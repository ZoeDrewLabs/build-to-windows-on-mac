// Build to Windows on Mac — roda programas e jogos de Windows no Mac (Wine + D3DMetal), sem máquina virtual.
// A interface só chama o zog.sh que vai dentro do app (Contents/Resources/scripts).
import AppKit
import SwiftUI
import UniformTypeIdentifiers
import CoreImage.CIFilterBuiltins
import ServiceManagement

// MARK: - Modelo

struct WinProgram: Identifiable, Hashable {
    var id: String { prefix + "/" + name }
    let prefix: String      // garrafa (WINEPREFIX) onde o programa está
    let name: String        // como aparece no Menu Iniciar do Windows
    let lnk: String         // atalho .lnk dentro da garrafa
}

/// Uma garrafa = um WINEPREFIX isolado (Prefixes/<id>).
struct Bottle: Identifiable, Hashable {
    let id: String          // nome da pasta
    let display: String     // nome de exibição (.zog/info)
    let programCount: Int
}

struct WinComponent: Identifiable, Hashable {
    let id: String          // vcredist, dotnet48
    let name: String
    let installed: Bool
}

struct Game: Identifiable, Hashable {
    let id: String          // nome do perfil (arquivo profiles/<id>.env)
    let title: String
    let appID: String
    let hasSavedConfig: Bool
}

@MainActor
final class Runner: ObservableObject {
    @Published var dataFolder: String {
        didSet {
            UserDefaults.standard.set(dataFolder, forKey: "dataFolder")
            Runner.writeCLIConfig(dataFolder)
            refresh()
        }
    }
    @Published var log = ""
    @Published var newName = ""     // campos do "Adicionar jogo"
    @Published var newAppID = ""
    @Published var dropTargeted = false   // arquivo sendo arrastado sobre a área
    @Published var showSupport = !UserDefaults.standard.bool(forKey: "supportShown")
    @Published var startAtLogin = SMAppService.mainApp.status == .enabled

    func setStartAtLogin(_ on: Bool) {
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
        } catch { log += "\nNão consegui mudar o início automático: \(error.localizedDescription)\n" }
        startAtLogin = SMAppService.mainApp.status == .enabled
    }
    @Published var busy = false
    @Published var games: [Game] = []
    @Published var isSetUp = false        // tradução instalada (motor do Wine)
    @Published var bottles: [Bottle] = []
    @Published var installTarget = ""     // "" = garrafa nova automática para cada programa
    @Published var componentsBottle: String? = nil   // garrafa aberta na folha de componentes
    @Published var progressText = ""
    @Published var progressValue = 0.0
    var currentProcess: Process?
    @Published var hasSteam = false
    @Published var programs: [WinProgram] = []
    @Published var components: [WinComponent] = []
    @Published var folderAvailable = true
    @Published var showFPS = UserDefaults.standard.bool(forKey: "showFPS") {
        didSet { UserDefaults.standard.set(showFPS, forKey: "showFPS") }
    }

    static let supportDir = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/BuildToWindowsOnMac")

    let script = Bundle.main.resourceURL!.appendingPathComponent("scripts/zog.sh").path

    init() {
        // 1) pasta escolhida no app; 2) a que o Terminal já usa (arquivo "home"); 3) padrão
        let saved = UserDefaults.standard.string(forKey: "dataFolder")
        let cli = (try? String(contentsOf: Runner.supportDir.appendingPathComponent("home"), encoding: .utf8))?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        dataFolder = saved ?? ((cli?.isEmpty == false) ? cli! : Runner.supportDir.appendingPathComponent("data").path)
        Runner.writeCLIConfig(dataFolder)
        refresh()
        checkUpdates()
    }

    // MARK: versão nova do app
    // O motor do Wine NUNCA é trocado pelo app: só a autora testa e publica versões novas no GitHub.
    // Aqui o app só avisa que existe um Release mais novo e abre a página para baixar.
    static let releasesAPI = "https://api.github.com/repos/ZoeDrewLabs/build-to-windows-on-mac/releases/latest"
    @Published var updateInfo = ""        // texto do aviso; vazio = nada novo
    @Published var updateURL: URL?

    func checkUpdates() {
        guard let url = URL(string: Runner.releasesAPI) else { return }
        var req = URLRequest(url: url, timeoutInterval: 8)
        req.setValue("BuildToWindowsOnMac", forHTTPHeaderField: "User-Agent")
        URLSession.shared.dataTask(with: req) { data, _, _ in
            guard let data,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let tag = json["tag_name"] as? String,
                  let page = (json["html_url"] as? String).flatMap(URL.init(string:)) else { return }
            let latest = tag.trimmingCharacters(in: CharacterSet(charactersIn: "vV"))
            let current = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
            guard latest.compare(current, options: .numeric) == .orderedDescending else { return }
            Task { @MainActor in
                self.updateInfo = "Versão nova do Build to Windows on Mac: \(latest) (você tem a \(current))."
                self.updateURL = page
            }
        }.resume()
    }

    /// O zog.sh do Terminal lê a pasta de dados deste arquivo.
    static func writeCLIConfig(_ folder: String) {
        try? FileManager.default.createDirectory(at: supportDir, withIntermediateDirectories: true)
        try? folder.write(to: supportDir.appendingPathComponent("home"), atomically: true, encoding: .utf8)
    }

    func refresh() {
        let fm = FileManager.default
        var isDir: ObjCBool = false
        folderAvailable = fm.fileExists(atPath: dataFolder, isDirectory: &isDir) && isDir.boolValue
        let engineOK = ((try? fm.contentsOfDirectory(atPath: (dataFolder as NSString)
            .appendingPathComponent("engine"))) ?? []).contains { e in
                fm.isExecutableFile(atPath: "\(dataFolder)/engine/\(e)/bin/wine") }
        isSetUp = engineOK
        // Garrafas: Prefixes/<nome>/ (versões antigas: bottles/steam, migrada pelo zog.sh no próximo comando)
        let prefixes = (dataFolder as NSString).appendingPathComponent("Prefixes")
        var dirs: [(String, String)] = ((try? fm.contentsOfDirectory(atPath: prefixes)) ?? []).sorted()
            .map { ($0, prefixes + "/" + $0) }
            .filter { fm.fileExists(atPath: $0.1 + "/system.reg") }
        let legacy = (dataFolder as NSString).appendingPathComponent("bottles/steam")
        if !dirs.contains(where: { $0.0 == "steam" }), fm.fileExists(atPath: legacy + "/system.reg") {
            dirs.append(("steam", legacy))
        }
        var allPrograms: [WinProgram] = []
        bottles = dirs.map { (name, path) in
            let progs = Runner.installedPrograms(in: path, prefix: name)
            allPrograms += progs
            let info = (try? String(contentsOfFile: path + "/.zog/info", encoding: .utf8)) ?? ""
            let display = info.split(separator: "\n").first { $0.hasPrefix("nome=") }
                .map { String($0.dropFirst(5)) } ?? name
            return Bottle(id: name, display: display, programCount: progs.count)
        }
        programs = allPrograms
        hasSteam = dirs.contains { fm.fileExists(atPath: $0.1 + "/drive_c/Program Files (x86)/Steam/steam.exe") }
        let profiles = (dataFolder as NSString).appendingPathComponent("profiles")
        let files = (try? fm.contentsOfDirectory(atPath: profiles)) ?? []
        // Só perfis de jogos da Steam (têm STEAM_APPID). Os "app-*.env" são de programas (tradutor gráfico etc.)
        games = files.filter { $0.hasSuffix(".env") && !$0.hasPrefix("app-") }.sorted().compactMap { file in
            let id = String(file.dropLast(4))
            let text = (try? String(contentsOfFile: (profiles as NSString).appendingPathComponent(file),
                                    encoding: .utf8)) ?? ""
            let appID = text.split(separator: "\n")
                .first { $0.hasPrefix("STEAM_APPID=") }
                .map { String($0.dropFirst("STEAM_APPID=".count)) } ?? ""
            var title = id.uppercased()
            if let first = text.split(separator: "\n").first, first.hasPrefix("# Perfil d") {
                // "# Perfil do PEAK (Steam appid ...)" → "PEAK"
                let s = first.replacingOccurrences(of: "# Perfil do ", with: "")
                    .replacingOccurrences(of: "# Perfil de ", with: "")
                title = s.components(separatedBy: " (").first ?? title
            }
            guard !appID.isEmpty else { return nil }          // sem número da Steam não é jogo da Steam
            let saved = fm.fileExists(atPath: (profiles as NSString).appendingPathComponent("\(id).config.reg"))
            return Game(id: id, title: title, appID: appID, hasSavedConfig: saved)
        }
    }

    /// Programas instalados = atalhos do Menu Iniciar dentro da garrafa (sem desinstaladores etc.).
    static func installedPrograms(in bottle: String, prefix: String) -> [WinProgram] {
        let fm = FileManager.default
        var roots = [bottle + "/drive_c/ProgramData/Microsoft/Windows/Start Menu"]
        for u in (try? fm.contentsOfDirectory(atPath: bottle + "/drive_c/users")) ?? [] {
            roots.append(bottle + "/drive_c/users/\(u)/AppData/Roaming/Microsoft/Windows/Start Menu")
        }
        let skip = ["uninstall", "desinstal", "remover", "readme", "leia-me", "help", "ajuda", "website", "manual"]
        var seen = Set<String>(); var out: [WinProgram] = []
        for root in roots {
            guard let en = fm.enumerator(atPath: root) else { continue }
            for case let rel as String in en where rel.lowercased().hasSuffix(".lnk") {
                let name = ((rel as NSString).lastPathComponent as NSString).deletingPathExtension
                let low = name.lowercased()
                if name == "Steam" || skip.contains(where: { low.contains($0) }) || seen.contains(name) { continue }
                seen.insert(name)
                out.append(WinProgram(prefix: prefix, name: name, lnk: root + "/" + rel))
            }
        }
        // Programa portátil (um .exe que não se instala, como muitos jogos): sem atalho no Menu Iniciar.
        // Usa a origem gravada na criação da garrafa (.zog/info), se ainda existir e não for instalador.
        if out.isEmpty, prefix != "steam",
           let info = try? String(contentsOfFile: bottle + "/.zog/info", encoding: .utf8) {
            let field = { (k: String) in info.split(separator: "\n").first { $0.hasPrefix(k + "=") }
                .map { String($0.dropFirst(k.count + 1)) } ?? "" }
            let origin = field("origem"), display = field("nome")
            let low = origin.lowercased()
            if low.hasSuffix(".exe"), fm.fileExists(atPath: origin),
               !low.contains("setup"), !low.contains("install") {
                out.append(WinProgram(prefix: prefix, name: display.isEmpty ? prefix : display, lnk: origin))
            }
        }
        return out.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    /// Roda "zog.sh <args>" e mostra a saída na caixa de log.
    func run(_ args: [String], extraEnv: [String: String] = [:], then: (() -> Void)? = nil) {
        guard !busy else { return }
        busy = true
        log += "\n▶︎ \(args.joined(separator: " "))\n"
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/zsh")
        p.arguments = [script] + args
        var env = ProcessInfo.processInfo.environment
        env["ZOG_HOME"] = dataFolder
        if showFPS { env["ZOG_HUD"] = "1" }
        extraEnv.forEach { env[$0] = $1 }
        p.environment = env
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe
        pipe.fileHandleForReading.readabilityHandler = { h in
            let data = h.availableData
            guard !data.isEmpty, let s = String(data: data, encoding: .utf8) else { return }
            Task { @MainActor in self.consume(s) }
        }
        progressText = ""; progressValue = 0
        currentProcess = p
        p.terminationHandler = { proc in
            Task { @MainActor in
                pipe.fileHandleForReading.readabilityHandler = nil
                self.currentProcess = nil
                self.progressText = ""
                if proc.terminationReason == .uncaughtSignal || proc.terminationStatus == 143 {
                    self.log += "(cancelado)\n"
                } else if proc.terminationStatus == 30 {
                    self.busy = false
                    self.refresh()
                    self.ensureRosetta { self.run(args, extraEnv: extraEnv, then: then) }
                    return
                } else if proc.terminationStatus != 0 {
                    self.log += "(terminou com código \(proc.terminationStatus))\n"
                }
                self.busy = false
                self.refresh()
                then?()
            }
        }
        do { try p.run() } catch {
            log += "Erro ao rodar: \(error.localizedDescription)\n"
            busy = false
        }
    }

    // Tradutores gráficos (DirectX → Metal) que dá para escolher por programa
    static let renderers: [(String, String)] = [
        ("d3dmetal", "D3DMetal (Apple) — padrão, o mais rápido"),
        ("dxmt", "DXMT — DirectX 11 → Metal (bom para GameMaker)"),
        ("dxvk", "DXVK — DirectX 9/10/11 → Vulkan → Metal"),
        ("wined3d", "WineD3D — o do próprio Wine (mais compatível, mais lento)"),
    ]
    func openProgram(_ p: WinProgram) {
        if p.lnk.lowercased().hasSuffix(".exe") {          // portátil: roda o .exe de origem na garrafa dele
            run(["abrir", p.lnk, p.prefix], extraEnv: ["ZOG_FORCAR": "1"])
        } else {
            run(["abrir-programa", p.prefix, p.name])
        }
    }

    func renderer(of prefix: String) -> String {
        let f = (dataFolder as NSString).appendingPathComponent("profiles/app-\(prefix).env")
        let text = (try? String(contentsOfFile: f, encoding: .utf8)) ?? ""
        let line = text.split(separator: "\n").last { $0.hasPrefix("ZOG_RENDERER=") }
        return line.map { String($0.dropFirst(13).prefix { $0 != " " && $0 != "#" }) } ?? "d3dmetal"
    }

    /// Separa as linhas de progresso ("PROGRESSO|etapa|total|texto") do resto do log.
    func consume(_ chunk: String) {
        for line in chunk.split(separator: "\n", omittingEmptySubsequences: false) {
            if line.hasPrefix("PROGRESSO|") {
                let f = line.split(separator: "|", maxSplits: 3).map(String.init)
                if f.count == 4, let i = Double(f[1]), let n = Double(f[2]) {
                    progressValue = n > 0 ? min(i / n, 1) : 0
                    progressText = f[3]
                    log += "• \(f[3])\n"
                }
            } else if !line.isEmpty {
                log += line + "\n"
            }
        }
    }

    /// Rosetta 2: o motor do Wine é Intel (x86_64) e roda pelo tradutor da Apple. Ele não pode vir
    /// dentro do app (é parte do macOS e só a Apple distribui); então o app instala direto da Apple.
    func ensureRosetta(_ then: @escaping () -> Void) {
        if quick(["rosetta"]).trimmingCharacters(in: .whitespacesAndNewlines) == "sim" { then(); return }
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "Falta o Rosetta 2"
        alert.informativeText = """
        O Rosetta 2 é o tradutor da Apple que deixa programas feitos para Intel rodarem no chip Apple — \
        e o Windows traduzido também passa por ele.

        Ele faz parte do macOS e só a Apple pode distribuí-lo, então não vem dentro deste app. \
        Mas o app instala agora, direto da Apple, com um clique (download pequeno, uma vez só).

        Ao instalar, você aceita a licença de software da Apple para o Rosetta.
        """
        alert.addButton(withTitle: "Instalar o Rosetta")
        alert.addButton(withTitle: "Agora não")
        guard alert.runModal() == .alertFirstButtonReturn else {
            log += "\nSem o Rosetta 2 os programas de Windows não abrem. Clique em Instalar quando quiser.\n"
            return
        }
        run(["instalar-rosetta"]) { [weak self] in
            guard let self else { return }
            if self.quick(["rosetta"]).trimmingCharacters(in: .whitespacesAndNewlines) == "sim" { then() }
        }
    }

    /// Cancela o comando atual: o zog.sh recebe SIGTERM e encerra a garrafa em uso (sem órfãos).
    func cancel() { currentProcess?.terminate() }

    func removeBottle(_ b: Bottle) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Apagar a garrafa \"\(b.display)\"?"
        alert.informativeText = "Apaga \(b.programCount == 1 ? "o programa instalado" : "os \(b.programCount) programas instalados") nela, com as configurações e arquivos salvos dentro dela. As outras garrafas não mudam. Não dá para desfazer."
        alert.addButton(withTitle: "Apagar")
        alert.addButton(withTitle: "Cancelar")
        if alert.runModal() == .alertFirstButtonReturn { run(["remover-garrafa", b.id]) }
    }

    static let windowsExtensions: Set<String> = ["exe", "msi", "bat", "cmd"]

    /// Abre um programa de Windows (.exe roda, .msi instala) — sem máquina virtual, só tradução.
    /// Roda "zog.sh <args>" e devolve a saída (para consultas rápidas que não usam o Wine).
    func quick(_ args: [String]) -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/zsh")
        p.arguments = [script] + args
        var env = ProcessInfo.processInfo.environment
        env["ZOG_HOME"] = dataFolder
        p.environment = env
        let pipe = Pipe(); p.standardOutput = pipe; p.standardError = Pipe()
        guard (try? p.run()) != nil else { return "" }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return String(data: data, encoding: .utf8) ?? ""
    }

    func loadComponents(for bottle: String) {
        components = quick(["componentes", bottle]).split(separator: "\n").compactMap { line in
            let f = line.split(separator: "|", omittingEmptySubsequences: false).map(String.init)
            return f.count == 3 ? WinComponent(id: f[0], name: f[1], installed: f[2] == "sim") : nil
        }
    }

    /// Antes de abrir: o catálogo conhece esse programa? Tem versão para Mac? Não funciona no Wine?
    /// Devolve true se pode seguir.
    func confirmWithCatalog(_ url: URL) -> Bool {
        let out = quick(["catalogo", url.deletingPathExtension().lastPathComponent])
        let f = out.trimmingCharacters(in: .whitespacesAndNewlines).components(separatedBy: "\t")
        guard f.count >= 5 else { return true }               // não está no catálogo
        let (name, sit, link, note) = (f[0], f[1], f[2], f[4])
        guard sit == "mac" || sit == "nao" else {
            log += "\nPrograma reconhecido: \(name) — \(note)\n"
            return true
        }
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        if sit == "mac" {
            alert.messageText = "\(name) tem versão para Mac"
            alert.informativeText = "\(note)\n\nA versão nativa roda melhor e não precisa de tradução. Quer abrir o site da versão para Mac?"
            alert.addButton(withTitle: "Abrir site da versão Mac")
            alert.addButton(withTitle: "Usar a de Windows mesmo assim")
            alert.addButton(withTitle: "Cancelar")
            switch alert.runModal() {
            case .alertFirstButtonReturn:
                if let u = URL(string: link) { NSWorkspace.shared.open(u) }
                return false
            case .alertSecondButtonReturn: return true
            default: return false
            }
        } else {
            alert.alertStyle = .warning
            alert.messageText = "\(name) não funciona por aqui"
            alert.informativeText = note
            alert.addButton(withTitle: "Cancelar")
            alert.addButton(withTitle: "Tentar mesmo assim")
            return alert.runModal() == .alertSecondButtonReturn
        }
    }

    func openWindowsFile(_ url: URL) {
        guard Runner.windowsExtensions.contains(url.pathExtension.lowercased()) else {
            log += "\n\(url.lastPathComponent): não é um programa de Windows (.exe, .msi, .bat).\n"
            return
        }
        guard isSetUp else {
            log += "\nPrimeiro clique em \"Instalar\"; depois arraste o programa de novo.\n"
            return
        }
        if busy {   // espera o comando atual terminar
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { self.openWindowsFile(url) }
            return
        }
        guard confirmWithCatalog(url) else { log += "\n\(url.lastPathComponent): cancelado.\n"; return }
        var env = ["ZOG_FORCAR": "1"]
        if !installTarget.isEmpty { env["ZOG_PREFIXO"] = installTarget }
        run(["abrir", url.path], extraEnv: env)
    }

    func pickWindowsFile() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = Runner.windowsExtensions.compactMap { UTType(filenameExtension: $0) }
        panel.allowsMultipleSelection = false
        panel.prompt = "Abrir"
        if panel.runModal() == .OK, let url = panel.url { openWindowsFile(url) }
    }

    func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "Usar esta pasta"
        panel.message = "Onde guardar o \"Windows\" com seus programas e jogos? (pode ser um SSD externo)"
        if panel.runModal() == .OK, let url = panel.url {
            // Se escolheu uma pasta que já é do Build to Windows on Mac, usa ela; senão cria uma subpasta.
            let existing = url.appendingPathComponent("bottles").path
            dataFolder = FileManager.default.fileExists(atPath: existing)
                ? url.path : url.appendingPathComponent("BuildToWindowsOnMac").path
        }
    }

    func copyLog() {
        let last = (dataFolder as NSString).appendingPathComponent("logs/ultimo.log")
        let text = (try? String(contentsOfFile: last, encoding: .utf8)) ?? log
        let tail = text.split(separator: "\n", omittingEmptySubsequences: false).suffix(120).joined(separator: "\n")
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(tail, forType: .string)
        log += "\n(últimas 120 linhas do log copiadas — é só colar para o Claude)\n"
    }
}


// MARK: - Apoio (o app é gratuito)

enum Support {
    static let livePixURL = "https://livepix.gg/zoedrewerro404"
    static let pixKey = "54.913.468/0001-04"          // Pix (CNPJ)
    static let pixKeyDigits = "54913468000104"

    static func qrCode(_ text: String) -> NSImage {
        let f = CIFilter.qrCodeGenerator()
        f.message = Data(text.utf8)
        f.correctionLevel = "M"
        let img = f.outputImage!.transformed(by: CGAffineTransform(scaleX: 10, y: 10))
        let rep = NSCIImageRep(ciImage: img)
        let ns = NSImage(size: rep.size)
        ns.addRepresentation(rep)
        return ns
    }
}

struct SupportView: View {
    @EnvironmentObject var r: Runner
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        VStack(spacing: 14) {
            Text("☕️").font(.system(size: 44))
            Text("Este aplicativo é gratuito").font(.title2.bold())
            Text("Considere me pagar um café! Qualquer valor ajuda a manter o Build to Windows on Mac funcionando com mais programas e jogos.")
                .multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
            HStack(alignment: .top, spacing: 24) {
                VStack(spacing: 6) {
                    Image(nsImage: Support.qrCode(Support.livePixURL))
                        .interpolation(.none).resizable().frame(width: 170, height: 170)
                        .padding(8).background(Color.white).cornerRadius(8)
                    Text("LivePix").font(.headline)
                    Link("livepix.gg/zoedrewerro404", destination: URL(string: Support.livePixURL)!).font(.caption)
                }
                VStack(alignment: .leading, spacing: 8) {
                    Text("Pix (CNPJ)").font(.headline)
                    Text(Support.pixKey).font(.system(.title3, design: .monospaced)).textSelection(.enabled)
                    Button("Copiar chave Pix") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(Support.pixKeyDigits, forType: .string)
                    }
                    Text("Cole no app do seu banco, em Pix → Pagar com chave.")
                        .font(.caption).foregroundStyle(.secondary).frame(width: 180, alignment: .leading)
                }.padding(.top, 10)
            }
            Button("Continuar") {
                UserDefaults.standard.set(true, forKey: "supportShown")
                r.showSupport = false
                dismiss()
            }.buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
        }
        .padding(28)
        .frame(width: 480)
    }
}

// MARK: - Telas

struct BottleRef: Identifiable { let id: String }

/// Componentes do Windows de uma garrafa (Visual C++, .NET, fontes…).
struct ComponentsSheet: View {
    @EnvironmentObject var r: Runner
    @Environment(\.dismiss) private var dismiss
    let bottle: String
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Componentes da garrafa \"\(bottle)\"").font(.title3.bold())
            Text("Vêm direto da Microsoft. O app já instala sozinho o que detecta no programa; aqui dá para instalar à mão.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            ForEach(r.components) { c in
                HStack {
                    Image(systemName: c.installed ? "checkmark.circle.fill" : "circle")
                        .foregroundStyle(c.installed ? .green : .secondary)
                    Text(c.name)
                    Spacer()
                    if c.installed { Text("instalado").font(.caption).foregroundStyle(.secondary) }
                    else {
                        Button("Instalar") {
                            r.run(["instalar-componente", bottle, c.id]) { r.loadComponents(for: bottle) }
                        }.controlSize(.small).disabled(r.busy)
                    }
                }
            }
            HStack { Spacer(); Button("Fechar") { dismiss() }.keyboardShortcut(.defaultAction) }
        }
        .padding(22).frame(width: 460)
    }
}

/// Área onde se solta um .exe/.msi para rodar.
struct DropZone: View {
    @EnvironmentObject var r: Runner

    var body: some View {
        VStack(spacing: 6) {
            Image(systemName: "arrow.down.app").font(.system(size: 26))
            Text("Arraste aqui um programa de Windows (.exe ou .msi)").font(.headline)
            Text("Roda direto no Mac, traduzido pelo Wine — sem máquina virtual.")
                .font(.caption).foregroundStyle(.secondary)
            Button("Escolher arquivo…") { r.pickWindowsFile() }.controlSize(.small)
        }
        .frame(maxWidth: .infinity, minHeight: 110)
        .background(RoundedRectangle(cornerRadius: 10)
            .fill(r.dropTargeted ? Color.accentColor.opacity(0.15) : Color.secondary.opacity(0.06)))
        .overlay(RoundedRectangle(cornerRadius: 10)
            .strokeBorder(r.dropTargeted ? Color.accentColor : Color.secondary.opacity(0.4),
                          style: StrokeStyle(lineWidth: 1.5, dash: [6, 4])))
        .onDrop(of: [.fileURL], isTargeted: $r.dropTargeted) { providers in
            for p in providers {
                _ = p.loadObject(ofClass: URL.self) { url, _ in
                    if let url { Task { @MainActor in r.openWindowsFile(url) } }
                }
            }
            return true
        }
    }
}

struct ContentView: View {
    @EnvironmentObject var r: Runner

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            if !r.folderAvailable && r.dataFolder.hasPrefix("/Volumes/") {
                Label("A pasta de dados não está disponível. O SSD está conectado?",
                      systemImage: "externaldrive.badge.exclamationmark")
                    .foregroundStyle(.orange)
            }
            ScrollView {
                if r.isSetUp { mainControls } else { setupPanel }
            }
            if r.busy {
                HStack {
                    if r.progressText.isEmpty { ProgressView().controlSize(.small) }
                    else { ProgressView(value: r.progressValue).frame(width: 140) }
                    Text(r.progressText.isEmpty ? "Trabalhando…" : r.progressText).font(.callout).lineLimit(1)
                    Spacer()
                    Button("Cancelar") { r.cancel() }.controlSize(.small)
                }
            }
            logBox
        }
        .padding(20)
        .frame(minWidth: 640, minHeight: 700)
        .onAppear { r.refresh() }
        .sheet(isPresented: $r.showSupport) { SupportView().environmentObject(r) }
        .sheet(item: Binding(get: { r.componentsBottle.map { BottleRef(id: $0) } },
                             set: { r.componentsBottle = $0?.id })) { ref in
            ComponentsSheet(bottle: ref.id).environmentObject(r)
        }
    }

    var header: some View {
        HStack(alignment: .center) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Build to Windows on Mac").font(.largeTitle.bold())
                Text("Programas e jogos de Windows no Mac · sem máquina virtual").foregroundStyle(.secondary)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 4) {
                Text(r.dataFolder).font(.caption).foregroundStyle(.secondary)
                    .lineLimit(1).truncationMode(.middle).frame(maxWidth: 260, alignment: .trailing)
                HStack {
                    Button("☕️ Apoiar") { r.showSupport = true }.controlSize(.small)
                    Button("Mudar pasta…") { r.chooseFolder() }.controlSize(.small).disabled(r.busy)
                }
                Toggle("Abrir ao ligar o Mac", isOn: Binding(get: { r.startAtLogin },
                                                             set: { r.setStartAtLogin($0) }))
                    .toggleStyle(.checkbox).controlSize(.small)
            }
        }
    }

    var setupPanel: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 10) {
                Text("Primeira vez neste Mac").font(.headline)
                Text("Vai instalar a tradução que vem dentro do app — o motor do Wine e os tradutores gráficos (D3DMetal da Apple e DXMT) — e criar um \"Windows\" vazio para os seus programas. Funciona sem internet; com internet, o app procura versões mais novas. Depois é só arrastar um instalador .exe ou .msi, ou instalar a Steam se quiser jogar. Precisa de um Mac com chip Apple (M1 ou mais novo). Se faltar o Rosetta 2 (tradutor da Apple), o app instala direto da Apple antes.")
                    .fixedSize(horizontal: false, vertical: true)
                HStack {
                    Button("Instalar") { r.ensureRosetta { r.run(["setup"]) } }
                        .buttonStyle(.borderedProminent).disabled(r.busy)
                    if r.busy { ProgressView().controlSize(.small) }
                }
            }.frame(maxWidth: .infinity, alignment: .leading).padding(6)
        }
    }

    var mainControls: some View {
        VStack(alignment: .leading, spacing: 12) {
            if !r.updateInfo.isEmpty && r.isSetUp {
                HStack {
                    Image(systemName: "arrow.down.circle.fill").foregroundStyle(.blue)
                    Text(r.updateInfo).font(.callout).fixedSize(horizontal: false, vertical: true)
                    Spacer()
                    Button("Baixar") { if let u = r.updateURL { NSWorkspace.shared.open(u) } }
                        .buttonStyle(.borderedProminent).controlSize(.small)
                    Button("Agora não") { r.updateInfo = "" }.controlSize(.small)
                }
                .padding(10)
                .background(RoundedRectangle(cornerRadius: 8).fill(Color.blue.opacity(0.1)))
            }
            HStack {
                Button { r.run(["kill"]) } label: { Label("Fechar tudo do Windows", systemImage: "stop.fill") }
                Toggle("Mostrar FPS", isOn: $r.showFPS).toggleStyle(.checkbox).padding(.leading, 8)
                Spacer()
                Button { r.copyLog() } label: { Label("Copiar log", systemImage: "doc.on.clipboard") }
            }.disabled(r.busy)

            GroupBox("Programas de Windows") {
                VStack(alignment: .leading, spacing: 8) {
                    DropZone()
                    HStack {
                        Text("Instalar em:").font(.callout)
                        Picker("", selection: $r.installTarget) {
                            Text("Garrafa nova para cada programa (recomendado)").tag("")
                            ForEach(r.bottles) { b in Text("Garrafa \"\(b.display)\"").tag(b.id) }
                        }.labelsHidden().frame(maxWidth: 360)
                        Spacer()
                    }
                    if r.programs.filter({ $0.prefix != "steam" }).isEmpty {
                        Text("Nenhum programa instalado ainda. Arraste o instalador (.exe ou .msi) acima.")
                            .font(.callout).foregroundStyle(.secondary)
                    } else {
                        ForEach(r.programs.filter { $0.prefix != "steam" }) { prog in
                            HStack {
                                Image(systemName: "app.dashed")
                                VStack(alignment: .leading, spacing: 0) {
                                    Text(prog.name)
                                    Text("garrafa \(prog.prefix)").font(.caption2).foregroundStyle(.secondary)
                                }
                                Spacer()
                                Menu {
                                    Text("Se o programa abrir com tela preta, erro de DirectX ou gráfico estranho, troque aqui:")
                                    ForEach(Runner.renderers, id: \.0) { rid, label in
                                        Button((r.renderer(of: prog.prefix) == rid ? "✓ " : "") + label) {
                                            r.run(["tradutor", prog.prefix, rid])
                                        }
                                    }
                                } label: { Image(systemName: "display") }
                                .menuStyle(.borderlessButton).fixedSize().help("Tradutor gráfico deste programa")
                                Button("Abrir") { r.openProgram(prog) }.controlSize(.small)
                            }
                            Divider()
                        }
                    }
                }.disabled(r.busy).padding(4)
            }

            GroupBox("Garrafas (cada programa isolado)") {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Cada programa fica na própria garrafa — um Windows separado, com registro e DLLs só dele. Assim um programa de empresa nunca quebra outro. Os componentes (Visual C++, .NET, fontes) são instalados por garrafa, sozinhos quando o app detecta que o programa precisa.")
                        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    ForEach(r.bottles) { b in
                        HStack {
                            Image(systemName: b.id == "steam" ? "gamecontroller" : "shippingbox")
                            VStack(alignment: .leading, spacing: 0) {
                                Text(b.display)
                                Text("\(b.id) · \(b.programCount) programa\(b.programCount == 1 ? "" : "s")")
                                    .font(.caption2).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Button("Componentes…") { r.loadComponents(for: b.id); r.componentsBottle = b.id }
                                .controlSize(.small)
                            Button(role: .destructive) { r.removeBottle(b) } label: { Image(systemName: "trash") }
                                .controlSize(.small).help("Apagar esta garrafa")
                        }
                        Divider()
                    }
                }.disabled(r.busy).padding(4)
            }

            GroupBox("Jogos (Steam)") {
                if r.hasSteam { steamSection } else {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Quer jogar jogos de Windows?").font(.headline)
                            Text("Instale a Steam de Windows (opcional, precisa de internet).")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("Instalar Steam") { r.run(["instalar-steam"]) }.disabled(r.busy)
                    }.padding(4)
                }
            }
        }
    }

    var steamSection: some View {
        VStack(spacing: 6) {
            HStack {
                Button { r.run(["steam"]) } label: { Label("Abrir Steam", systemImage: "play.fill") }
                    .buttonStyle(.borderedProminent)
                Spacer()
            }
            ForEach(r.games) { g in
                HStack {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(g.title).font(.headline)
                        Text("Steam \(g.appID)" + (g.hasSavedConfig ? " · configurações salvas" : ""))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Salvar config") { r.run(["salvar", g.id]) }.controlSize(.small)
                    Button("Restaurar") { r.run(["restaurar", g.id]) }.controlSize(.small)
                        .disabled(!g.hasSavedConfig)
                    Button("Jogar") { r.run(["jogar", g.id]) }.buttonStyle(.borderedProminent)
                }
                .padding(.vertical, 2)
                Divider()
            }
            HStack {
                TextField("nome do jogo (ex.: sims4)", text: $r.newName).frame(width: 180)
                TextField("número na loja Steam", text: $r.newAppID).frame(width: 150)
                Button("Adicionar jogo") {
                    let name = r.newName.lowercased().filter { $0.isLetter || $0.isNumber }
                    r.run(["novo", name, r.newAppID.filter(\.isNumber)])
                    r.newName = ""; r.newAppID = ""
                }.disabled(r.newName.isEmpty || r.newAppID.filter(\.isNumber).isEmpty)
                Spacer()
            }
        }.disabled(r.busy).padding(4)
    }

    var logBox: some View {
        ScrollViewReader { proxy in
            ScrollView {
                Text(r.log.isEmpty ? "Pronto." : r.log)
                    .font(.system(.caption, design: .monospaced))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
                    .id("fim")
            }
            .frame(minHeight: 110, maxHeight: 160)
            .padding(8)
            .background(RoundedRectangle(cornerRadius: 8).fill(Color(nsColor: .textBackgroundColor)))
            .onChange(of: r.log) { _, _ in proxy.scrollTo("fim", anchor: .bottom) }
        }
    }
}

/// Recebe arquivos abertos pelo Finder ("Abrir com") ou soltos no ícone do Dock.
final class AppDelegate: NSObject, NSApplicationDelegate {
    var pending: [URL] = []
    var runner: Runner? { didSet { pending.forEach { u in Task { @MainActor in runner?.openWindowsFile(u) } }; pending = [] } }
    func application(_ application: NSApplication, open urls: [URL]) {
        guard let runner else { pending += urls; return }
        urls.forEach { u in Task { @MainActor in runner.openWindowsFile(u) } }
    }
    // Fecha a janela mas continua na barra de menus, pronto para abrir programas de Windows.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
}

@main
struct BuildToWindowsOnMacApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var runner = Runner()
    var body: some Scene {
        WindowGroup("Build to Windows on Mac", id: "main") {
            ContentView().environmentObject(runner)
                .onAppear { delegate.runner = runner }
        }
        .windowResizability(.contentMinSize)

        MenuBarExtra("Build to Windows on Mac", systemImage: "macwindow") {
            MenuBarContent().environmentObject(runner)
        }
    }
}

/// Menu na barra de cima do Mac (o app fica rodando em segundo plano).
struct MenuBarContent: View {
    @EnvironmentObject var r: Runner
    @Environment(\.openWindow) private var openWindow
    var body: some View {
        Button("Abrir Build to Windows on Mac") { showMain() }
        Divider()
        if r.isSetUp {
            Button("Abrir programa de Windows…") { NSApp.activate(ignoringOtherApps: true); r.pickWindowsFile() }
            if !r.programs.filter({ $0.prefix != "steam" }).isEmpty {
                Menu("Programas") {
                    ForEach(r.programs.filter { $0.prefix != "steam" }) { p in
                        Button(p.name) { r.openProgram(p) }
                    }
                }
            }
            if r.hasSteam { Button("Abrir Steam") { r.run(["steam"]) } }
            if r.hasSteam && !r.games.isEmpty {
                Menu("Jogar") {
                    ForEach(r.games) { g in Button(g.title) { r.run(["jogar", g.id]) } }
                }
            }
            Button("Fechar tudo do Windows") { r.run(["kill"]) }
        } else {
            Button("Instalar (primeira vez)…") { showMain() }
        }
        Divider()
        Button("☕️ Apoiar o app") { showMain(); r.showSupport = true }
        Button("Sair") { NSApp.terminate(nil) }
    }
    func showMain() {
        NSApp.activate(ignoringOtherApps: true)
        if let w = NSApp.windows.first(where: { $0.title == "Build to Windows on Mac" }) { w.makeKeyAndOrderFront(nil) }
        else { openWindow(id: "main") }
    }
}
