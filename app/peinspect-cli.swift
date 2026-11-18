// peinspect — ferramenta de linha de comando do PEInspector (usada pelo zog.sh).
//   peinspect <arquivo.exe>            relatório de um arquivo
//   peinspect --deps <arq> [<arq>...]  só a união dos pré-requisitos (separados por vírgula)
// Código de saída: 0 ok, 2 não é um executável do Windows, 1 erro de uso.
import Foundation

@main
struct PEInspectCLI {
    static func main() {
        var args = Array(CommandLine.arguments.dropFirst())
        guard !args.isEmpty else {
            FileHandle.standardError.write("uso: peinspect [--deps] <arquivo.exe>...\n".data(using: .utf8)!)
            exit(1)
        }
        let depsOnly = args.first == "--deps"
        if depsOnly { args.removeFirst() }
        var union = Set<String>()
        var anyOK = false
        for path in args {
            do {
                let info = try PEInspector.inspect(URL(fileURLWithPath: path))
                anyOK = true
                if depsOnly { union.formUnion(info.dependencies) } else { print(PEInspector.report(info)) }
            } catch {
                if !depsOnly { print("erro=\(path): \(error)") }
            }
        }
        if depsOnly { print(union.sorted().joined(separator: ",")) }
        exit(anyOK ? 0 : 2)
    }
}
