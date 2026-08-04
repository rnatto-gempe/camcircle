import AppKit

/// Valida posições de janela salvas contra as telas que existem agora.
///
/// Uma posição gravada com o monitor externo conectado fica fora de qualquer
/// tela quando ele é desconectado. O app abre, roda, e não se vê nada — foi
/// exatamente o que aconteceu com `originX = 2969` numa tela de 1440 pontos.
enum ScreenGuard {

    /// O retângulo tem interseção suficiente com alguma tela para ser alcançável?
    /// Um terço da área já basta para dar de pegar e arrastar.
    static func isReachable(_ frame: NSRect) -> Bool {
        guard frame.width > 0, frame.height > 0 else { return false }
        let needed = frame.width * frame.height / 3
        for screen in NSScreen.screens {
            let overlap = screen.visibleFrame.intersection(frame)
            if overlap.width * overlap.height >= needed { return true }
        }
        return false
    }
}

/// Ponte entre os apps: cada um abre e fecha os outros.
/// Este arquivo é compilado nos três binários.
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
