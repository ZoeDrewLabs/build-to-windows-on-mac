// PEInspector — lê o cabeçalho PE (Portable Executable) de um .exe/.dll do Windows, sem executar nada,
// e deduz do que o programa precisa: arquitetura, DLLs importadas, se é .NET, se é instalador, Electron…
//
// Formato PE (resumo): DOS header ("MZ", e_lfanew em 0x3C) → "PE\0\0" → COFF header (Machine,
// NumberOfSections, SizeOfOptionalHeader) → Optional Header (PE32 0x10B / PE32+ 0x20B, ImageBase,
// Data Directories) → tabela de seções (para converter RVA em posição no arquivo).
// Data Directories usados: [1] Import, [13] Delay Import, [14] CLR (.NET).
import Foundation

struct PEInfo {
    enum Arch: String { case x86, x64, arm64, desconhecida }
    var arch: Arch = .desconhecida
    var imports: [String] = []          // DLLs importadas direto (minúsculas)
    var delayImports: [String] = []     // DLLs carregadas sob demanda
    var dotNetVersion: String? = nil    // ex.: "v4.0.30319" se for .NET
    var installerKind: String? = nil    // nsis, inno, installshield, wix, msi-wrapper, 7zip-sfx
    var isElectron = false
    var usesWebView2 = false
    var isGameMaker = false             // jogo GameMaker (data.win): o D3DMetal falha nele; o DXMT funciona

    var allImports: [String] { imports + delayImports }

    /// Pré-requisitos (ids do provisionador) deduzidos das importações.
    var dependencies: [String] {
        var d = Set<String>()
        for dll in allImports {
            if dll == "mscoree.dll" { d.insert("dotnet48") }
            if dll.hasPrefix("vcruntime140") || dll.hasPrefix("msvcp140") || dll.hasPrefix("concrt140")
                || dll.hasPrefix("vcomp140") || dll == "ucrtbase.dll" || dll.hasPrefix("api-ms-win-crt-") {
                d.insert("vcredist")
            }
            if dll == "msvcr120.dll" || dll == "msvcp120.dll" { d.insert("vcrun2013") }
            if dll == "msvcr100.dll" || dll == "msvcp100.dll" { d.insert("vcrun2010") }
            if dll == "msxml3.dll" || dll == "msxml6.dll" { d.insert("msxml6") }
            if dll == "webview2loader.dll" { d.insert("webview2") }
        }
        if let v = dotNetVersion, v.hasPrefix("v4") { d.insert("dotnet48") }
        if usesWebView2 { d.insert("webview2") }
        return d.sorted()
    }

    var flags: [String] {
        var f: [String] = []
        if isElectron { f.append("electron") }
        if isGameMaker { f.append("gamemaker") }
        if usesWebView2 { f.append("webview2") }
        if dotNetVersion != nil { f.append("dotnet") }
        return f
    }
}

enum PEError: Error { case notPE(String) }

enum PEInspector {
    /// Lê um arquivo. `scanFolder`: também olha a pasta do programa (Electron, WebView2Loader.dll).
    static func inspect(_ url: URL, scanFolder: Bool = true) throws -> PEInfo {
        let data = try Data(contentsOf: url, options: .alwaysMapped)
        var info = try parse(data)
        if scanFolder { inspectFolder(url.deletingLastPathComponent(), into: &info) }
        info.installerKind = detectInstaller(data, name: url.lastPathComponent)
        return info
    }

    // MARK: leitura segura de inteiros little-endian
    private static func u16(_ d: Data, _ o: Int) -> Int? {
        guard o >= 0, o + 2 <= d.count else { return nil }
        return Int(d[d.startIndex + o]) | Int(d[d.startIndex + o + 1]) << 8
    }
    private static func u32(_ d: Data, _ o: Int) -> Int? {
        guard o >= 0, o + 4 <= d.count else { return nil }
        var v = 0
        for i in 0..<4 { v |= Int(d[d.startIndex + o + i]) << (8 * i) }
        return v
    }
    private static func u64(_ d: Data, _ o: Int) -> UInt64? {
        guard o >= 0, o + 8 <= d.count else { return nil }
        var v: UInt64 = 0
        for i in 0..<8 { v |= UInt64(d[d.startIndex + o + i]) << (8 * UInt64(i)) }
        return v
    }
    private static func cString(_ d: Data, _ o: Int, max: Int = 260) -> String? {
        guard o >= 0, o < d.count else { return nil }
        var bytes: [UInt8] = []
        var i = o
        while i < d.count, bytes.count < max {
            let b = d[d.startIndex + i]
            if b == 0 { break }
            bytes.append(b); i += 1
        }
        return String(bytes: bytes, encoding: .ascii)
    }

    struct Section { let va: Int; let vsize: Int; let raw: Int; let rawSize: Int; let name: String }

    private static func rvaToOffset(_ rva: Int, _ sections: [Section]) -> Int? {
        for s in sections where rva >= s.va && rva < s.va + max(s.vsize, s.rawSize) {
            return rva - s.va + s.raw
        }
        return nil
    }

    static func parse(_ d: Data) throws -> PEInfo {
        guard d.count > 0x40, d[d.startIndex] == 0x4D, d[d.startIndex + 1] == 0x5A else {
            throw PEError.notPE("sem assinatura MZ")
        }
        guard let peOff = u32(d, 0x3C), u32(d, peOff) == 0x0000_4550 else {   // "PE\0\0"
            throw PEError.notPE("sem assinatura PE")
        }
        var info = PEInfo()
        let coff = peOff + 4
        switch u16(d, coff) ?? 0 {
        case 0x014C: info.arch = .x86          // IMAGE_FILE_MACHINE_I386
        case 0x8664: info.arch = .x64          // IMAGE_FILE_MACHINE_AMD64
        case 0xAA64: info.arch = .arm64        // IMAGE_FILE_MACHINE_ARM64
        default: info.arch = .desconhecida
        }
        let nSections = u16(d, coff + 2) ?? 0
        let optSize = u16(d, coff + 16) ?? 0
        let opt = coff + 20
        let magic = u16(d, opt) ?? 0
        let isPE32Plus = magic == 0x20B
        let imageBase: UInt64 = isPE32Plus ? (u64(d, opt + 24) ?? 0) : UInt64(u32(d, opt + 28) ?? 0)
        let numDirsOff = opt + (isPE32Plus ? 108 : 92)
        let dirsOff = opt + (isPE32Plus ? 112 : 96)
        let numDirs = min(u32(d, numDirsOff) ?? 0, 16)

        var sections: [Section] = []
        let secTable = opt + optSize
        for i in 0..<nSections {
            let s = secTable + i * 40
            guard let vsize = u32(d, s + 8), let va = u32(d, s + 12),
                  let rawSize = u32(d, s + 16), let raw = u32(d, s + 20) else { break }
            let name = cString(d, s, max: 8) ?? ""
            sections.append(Section(va: va, vsize: vsize, raw: raw, rawSize: rawSize, name: name))
        }
        func dir(_ i: Int) -> (rva: Int, size: Int)? {
            guard i < numDirs, let rva = u32(d, dirsOff + i * 8), let size = u32(d, dirsOff + i * 8 + 4),
                  rva != 0, size != 0 else { return nil }
            return (rva, size)
        }

        // [1] Import Directory: descritores de 20 bytes; Name (RVA) em +12; termina num descritor zerado.
        if let imp = dir(1), var off = rvaToOffset(imp.rva, sections) {
            for _ in 0..<512 {
                let nameRVA = u32(d, off + 12) ?? 0
                let firstThunk = u32(d, off + 16) ?? 0
                if nameRVA == 0 && firstThunk == 0 { break }
                if let no = rvaToOffset(nameRVA, sections), let n = cString(d, no) { info.imports.append(n.lowercased()) }
                off += 20
            }
        }
        // [13] Delay Import: descritores de 32 bytes; DllNameRVA em +4. Atributo bit 0 = 0 → é VA (antigo).
        if let dimp = dir(13), var off = rvaToOffset(dimp.rva, sections) {
            for _ in 0..<512 {
                let attrs = u32(d, off) ?? 0
                var nameRVA = u32(d, off + 4) ?? 0
                if nameRVA == 0 { break }
                if attrs & 1 == 0, UInt64(nameRVA) > imageBase { nameRVA = Int(UInt64(nameRVA) - imageBase) }
                if let no = rvaToOffset(nameRVA, sections), let n = cString(d, no) { info.delayImports.append(n.lowercased()) }
                off += 32
            }
        }
        // [14] CLR Runtime Header (.NET): MetaData RVA em +8 → raiz "BSJB", versão em +16 (tamanho em +12).
        if let clr = dir(14), let co = rvaToOffset(clr.rva, sections) {
            info.dotNetVersion = "?"
            if let mdRVA = u32(d, co + 8), let mo = rvaToOffset(mdRVA, sections), u32(d, mo) == 0x424A_5342,
               let len = u32(d, mo + 12), let v = cString(d, mo + 16, max: min(len, 64)) {
                info.dotNetVersion = v
            }
        }
        info.imports = Array(NSOrderedSet(array: info.imports)) as? [String] ?? info.imports
        return info
    }

    /// Instaladores conhecidos (o .exe de instalação quase só importa kernel32; o tipo diz como rodar).
    static func detectInstaller(_ d: Data, name: String) -> String? {
        let head = d.prefix(4 * 1024 * 1024)
        func has(_ s: String) -> Bool { head.range(of: Data(s.utf8)) != nil }
        if has("Nullsoft.NSIS") || has("NullsoftInst") { return "nsis" }
        if has("Inno Setup") { return "inno" }
        if has("InstallShield") { return "installshield" }
        if has(".wixburn") || has("WixBundle") { return "wix" }
        if has("7zS.sfx") || has(";!@Install@!UTF-8!") { return "7zip-sfx" }
        let n = name.lowercased()
        if n.contains("setup") || n.contains("install") { return "generico" }
        return nil
    }

    /// Pasta do programa: Electron (resources/app.asar, *.pak) e WebView2Loader.dll.
    static func inspectFolder(_ dir: URL, into info: inout PEInfo) {
        let fm = FileManager.default
        let names = Set(((try? fm.contentsOfDirectory(atPath: dir.path)) ?? []).map { $0.lowercased() })
        if names.contains("webview2loader.dll") { info.usesWebView2 = true }
        if names.contains("data.win") { info.isGameMaker = true }
        let asar = dir.appendingPathComponent("resources/app.asar").path
        if fm.fileExists(atPath: asar) || (names.contains("resources.pak") && names.contains("chrome_100_percent.pak")) {
            info.isElectron = true
        }
        if info.allImports.contains("webview2loader.dll") { info.usesWebView2 = true }
    }

    /// Texto estável para o zog.sh ler (uma chave por linha).
    static func report(_ info: PEInfo) -> String {
        [
            "arch=\(info.arch.rawValue)",
            "dotnet=\(info.dotNetVersion ?? "")",
            "installer=\(info.installerKind ?? "")",
            "imports=\(info.allImports.joined(separator: ","))",
            "deps=\(info.dependencies.joined(separator: ","))",
            "flags=\(info.flags.joined(separator: ","))",
        ].joined(separator: "\n")
    }
}
