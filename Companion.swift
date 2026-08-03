import AppKit

/// Ponte entre o CamCircle e o Teleprompter: cada app abre e fecha o outro.
/// Este arquivo é compilado nos dois binários.
enum Companion {

    /// Procura o bundle irmão. Primeiro ao lado do app que está rodando — cobre
    /// tanto os dois instalados em ~/Applications quanto os dois no diretório do
    /// fonte — e depois nos caminhos padrão.
    static func locate(_ name: String) -> URL? {
        let sibling = Bundle.main.bundleURL
            .deletingLastPathComponent()
            .appendingPathComponent("\(name).app")

        let candidates = [
            sibling,
            URL(fileURLWithPath: NSString(string: "~/Applications/\(name).app").expandingTildeInPath),
            URL(fileURLWithPath: "/Applications/\(name).app"),
        ]
        return candidates.first { FileManager.default.fileExists(atPath: $0.path) }
    }

    static func isRunning(bundleID: String) -> Bool {
        !NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).isEmpty
    }

    /// Abre se estiver fechado, fecha se estiver aberto.
    static func toggle(name: String, bundleID: String) {
        let running = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
        if !running.isEmpty {
            running.forEach { $0.terminate() }
            return
        }

        guard let url = locate(name) else {
            notFound(name)
            return
        }

        let config = NSWorkspace.OpenConfiguration()
        config.activates = false        // não rouba o foco do app em uso
        NSWorkspace.shared.openApplication(at: url, configuration: config) { _, error in
            guard let error else { return }
            DispatchQueue.main.async {
                let alert = NSAlert(error: error)
                alert.messageText = "Não foi possível abrir o \(name)"
                alert.runModal()
            }
        }
    }

    private static func notFound(_ name: String) {
        let alert = NSAlert()
        alert.messageText = "\(name) não encontrado"
        alert.informativeText = "Compile e instale os dois apps com:\n\n    cam build"
        alert.runModal()
    }
}
