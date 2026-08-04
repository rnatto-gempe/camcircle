import AppKit
import Carbon.HIToolbox

// MARK: - Preferências

private enum Pref {
    static let x = "tpX", y = "tpY", w = "tpW", h = "tpH"
    static let fontSize = "tpFontSize"
    static let speed = "tpSpeed"
    static let duration = "tpDuration"
    static let opacity = "tpOpacity"
    static let mirrored = "tpMirrored"
    static let script = "tpScript"
    static let passThrough = "tpPassThrough"
    static let hotkeys = "tpHotkeys"
}

private let controlPath = NSString(string: "~/.teleprompter/control").expandingTildeInPath
private let defaultScript = NSString(string: "~/Documents/teleprompter.txt").expandingTildeInPath

/// Altura da linha de leitura, medida do topo do painel. O texto começa nela e
/// sobe a partir dali — por isso a mesma constante serve para desenhar a linha e
/// para calcular o espaçador inicial.
private let readingLineFromTop: CGFloat = 0.38

// MARK: - Janela

/// Painel não-ativador: clicar nele não tira o foco do app que você está usando.
/// `sharingType = .none` é o que o torna invisível para gravação e
/// compartilhamento de tela.
final class PromptWindow: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

// MARK: - Fundo

final class Backdrop: NSView {

    private let fade = CAGradientLayer()
    private let readingLine = CAShapeLayer()
    private let passOutline = CAShapeLayer()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.withAlphaComponent(0.84).cgColor
        layer?.cornerRadius = 14
        layer?.masksToBounds = true
        layer?.borderWidth = 1
        layer?.borderColor = NSColor.white.withAlphaComponent(0.12).cgColor

        // O texto surge e desaparece nas pontas em vez de cortar seco.
        fade.colors = [
            NSColor.clear.cgColor, NSColor.white.cgColor,
            NSColor.white.cgColor, NSColor.clear.cgColor,
        ]
        fade.locations = [0, 0.15, 0.85, 1]
        fade.startPoint = CGPoint(x: 0.5, y: 0)
        fade.endPoint = CGPoint(x: 0.5, y: 1)

        // Linha de leitura: onde fixar o olhar.
        readingLine.strokeColor = NSColor(srgbRed: 0.42, green: 0.78, blue: 0.98, alpha: 0.45).cgColor
        readingLine.lineWidth = 1
        layer?.addSublayer(readingLine)

        // Contorno tracejado: sinaliza que os cliques estão atravessando o painel.
        passOutline.fillColor = NSColor.clear.cgColor
        passOutline.strokeColor = NSColor(srgbRed: 0.42, green: 0.78, blue: 0.98, alpha: 0.75).cgColor
        passOutline.lineWidth = 2
        passOutline.lineDashPattern = [6, 4]
        passOutline.isHidden = true
        layer?.addSublayer(passOutline)
    }

    required init?(coder: NSCoder) { fatalError() }

    /// No modo atravessa-cliques a borda fica tracejada, para você nunca ficar
    /// sem saber por que o painel não responde ao mouse.
    func setPassThrough(_ on: Bool) {
        passOutline.isHidden = !on
        layer?.borderColor = on
            ? NSColor.clear.cgColor
            : NSColor.white.withAlphaComponent(0.12).cgColor
    }

    /// O fade vai na view de conteúdo, não na backdrop — senão o fundo e a
    /// borda também sumiriam nas pontas.
    func installFade(on view: NSView) {
        view.wantsLayer = true
        view.layer?.mask = fade
    }

    override func layout() {
        super.layout()
        fade.frame = bounds
        let y = bounds.height * (1 - readingLineFromTop)
        let path = CGMutablePath()
        path.move(to: CGPoint(x: 16, y: y))
        path.addLine(to: CGPoint(x: bounds.width - 16, y: y))
        readingLine.path = path

        passOutline.frame = bounds
        passOutline.path = CGPath(roundedRect: bounds.insetBy(dx: 1, dy: 1),
                                  cornerWidth: 13, cornerHeight: 13, transform: nil)
    }
}

// MARK: - Painel de ajuda

/// Cartão com os comandos. Também invisível na captura, e nunca vira janela ativa.
final class HelpPanel {

    private var window: NSWindow?

    /// Chave vazia = título de seção.
    private static let items: [(String, String)] = [
        ("", "TEXTO"),
        ("⌃⌥⌘V", "carrega o texto do clipboard"),
        ("cam tp edit", "abre o roteiro no editor (recarrega ao salvar)"),
        ("cam tp load ARQ", "usa outro arquivo como roteiro"),
        ("cam tp paste", "mesmo que ⌃⌥⌘V"),

        ("", "VELOCIDADE"),
        ("cam tp time 3:00", "calcula a velocidade para durar esse tempo"),
        ("cam tp speed 60", "velocidade fixa em px/s"),
        ("⌃⌥⌘Space", "play / pause"),
        ("⌃⌥⌘↑  ⌃⌥⌘↓", "mais rápido / mais lento"),
        ("⌃⌥⌘R", "volta ao início"),

        ("", "APARÊNCIA"),
        ("⌃⌥⌘[  ⌃⌥⌘]", "menos / mais opaco"),
        ("cam tp opacity 0.6", "opacidade direta (0.25 a 1)"),
        ("+  −", "fonte (com o mouse ativo)"),
        ("cam tp font 40", "tamanho da fonte"),
        ("M", "espelhar, para vidro de teleprompter"),

        ("", "POSIÇÃO"),
        ("⌃⌥⌘⇧ setas", "move o painel pelo teclado"),
        ("arrastar", "move (com o mouse ativo)"),
        ("⌥ arrastar", "redimensiona (com o mouse ativo)"),

        ("", "O OUTRO APP"),
        ("⌃⌥⌘C", "abre / fecha o círculo da câmera"),
        ("cam", "abre o círculo pelo terminal"),

        ("", "MOUSE E JANELA"),
        ("⌃⌥⌘L", "cliques atravessam o painel (liga/desliga)"),
        ("⌃⌥⌘T", "esconde / mostra o painel"),
        ("⌃⌥⌘/", "abre e fecha esta ajuda"),
        ("Q", "sair"),
    ]

    var isVisible: Bool { window != nil }

    func toggle(relativeTo host: NSWindow) {
        isVisible ? hide() : show(relativeTo: host)
    }

    func hide() {
        window?.orderOut(nil)
        window = nil
    }

    private func show(relativeTo host: NSWindow) {
        let text = NSTextField(labelWithAttributedString: Self.list())
        text.translatesAutoresizingMaskIntoConstraints = false

        let backdrop = NSVisualEffectView()
        backdrop.material = .hudWindow
        backdrop.blendingMode = .behindWindow
        backdrop.state = .active
        backdrop.wantsLayer = true
        backdrop.layer?.cornerRadius = 14
        backdrop.layer?.masksToBounds = true
        backdrop.addSubview(text)

        let pad: CGFloat = 20
        NSLayoutConstraint.activate([
            text.leadingAnchor.constraint(equalTo: backdrop.leadingAnchor, constant: pad),
            text.trailingAnchor.constraint(equalTo: backdrop.trailingAnchor, constant: -pad),
            text.topAnchor.constraint(equalTo: backdrop.topAnchor, constant: pad),
            text.bottomAnchor.constraint(equalTo: backdrop.bottomAnchor, constant: -pad),
        ])

        let size = text.intrinsicContentSize
        let frame = NSRect(x: 0, y: 0, width: size.width + pad * 2, height: size.height + pad * 2)

        let panel = NSWindow(contentRect: frame, styleMask: [.borderless],
                             backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = host.level
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.sharingType = .none          // a ajuda também não entra na gravação
        panel.contentView = backdrop
        panel.setFrame(Self.position(frame, near: host), display: false)

        host.addChildWindow(panel, ordered: .above)
        panel.orderFront(nil)
        window = panel
    }

    private static func position(_ frame: NSRect, near host: NSWindow) -> NSRect {
        let hostFrame = host.frame
        let visible = (host.screen ?? NSScreen.main)?.visibleFrame
            ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let gap: CGFloat = 10

        // Abaixo do painel; se não couber, acima.
        var y = hostFrame.minY - frame.height - gap
        if y < visible.minY { y = hostFrame.maxY + gap }
        y = min(max(y, visible.minY + gap), visible.maxY - frame.height - gap)

        var x = hostFrame.midX - frame.width / 2
        x = min(max(x, visible.minX + gap), visible.maxX - frame.width - gap)
        return NSRect(x: x, y: y, width: frame.width, height: frame.height)
    }

    private static func list() -> NSAttributedString {
        let result = NSMutableAttributedString()
        result.append(NSAttributedString(string: "Teleprompter · comandos\n", attributes: [
            .font: NSFont.systemFont(ofSize: 13, weight: .semibold),
            .foregroundColor: NSColor.white,
        ]))

        let paragraph = NSMutableParagraphStyle()
        paragraph.tabStops = [NSTextTab(textAlignment: .left, location: 150, options: [:])]
        paragraph.lineSpacing = 3

        let keyFont = NSFont.monospacedSystemFont(ofSize: 11, weight: .semibold)
        let bodyFont = NSFont.systemFont(ofSize: 11.5)

        for (key, action) in items {
            if key.isEmpty {
                result.append(NSAttributedString(string: "\n" + action + "\n", attributes: [
                    .font: NSFont.systemFont(ofSize: 9.5, weight: .semibold),
                    .foregroundColor: NSColor(srgbRed: 0.42, green: 0.78, blue: 0.98, alpha: 0.95),
                    .kern: 1.2,
                ]))
                continue
            }
            let line = NSMutableAttributedString(string: key, attributes: [
                .font: keyFont, .foregroundColor: NSColor.white, .paragraphStyle: paragraph,
            ])
            line.append(NSAttributedString(string: "\t" + action + "\n", attributes: [
                .font: bodyFont,
                .foregroundColor: NSColor.white.withAlphaComponent(0.75),
                .paragraphStyle: paragraph,
            ]))
            result.append(line)
        }
        return result
    }
}

// MARK: - Controller

final class Prompter: NSObject, NSApplicationDelegate, NSMenuDelegate {

    static weak var shared: Prompter?

    private var window: PromptWindow!
    private var scrollView: NSScrollView!
    private var textView: NSTextView!
    private var flipHost: NSView!
    private var backdrop: Backdrop!
    private var status: NSTextField!

    private let defaults = UserDefaults.standard
    private let help = HelpPanel()
    private var bodyText = ""
    private var scriptPath = defaultScript
    private var scriptStamp: Date?
    private var controlStamp: Date?
    private var hotKeys: [EventHotKeyRef?] = []
    private var statusItem: NSStatusItem?
    private var hotKeyFailures: [String] = []

    private var timer: Timer?
    private var playing = false
    private var offset: CGFloat = 0
    private var frameCount = 0

    private var fontSize: CGFloat = 34 {
        didSet {
            render()
            recomputeSpeedFromDuration()
            defaults.set(Double(fontSize), forKey: Pref.fontSize)
        }
    }

    /// Velocidade em pixels por segundo.
    private var speed: CGFloat = 40 {
        didSet { defaults.set(Double(speed), forKey: Pref.speed) }
    }

    /// Se > 0, a velocidade é derivada deste tempo total (em segundos).
    private var duration: CGFloat = 0 {
        didSet {
            recomputeSpeedFromDuration()
            defaults.set(Double(duration), forKey: Pref.duration)
        }
    }

    private var mirrored = false {
        didSet { applyMirror(); defaults.set(mirrored, forKey: Pref.mirrored) }
    }

    /// Cliques atravessam o painel e chegam no que está atrás dele.
    /// Só pode ser alternado por atalho global — com os cliques atravessando,
    /// não haveria como clicar no painel para desligar.
    private var passThrough = false {
        didSet {
            window.ignoresMouseEvents = passThrough
            backdrop.setPassThrough(passThrough)
            defaults.set(passThrough, forKey: Pref.passThrough)
            updateStatus()
        }
    }

    // MARK: Ciclo de vida

    func applicationDidFinishLaunching(_ notification: Notification) {
        Prompter.shared = self
        defaults.register(defaults: [
            Pref.w: 640.0, Pref.h: 340.0, Pref.fontSize: 34.0,
            Pref.speed: 40.0, Pref.duration: 0.0, Pref.opacity: 1.0,
            Pref.mirrored: false, Pref.passThrough: false, Pref.hotkeys: true,
        ])

        // Roteiro: argumento da linha de comando, ou o último usado, ou o padrão.
        if let arg = CommandLine.arguments.dropFirst().first, !arg.hasPrefix("-") {
            scriptPath = (arg as NSString).expandingTildeInPath
        } else if let saved = defaults.string(forKey: Pref.script) {
            scriptPath = saved
        }
        defaults.set(scriptPath, forKey: Pref.script)

        buildWindow()
        loadScript()
        installHotKeys()
        installStatusItem()
        startTimer()
    }

    private func buildWindow() {
        let size = CGSize(width: defaults.double(forKey: Pref.w),
                          height: defaults.double(forKey: Pref.h))
        let screen = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        var origin = NSPoint(x: screen.midX - size.width / 2, y: screen.maxY - size.height - 80)
        if defaults.object(forKey: Pref.x) != nil {
            let saved = NSPoint(x: defaults.double(forKey: Pref.x),
                                y: defaults.double(forKey: Pref.y))
            // Descarta posição que não existe mais em nenhuma tela: desconectar
            // um monitor externo deixaria o painel fora de alcance.
            if ScreenGuard.isReachable(NSRect(origin: saved, size: size)) {
                origin = saved
            } else {
                // Regrava com a posição válida, senão o descarte se repete sempre.
                defaults.set(Double(origin.x), forKey: Pref.x)
                defaults.set(Double(origin.y), forKey: Pref.y)
            }
        }

        window = PromptWindow(contentRect: NSRect(origin: origin, size: size),
                              styleMask: [.borderless, .nonactivatingPanel],
                              backing: .buffered, defer: false)
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = true
        window.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.overlayWindow)))
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        window.alphaValue = CGFloat(defaults.double(forKey: Pref.opacity))

        // É ISTO que esconde a janela de gravações e de compartilhamento de tela.
        window.sharingType = .none

        backdrop = Backdrop(frame: NSRect(origin: .zero, size: size))
        backdrop.autoresizingMask = [.width, .height]

        flipHost = NSView(frame: backdrop.bounds)
        flipHost.autoresizingMask = [.width, .height]
        flipHost.wantsLayer = true

        textView = NSTextView(frame: NSRect(origin: .zero, size: size))
        textView.isEditable = false
        textView.isSelectable = false
        textView.drawsBackground = false
        textView.textContainerInset = NSSize(width: 28, height: 30)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]

        scrollView = NSScrollView(frame: backdrop.bounds)
        scrollView.autoresizingMask = [.width, .height]
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = false
        scrollView.hasHorizontalScroller = false
        scrollView.documentView = textView

        // Rodapé com tempo restante e velocidade. Como a janela é invisível
        // na captura, mostrar isso não suja a gravação.
        status = NSTextField(labelWithString: "")
        status.font = NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .medium)
        status.textColor = NSColor.white.withAlphaComponent(0.5)
        status.alignment = .center
        status.frame = NSRect(x: 0, y: 6, width: size.width, height: 14)
        status.autoresizingMask = [.width]

        flipHost.addSubview(scrollView)
        backdrop.addSubview(flipHost)
        backdrop.installFade(on: flipHost)
        backdrop.addSubview(status)

        fontSize = CGFloat(defaults.double(forKey: Pref.fontSize))
        speed = CGFloat(defaults.double(forKey: Pref.speed))
        duration = CGFloat(defaults.double(forKey: Pref.duration))
        mirrored = defaults.bool(forKey: Pref.mirrored)

        window.contentView = HostView(prompter: self, backdrop: backdrop)
        window.orderFrontRegardless()
        applyMirror()
        passThrough = defaults.bool(forKey: Pref.passThrough)
    }

    /// Espelha na horizontal, para uso com vidro de teleprompter.
    private func applyMirror() {
        guard let layer = flipHost.layer else { return }
        let w = flipHost.bounds.width
        layer.transform = mirrored
            ? CATransform3DConcat(CATransform3DMakeScale(-1, 1, 1),
                                  CATransform3DMakeTranslation(w, 0, 0))
            : CATransform3DIdentity
    }

    // MARK: Texto

    /// Monta o texto com espaçadores: um na frente, para a primeira linha nascer
    /// na linha de leitura em vez de no topo; outro no fim, para a última linha
    /// conseguir subir até lá. Os dois dependem da altura do painel, então isto
    /// roda de novo a cada redimensionamento.
    private func render() {
        guard let storage = textView.textStorage else { return }

        let panelHeight = scrollView.contentView.bounds.height
        let lineFromTop = panelHeight * readingLineFromTop
        let inset = textView.textContainerInset.height

        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = fontSize * 0.40
        paragraph.paragraphSpacing = fontSize * 0.65
        paragraph.alignment = .center

        let body = NSAttributedString(string: bodyText, attributes: [
            .font: NSFont.systemFont(ofSize: fontSize, weight: .medium),
            .foregroundColor: NSColor.white,
            .paragraphStyle: paragraph,
        ])

        let result = NSMutableAttributedString()
        result.append(Self.spacer(lineFromTop - inset))
        result.append(body)
        result.append(Self.spacer(panelHeight - lineFromTop))
        storage.setAttributedString(result)
    }

    /// Uma quebra de linha com altura exata, usada como espaçador.
    private static func spacer(_ height: CGFloat) -> NSAttributedString {
        guard height > 1 else { return NSAttributedString() }
        let paragraph = NSMutableParagraphStyle()
        paragraph.minimumLineHeight = height
        paragraph.maximumLineHeight = height
        return NSAttributedString(string: "\n", attributes: [
            .font: NSFont.systemFont(ofSize: 1),
            .paragraphStyle: paragraph,
        ])
    }

    private func setText(_ text: String) {
        bodyText = text
        render()
        offset = 0
        scrollView.contentView.scroll(to: .zero)
        scrollView.reflectScrolledClipView(scrollView.contentView)
        recomputeSpeedFromDuration()
    }

    private func loadScript() {
        if let raw = try? String(contentsOfFile: scriptPath, encoding: .utf8),
           !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            setText(raw)
        } else {
            setText("""
                Nenhum roteiro carregado.

                Escreva em \(scriptPath) — recarrega ao salvar.
                Ou copie um texto e use ⌃⌥⌘V.
                """)
        }
        scriptStamp = modified(scriptPath)
    }

    private func loadFromClipboard() {
        guard let text = NSPasteboard.general.string(forType: .string),
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        setText(text)
        scriptStamp = nil          // passa a mostrar o clipboard, não o arquivo
    }

    private func modified(_ path: String) -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: path)[.modificationDate]) as? Date
    }

    // MARK: Rolagem

    /// Altura real do texto renderizado.
    private var contentHeight: CGFloat {
        guard let manager = textView.layoutManager, let container = textView.textContainer
        else { return textView.frame.height }
        manager.ensureLayout(for: container)
        return manager.usedRect(for: container).height + textView.textContainerInset.height * 2
    }

    private var maxOffset: CGFloat {
        max(0, contentHeight - scrollView.contentView.bounds.height)
    }

    /// Com tempo definido, a velocidade sai da conta: percurso ÷ tempo.
    private func recomputeSpeedFromDuration() {
        guard duration > 0 else { return }
        let distance = maxOffset
        guard distance > 0 else { return }
        speed = max(1, distance / duration)
    }

    private func startTimer() {
        timer = Timer.scheduledTimer(withTimeInterval: 1.0 / 60, repeats: true) { [weak self] _ in
            self?.tick()
        }
    }

    private func tick() {
        if playing {
            offset += speed / 60
            let limit = maxOffset
            if offset >= limit {
                offset = limit
                playing = false
            }
            scrollView.contentView.scroll(to: NSPoint(x: 0, y: offset))
            scrollView.reflectScrolledClipView(scrollView.contentView)
        }

        frameCount += 1
        if frameCount % 10 == 0 { updateStatus() }

        // 4x por segundo: recarrega o roteiro e lê comandos da CLI.
        guard frameCount % 15 == 0 else { return }
        if scriptStamp != nil, let stamp = modified(scriptPath), stamp != scriptStamp {
            loadScript()
        }
        if let stamp = modified(controlPath), stamp != controlStamp {
            controlStamp = stamp
            if let raw = try? String(contentsOfFile: controlPath, encoding: .utf8) {
                let line = raw.split(separator: "\n").first.map(String.init) ?? ""
                apply(command: line.trimmingCharacters(in: .whitespaces))
            }
        }
    }

    private func updateStatus() {
        let remaining = speed > 0 ? (maxOffset - offset) / speed : 0
        let total = speed > 0 ? maxOffset / speed : 0
        let state = playing ? "▶" : "❙❙"
        let mouse = passThrough ? "⇢ cliques passam" : "mouse ativo"
        var line = String(
            format: "%@  %@ / %@   %.0f px/s   ·   %@ (⌃⌥⌘L)   ·   ajuda ⌃⌥⌘/",
            state, Self.clock(remaining), Self.clock(total), speed, mouse)
        if !hotKeyFailures.isEmpty {
            line += "   ·   ⚠ em conflito: " + hotKeyFailures.joined(separator: " ")
        }
        status.stringValue = line
    }

    private static func clock(_ seconds: CGFloat) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "--:--" }
        let total = Int(seconds.rounded())
        return String(format: "%d:%02d", total / 60, total % 60)
    }

    // MARK: Item na barra de menus

    /// O painel é invisível na captura e ignora o mouse no modo atravessa —
    /// sem um item na barra, um usuário que não decorou os atalhos não tem
    /// como controlar nem encerrar o app.
    private func installStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.image = NSImage(systemSymbolName: "text.alignleft",
                                    accessibilityDescription: "Teleprompter")
        item.button?.image?.isTemplate = true

        let menu = NSMenu()
        menu.delegate = self
        item.menu = menu
        statusItem = item
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()

        add(menu, playing ? "Pausar" : "Rolar", #selector(menuToggle))
        add(menu, "Voltar ao início", #selector(menuTop))
        menu.addItem(.separator())

        let info = NSMenuItem(title: String(format: "Duração: %@ · %.0f px/s",
                                            Self.clock(maxOffset / max(speed, 1)), speed),
                              action: nil, keyEquivalent: "")
        info.isEnabled = false
        menu.addItem(info)
        for (title, seconds) in [("1 minuto", 60.0), ("3 minutos", 180.0), ("5 minutos", 300.0)] {
            let item = add(menu, "   Ajustar para \(title)", #selector(menuDuration(_:)))
            item.representedObject = seconds
        }
        menu.addItem(.separator())

        add(menu, "Colar texto do clipboard", #selector(menuPaste))
        add(menu, "Abrir roteiro no editor", #selector(menuEditScript))
        menu.addItem(.separator())

        add(menu, "Cliques atravessam o painel", #selector(menuPass), on: passThrough)
        add(menu, "Espelhar", #selector(menuMirror), on: mirrored)
        add(menu, "Atalhos…", #selector(menuHelpItem), on: help.isVisible)
        menu.addItem(.separator())

        add(menu, Companion.isRunning(bundleID: "com.startse.camcircle")
            ? "Fechar câmera" : "Abrir câmera", #selector(menuCamera))
        add(menu, "Sair", #selector(menuQuitItem))
    }

    @discardableResult
    private func add(_ menu: NSMenu, _ title: String, _ action: Selector,
                     on: Bool? = nil) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        if let on { item.state = on ? .on : .off }
        menu.addItem(item)
        return item
    }

    @objc private func menuToggle() { toggle() }
    @objc private func menuTop() { apply(command: "top") }
    @objc private func menuDuration(_ sender: NSMenuItem) {
        if let seconds = sender.representedObject as? Double { duration = CGFloat(seconds) }
    }
    @objc private func menuPaste() { apply(command: "paste") }
    @objc private func menuEditScript() {
        NSWorkspace.shared.open(URL(fileURLWithPath: scriptPath))
    }
    @objc private func menuPass() { passThrough.toggle() }
    @objc private func menuMirror() { mirrored.toggle() }
    @objc private func menuHelpItem() { help.toggle(relativeTo: window) }
    @objc private func menuCamera() {
        Companion.toggle(name: "CamCircle", bundleID: "com.startse.camcircle")
    }
    @objc private func menuQuitItem() { quit() }

    // MARK: Atalhos globais (Carbon — não exige permissão de Acessibilidade)

    private enum HotKey: UInt32 {
        case toggle = 1, faster = 2, slower = 3, top = 4, paste = 5, visibility = 6
        case passThrough = 7
        case moveUp = 8, moveDown = 9, moveLeft = 10, moveRight = 11
        case dimmer = 12, brighter = 13, help = 14
        case camera = 15
    }

    private func installHotKeys() {
        // Escape hatch: `cam tp hotkeys off` desliga tudo isso.
        guard defaults.bool(forKey: Pref.hotkeys) else { return }

        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                                 eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ -> OSStatus in
            var id = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject),
                              EventParamType(typeEventHotKeyID), nil,
                              MemoryLayout<EventHotKeyID>.size, nil, &id)
            let value = id.id
            DispatchQueue.main.async { Prompter.shared?.handleHotKey(value) }
            return noErr
        }, 1, &spec, nil, nil)

        // ⌃⌥⌘ de propósito. Um atalho registrado pelo Carbon tem precedência sobre
        // o do sistema, então usar option+command sequestraria globalmente coisas
        // como "Mover item aqui" (⌥⌘V no Finder) e a busca do Finder (⌥⌘Space).
        // ⌃⌥⌘ é a combinação que o macOS praticamente não reivindica.
        let mods = UInt32(controlKey | optionKey | cmdKey)
        register(kVK_Space, mods, .toggle, "⌃⌥⌘Space")
        register(kVK_UpArrow, mods, .faster, "⌃⌥⌘↑")
        register(kVK_DownArrow, mods, .slower, "⌃⌥⌘↓")
        register(kVK_ANSI_R, mods, .top, "⌃⌥⌘R")
        register(kVK_ANSI_V, mods, .paste, "⌃⌥⌘V")
        register(kVK_ANSI_T, mods, .visibility, "⌃⌥⌘T")
        register(kVK_ANSI_L, mods, .passThrough, "⌃⌥⌘L")
        register(kVK_ANSI_LeftBracket, mods, .dimmer, "⌃⌥⌘[")
        register(kVK_ANSI_RightBracket, mods, .brighter, "⌃⌥⌘]")
        register(kVK_ANSI_Slash, mods, .help, "⌃⌥⌘/")
        register(kVK_ANSI_C, mods, .camera, "⌃⌥⌘C")

        // Mover pelo teclado: no modo atravessa-cliques não há como arrastar.
        let moveMods = UInt32(controlKey | optionKey | cmdKey | shiftKey)
        register(kVK_UpArrow, moveMods, .moveUp, "⌃⌥⌘⇧↑")
        register(kVK_DownArrow, moveMods, .moveDown, "⌃⌥⌘⇧↓")
        register(kVK_LeftArrow, moveMods, .moveLeft, "⌃⌥⌘⇧←")
        register(kVK_RightArrow, moveMods, .moveRight, "⌃⌥⌘⇧→")
    }

    private func register(_ keyCode: Int, _ mods: UInt32, _ id: HotKey, _ label: String = "") {
        var ref: EventHotKeyRef?
        let hotKeyID = EventHotKeyID(signature: OSType(0x54_50_52_4D), id: id.rawValue)  // 'TPRM'
        let status = RegisterEventHotKey(UInt32(keyCode), mods, hotKeyID,
                                        GetApplicationEventTarget(), 0, &ref)
        if status == noErr {
            hotKeys.append(ref)
        } else {
            // Outro app já registrou essa combinação. Silenciar isso deixaria o
            // atalho morto sem explicação.
            hotKeyFailures.append(label.isEmpty ? "\(id)" : label)
        }
    }

    func handleHotKey(_ raw: UInt32) {
        switch HotKey(rawValue: raw) {
        case .toggle: playing.toggle()
        case .faster: bumpSpeed(8)
        case .slower: bumpSpeed(-8)
        case .top: apply(command: "top")
        case .paste: loadFromClipboard()
        case .visibility: toggleVisibility()
        case .passThrough: passThrough.toggle()
        case .dimmer: setOpacity(window.alphaValue - 0.1)
        case .brighter: setOpacity(window.alphaValue + 0.1)
        case .help: help.toggle(relativeTo: window)
        case .camera: Companion.toggle(name: "CamCircle", bundleID: "com.startse.camcircle")
        case .moveUp: move(dx: 0, dy: 24)
        case .moveDown: move(dx: 0, dy: -24)
        case .moveLeft: move(dx: -24, dy: 0)
        case .moveRight: move(dx: 24, dy: 0)
        case .none: break
        }
        updateStatus()
    }

    private func move(dx: CGFloat, dy: CGFloat) {
        var frame = window.frame
        frame.origin.x += dx
        frame.origin.y += dy
        window.setFrame(frame, display: true)
        savePosition()
    }

    // MARK: Comandos

    /// Um comando por linha, opcionalmente com argumento: "time 180", "speed 60".
    func apply(command: String) {
        let parts = command.split(separator: " ", maxSplits: 1).map(String.init)
        guard let verb = parts.first else { return }
        let arg = parts.count > 1 ? parts[1] : ""

        switch verb {
        case "play": playing = true
        case "pause": playing = false
        case "toggle": playing.toggle()
        case "top":
            offset = 0
            scrollView.contentView.scroll(to: .zero)
            scrollView.reflectScrolledClipView(scrollView.contentView)
        case "faster": bumpSpeed(8)
        case "slower": bumpSpeed(-8)
        case "speed":
            if let value = Double(arg) { duration = 0; speed = max(1, CGFloat(value)) }
        case "time":
            if let seconds = Self.parseTime(arg) { duration = seconds }
        case "bigger": fontSize = min(fontSize + 3, 140)
        case "smaller": fontSize = max(fontSize - 3, 12)
        case "font":
            if let value = Double(arg) { fontSize = CGFloat(value).clamped(12, 140) }
        case "mirror": mirrored.toggle()
        case "dimmer": setOpacity(window.alphaValue - 0.1)
        case "brighter": setOpacity(window.alphaValue + 0.1)
        case "opacity":
            if let value = Double(arg) {
                // Aceita 0.6 ou 60.
                setOpacity(value > 1 ? CGFloat(value / 100) : CGFloat(value))
            }
        case "help", "keys": help.toggle(relativeTo: window)
        case "camera", "cam":
            Companion.toggle(name: "CamCircle", bundleID: "com.startse.camcircle")
        case "hotkeys":
            let on = !(arg == "off" || arg == "false" || arg == "0")
            defaults.set(on, forKey: Pref.hotkeys)
        case "paste": loadFromClipboard()
        case "load":
            if !arg.isEmpty {
                scriptPath = (arg as NSString).expandingTildeInPath
                defaults.set(scriptPath, forKey: Pref.script)
                loadScript()
            }
        case "reload": loadScript()
        case "pass", "click", "clickthrough":
            switch arg {
            case "on", "true", "1": passThrough = true
            case "off", "false", "0": passThrough = false
            default: passThrough.toggle()
            }
        case "hide": window.orderOut(nil)
        case "show": window.orderFrontRegardless()
        case "visibility": toggleVisibility()
        case "quit": quit()
        default: break
        }
        updateStatus()
    }

    /// Aceita "180", "3:00" ou "3m".
    private static func parseTime(_ text: String) -> CGFloat? {
        if text.contains(":") {
            let parts = text.split(separator: ":").compactMap { Double($0) }
            guard parts.count == 2 else { return nil }
            return CGFloat(parts[0] * 60 + parts[1])
        }
        if text.hasSuffix("m"), let minutes = Double(text.dropLast()) {
            return CGFloat(minutes * 60)
        }
        if let seconds = Double(text) { return CGFloat(seconds) }
        return nil
    }

    private func bumpSpeed(_ delta: CGFloat) {
        duration = 0                     // mexer na velocidade abandona o modo tempo
        speed = (speed + delta).clamped(4, 500)
    }

    private func toggleVisibility() {
        window.isVisible ? window.orderOut(nil) : window.orderFrontRegardless()
    }

    // MARK: Interação

    func toggle() { playing.toggle(); updateStatus() }

    func nudge(_ delta: CGFloat) {
        offset = (offset + delta).clamped(0, maxOffset)
        scrollView.contentView.scroll(to: NSPoint(x: 0, y: offset))
        scrollView.reflectScrolledClipView(scrollView.contentView)
        updateStatus()
    }

    func changeSpeed(_ delta: CGFloat) { bumpSpeed(delta); updateStatus() }
    func changeFont(_ delta: CGFloat) { fontSize = (fontSize + delta).clamped(12, 140) }
    func toggleMirror() { mirrored.toggle() }
    func restart() { apply(command: "top") }
    func nudgeOpacity(_ delta: CGFloat) { setOpacity(window.alphaValue + delta) }

    func setOpacity(_ value: CGFloat) {
        let clamped = value.clamped(0.25, 1.0)
        window.alphaValue = clamped
        defaults.set(Double(clamped), forKey: Pref.opacity)
    }

    func drag(with event: NSEvent) {
        window.performDrag(with: event)
        savePosition()
    }

    /// Redimensiona com option + arraste.
    func resize(by delta: CGSize) {
        var frame = window.frame
        frame.size.width = (frame.width + delta.width).clamped(280, 2400)
        frame.size.height = (frame.height + delta.height).clamped(140, 1600)
        frame.origin.y -= delta.height          // cresce para baixo
        window.setFrame(frame, display: true)
        defaults.set(Double(frame.width), forKey: Pref.w)
        defaults.set(Double(frame.height), forKey: Pref.h)
        applyMirror()
        render()                  // os espaçadores dependem da altura do painel
        recomputeSpeedFromDuration()
    }

    private func savePosition() {
        defaults.set(Double(window.frame.origin.x), forKey: Pref.x)
        defaults.set(Double(window.frame.origin.y), forKey: Pref.y)
    }

    func toggleHelp() { help.toggle(relativeTo: window) }
    var isHelpVisible: Bool { help.isVisible }
    func hideHelp() { help.hide() }

    func quit() {
        help.hide()
        savePosition()
        NSApp.terminate(nil)
    }
}

// MARK: - Eventos

final class HostView: NSView {

    private weak var prompter: Prompter?
    private var resizeAnchor: NSPoint?

    init(prompter: Prompter, backdrop: NSView) {
        self.prompter = prompter
        super.init(frame: backdrop.frame)
        autoresizesSubviews = true
        backdrop.autoresizingMask = [.width, .height]
        addSubview(backdrop)
    }

    required init?(coder: NSCoder) { fatalError() }

    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        if event.modifierFlags.contains(.option) {
            resizeAnchor = NSEvent.mouseLocation
        } else {
            prompter?.drag(with: event)
        }
    }

    override func mouseDragged(with event: NSEvent) {
        guard let anchor = resizeAnchor else { return }
        let now = NSEvent.mouseLocation
        prompter?.resize(by: CGSize(width: now.x - anchor.x, height: anchor.y - now.y))
        resizeAnchor = now
    }

    override func mouseUp(with event: NSEvent) { resizeAnchor = nil }

    override func scrollWheel(with event: NSEvent) {
        prompter?.nudge(-event.scrollingDeltaY * 2)
    }

    override func keyDown(with event: NSEvent) {
        switch event.charactersIgnoringModifiers?.lowercased() ?? "" {
        case " ": prompter?.toggle()
        case "h", "?": prompter?.toggleHelp()
        case "\u{1B}":                     // Esc fecha a ajuda antes de encerrar
            if prompter?.isHelpVisible == true { prompter?.hideHelp() } else { prompter?.quit() }
        case "q": prompter?.quit()
        case "r": prompter?.restart()
        case "m": prompter?.toggleMirror()
        case "v": prompter?.apply(command: "paste")
        case "+", "=": prompter?.changeFont(3)
        case "-", "_": prompter?.changeFont(-3)
        case "[": prompter?.nudgeOpacity(-0.1)
        case "]": prompter?.nudgeOpacity(0.1)
        case String(UnicodeScalar(NSUpArrowFunctionKey)!):    prompter?.changeSpeed(6)
        case String(UnicodeScalar(NSDownArrowFunctionKey)!):  prompter?.changeSpeed(-6)
        case String(UnicodeScalar(NSLeftArrowFunctionKey)!):  prompter?.nudge(-40)
        case String(UnicodeScalar(NSRightArrowFunctionKey)!): prompter?.nudge(40)
        default: super.keyDown(with: event)
        }
    }
}

private extension CGFloat {
    func clamped(_ lo: CGFloat, _ hi: CGFloat) -> CGFloat { Swift.min(Swift.max(self, lo), hi) }
}

// MARK: - main

// @main em vez de código no topo do arquivo: com mais de um fonte no módulo
// (Companion.swift), o Swift só aceita top-level code em main.swift.
@main
struct TeleprompterApp {
    /// Retém o delegate — NSApplication.delegate é weak.
    static let prompter = Prompter()

    static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        app.delegate = prompter
        app.run()
    }
}
