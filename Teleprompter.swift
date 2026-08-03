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
}

private let controlPath = NSString(string: "~/.teleprompter/control").expandingTildeInPath
private let defaultScript = NSString(string: "~/Documents/teleprompter.txt").expandingTildeInPath

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
    }

    required init?(coder: NSCoder) { fatalError() }

    /// O fade vai na view de conteúdo, não na backdrop — senão o fundo e a
    /// borda também sumiriam nas pontas.
    func installFade(on view: NSView) {
        view.wantsLayer = true
        view.layer?.mask = fade
    }

    override func layout() {
        super.layout()
        fade.frame = bounds
        let y = bounds.height * 0.62
        let path = CGMutablePath()
        path.move(to: CGPoint(x: 16, y: y))
        path.addLine(to: CGPoint(x: bounds.width - 16, y: y))
        readingLine.path = path
    }
}

// MARK: - Controller

final class Prompter: NSObject, NSApplicationDelegate {

    static weak var shared: Prompter?

    private var window: PromptWindow!
    private var scrollView: NSScrollView!
    private var textView: NSTextView!
    private var flipHost: NSView!
    private var backdrop: Backdrop!
    private var status: NSTextField!

    private let defaults = UserDefaults.standard
    private var scriptPath = defaultScript
    private var scriptStamp: Date?
    private var controlStamp: Date?
    private var hotKeys: [EventHotKeyRef?] = []

    private var timer: Timer?
    private var playing = false
    private var offset: CGFloat = 0
    private var frameCount = 0

    private var fontSize: CGFloat = 34 {
        didSet {
            applyTextStyle()
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

    // MARK: Ciclo de vida

    func applicationDidFinishLaunching(_ notification: Notification) {
        Prompter.shared = self
        defaults.register(defaults: [
            Pref.w: 640.0, Pref.h: 340.0, Pref.fontSize: 34.0,
            Pref.speed: 40.0, Pref.duration: 0.0, Pref.opacity: 1.0,
            Pref.mirrored: false,
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
        startTimer()
    }

    private func buildWindow() {
        let size = CGSize(width: defaults.double(forKey: Pref.w),
                          height: defaults.double(forKey: Pref.h))
        let screen = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        var origin = NSPoint(x: screen.midX - size.width / 2, y: screen.maxY - size.height - 80)
        if defaults.object(forKey: Pref.x) != nil {
            origin = NSPoint(x: defaults.double(forKey: Pref.x), y: defaults.double(forKey: Pref.y))
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

    private func applyTextStyle() {
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = fontSize * 0.40
        paragraph.paragraphSpacing = fontSize * 0.65
        paragraph.alignment = .center

        let length = textView.textStorage?.length ?? 0
        textView.textStorage?.setAttributes([
            .font: NSFont.systemFont(ofSize: fontSize, weight: .medium),
            .foregroundColor: NSColor.white,
            .paragraphStyle: paragraph,
        ], range: NSRange(location: 0, length: length))
    }

    private func setText(_ text: String) {
        // Respiro no fim para o texto poder subir até sair da tela.
        textView.string = text + "\n\n\n"
        applyTextStyle()
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
                Ou copie um texto e use ⌥⌘V.
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
        status.stringValue = String(
            format: "%@  %@ / %@   %.0f px/s   ⌥⌘Space",
            state, Self.clock(remaining), Self.clock(total), speed)
    }

    private static func clock(_ seconds: CGFloat) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "--:--" }
        let total = Int(seconds.rounded())
        return String(format: "%d:%02d", total / 60, total % 60)
    }

    // MARK: Atalhos globais (Carbon — não exige permissão de Acessibilidade)

    private enum HotKey: UInt32 {
        case toggle = 1, faster = 2, slower = 3, top = 4, paste = 5, visibility = 6
    }

    private func installHotKeys() {
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

        let mods = UInt32(optionKey | cmdKey)
        register(kVK_Space, mods, .toggle)
        register(kVK_UpArrow, mods, .faster)
        register(kVK_DownArrow, mods, .slower)
        register(kVK_ANSI_R, mods, .top)
        register(kVK_ANSI_V, mods, .paste)
        register(kVK_ANSI_T, mods, .visibility)
    }

    private func register(_ keyCode: Int, _ mods: UInt32, _ id: HotKey) {
        var ref: EventHotKeyRef?
        let hotKeyID = EventHotKeyID(signature: OSType(0x54_50_52_4D), id: id.rawValue)  // 'TPRM'
        let status = RegisterEventHotKey(UInt32(keyCode), mods, hotKeyID,
                                        GetApplicationEventTarget(), 0, &ref)
        if status == noErr { hotKeys.append(ref) }
    }

    func handleHotKey(_ raw: UInt32) {
        switch HotKey(rawValue: raw) {
        case .toggle: playing.toggle()
        case .faster: bumpSpeed(8)
        case .slower: bumpSpeed(-8)
        case .top: apply(command: "top")
        case .paste: loadFromClipboard()
        case .visibility: toggleVisibility()
        case .none: break
        }
        updateStatus()
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
        case "paste": loadFromClipboard()
        case "load":
            if !arg.isEmpty {
                scriptPath = (arg as NSString).expandingTildeInPath
                defaults.set(scriptPath, forKey: Pref.script)
                loadScript()
            }
        case "reload": loadScript()
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
        recomputeSpeedFromDuration()
    }

    private func savePosition() {
        defaults.set(Double(window.frame.origin.x), forKey: Pref.x)
        defaults.set(Double(window.frame.origin.y), forKey: Pref.y)
    }

    func quit() {
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
        case "q", "\u{1B}": prompter?.quit()
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

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let prompter = Prompter()
app.delegate = prompter
app.run()
