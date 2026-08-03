import AppKit
import AVFoundation
import Carbon.HIToolbox
import Speech

// MARK: - Preferências

private enum Pref {
    static let x = "ccX", y = "ccY", w = "ccW", h = "ccH"
    static let fontSize = "ccFontSize"
    static let opacity = "ccOpacity"
    static let passThrough = "ccPassThrough"
    static let hotkeys = "ccHotkeys"
    static let locale = "ccLocale"
    static let listening = "ccListening"
    static let systemAudio = "ccSystemAudio"
}

private let controlPath = NSString(string: "~/.teleprompter/captions-control").expandingTildeInPath

// MARK: - Transcrição contínua

/// Transcreve o microfone indefinidamente, on-device.
///
/// O `SFSpeechRecognizer` não sustenta uma sessão longa: medi que uma requisição
/// de 100s devolve só uma janela do áudio, não o todo. A saída é rotacionar a
/// requisição — e a rotação ingênua perde ou duplica palavras na emenda.
///
/// Aqui a virada é feita com sobreposição: a requisição nova começa a receber
/// áudio ANTES de a antiga ser encerrada, então nada se perde no vão. O trecho
/// que as duas ouviram é removido por casamento de palavras, então nada duplica.
final class Transcriber: NSObject, SFSpeechRecognizerDelegate {

    /// Depois de quanto tempo trocar de requisição. Bem abaixo do limite medido.
    private let rotateAfter: TimeInterval = 40
    /// Quanto tempo as duas requisições recebem áudio em paralelo.
    private let overlap: TimeInterval = 2.0

    private var recognizer: SFSpeechRecognizer?

    /// Requisição que está no ar e alimenta o texto provisório.
    private var live: SFSpeechAudioBufferRecognitionRequest?
    private var liveTask: SFSpeechRecognitionTask?
    /// Requisição antiga, ainda recebendo áudio durante a sobreposição.
    private var fading: SFSpeechAudioBufferRecognitionRequest?

    private var rotateTimer: Timer?
    private var committed: [String] = []
    private var partial: [String] = []

    private(set) var isListening = false
    private(set) var lastError: String?

    /// (texto confirmado, texto provisório)
    var onUpdate: ((String, String) -> Void)?
    var onStateChange: (() -> Void)?

    var localeID: String {
        didSet { if isListening { restart() } }
    }

    init(localeID: String) {
        self.localeID = localeID
        super.init()
    }

    var text: String {
        let all = committed + partial
        return all.joined(separator: " ")
    }

    // MARK: Ciclo

    /// Só o reconhecimento: o áudio entra por `feed`, venha do microfone ou do
    /// tap da saída do sistema. É o que permite as duas fontes usarem a mesma
    /// lógica de rotação e costura.
    func start() {
        guard !isListening else { return }
        lastError = nil

        SFSpeechRecognizer.requestAuthorization { [weak self] status in
            DispatchQueue.main.async {
                guard let self else { return }
                guard status == .authorized else {
                    self.fail("Reconhecimento de fala não autorizado. Libere em Ajustes do Sistema › Privacidade e Segurança › Reconhecimento de Fala.")
                    return
                }
                self.begin()
            }
        }
    }

    private func begin() {
        guard let rec = SFSpeechRecognizer(locale: Locale(identifier: localeID)) else {
            fail("Idioma \(localeID) não suportado.")
            return
        }
        rec.delegate = self
        // Só interessa o modo local: nada de áudio saindo da máquina.
        guard rec.supportsOnDeviceRecognition else {
            fail("Sem modelo on-device para \(localeID). Ative o Ditado nesse idioma em Ajustes do Sistema › Teclado › Ditado.")
            return
        }
        recognizer = rec

        rotate(initial: true)
        isListening = true
        rotateTimer = Timer.scheduledTimer(withTimeInterval: rotateAfter, repeats: true) { [weak self] _ in
            self?.rotate(initial: false)
        }
        onStateChange?()
    }

    /// Durante a sobreposição as duas requisições recebem o mesmo áudio.
    func feed(_ buffer: AVAudioPCMBuffer) {
        live?.append(buffer)
        fading?.append(buffer)
    }

    func stop() {
        rotateTimer?.invalidate()
        rotateTimer = nil
        // Encerra o áudio para a última requisição entregar o resultado final.
        live?.endAudio()
        fading?.endAudio()
        live = nil
        fading = nil
        liveTask = nil
        isListening = false
        onStateChange?()
    }

    func restart() {
        stop()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in self?.start() }
    }

    func clear() {
        committed = []
        partial = []
        publish()
    }

    /// Erro vindo da fonte de áudio, não do reconhecedor.
    func reportExternal(_ message: String) {
        lastError = message
        onStateChange?()
    }

    private func fail(_ message: String) {
        lastError = message
        isListening = false
        onStateChange?()
    }

    // MARK: Rotação

    /// Cria a requisição nova e agenda o encerramento da antiga, deixando as
    /// duas ouvindo o mesmo trecho durante `overlap` segundos.
    private func rotate(initial: Bool) {
        guard let rec = recognizer else { return }

        let request = SFSpeechAudioBufferRecognitionRequest()
        request.requiresOnDeviceRecognition = true
        request.shouldReportPartialResults = true
        request.addsPunctuation = true      // ignorado em alguns idiomas, inofensivo

        let old = live
        fading = old                        // continua recebendo áudio por `overlap`
        live = request

        liveTask = rec.recognitionTask(with: request) { [weak self] result, error in
            DispatchQueue.main.async {
                guard let self else { return }
                if let error {
                    guard self.isListening else { return }
                    let ns = error as NSError

                    // "No speech detected" (1110) não é falha: é uma sala em
                    // silêncio. Mostrar isso como erro no rodapé seria ruído
                    // permanente em qualquer pausa da fala.
                    let silence = ns.code == 1110
                        || ns.localizedDescription.lowercased().contains("no speech")
                    if !silence { self.lastError = ns.localizedDescription }
                    self.onStateChange?()

                    // A task morreu de um jeito ou de outro: sobe outra, com um
                    // respiro para não entrar em laço apertado no silêncio.
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                        guard let self, self.isListening else { return }
                        self.rotate(initial: false)
                    }
                    return
                }
                // Chegou fala: limpa um erro antigo que já não descreve o estado.
                if self.lastError != nil {
                    self.lastError = nil
                    self.onStateChange?()
                }
                guard let result else { return }
                let words = Self.words(of: result.bestTranscription.formattedString)

                if result.isFinal {
                    self.commit(words)
                    self.partial = []
                } else {
                    // Provisório: tira o pedaço que já está confirmado, senão a
                    // sobreposição apareceria duplicada na tela.
                    self.partial = Self.trimOverlap(committed: self.committed, words: words)
                }
                self.publish()
            }
        }

        guard !initial, let old else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + overlap) { [weak self] in
            guard let self else { return }
            old.endAudio()
            if self.fading === old { self.fading = nil }
        }
    }

    private func commit(_ words: [String]) {
        let fresh = Self.trimOverlap(committed: committed, words: words)
        guard !fresh.isEmpty else { return }
        committed.append(contentsOf: fresh)
        // Um teto evita a view crescer sem limite numa sessão longa.
        if committed.count > 4000 { committed.removeFirst(committed.count - 4000) }
    }

    private func publish() {
        onUpdate?(committed.joined(separator: " "), partial.joined(separator: " "))
    }

    // MARK: Costura

    private static func words(of text: String) -> [String] {
        text.split(whereSeparator: { $0.isWhitespace }).map(String.init)
    }

    /// Chave de comparação: sem caixa, sem acento e sem pontuação, porque o
    /// reconhecedor varia esses detalhes entre uma passada e outra do mesmo trecho.
    private static func key(_ word: String) -> String {
        word.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil)
            .filter { $0.isLetter || $0.isNumber }
    }

    /// Remove do início de `words` o maior trecho que já está no fim de
    /// `committed`. Prefere o casamento MAIOR: repetir palavra na tela é pior
    /// do que perder uma que o reconhecedor já havia entregado.
    static func trimOverlap(committed: [String], words: [String], maxOverlap: Int = 30) -> [String] {
        let limit = min(maxOverlap, min(committed.count, words.count))
        guard limit > 0 else { return words }

        let tail = committed.suffix(limit).map(key)
        let head = words.prefix(limit).map(key)

        var k = limit
        while k > 0 {
            if Array(tail.suffix(k)) == Array(head.prefix(k)) {
                return Array(words.dropFirst(k))
            }
            k -= 1
        }
        return words
    }

    // MARK: SFSpeechRecognizerDelegate

    func speechRecognizer(_ recognizer: SFSpeechRecognizer, availabilityDidChange available: Bool) {
        if !available, isListening {
            fail("O reconhecedor ficou indisponível.")
            stop()
        }
    }
}

// MARK: - Janela

final class CaptionWindow: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

// MARK: - Fundo

final class CaptionBackdrop: NSView {

    private let passOutline = CAShapeLayer()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.withAlphaComponent(0.84).cgColor
        layer?.cornerRadius = 14
        layer?.masksToBounds = true
        layer?.borderWidth = 1
        layer?.borderColor = NSColor.white.withAlphaComponent(0.12).cgColor

        passOutline.fillColor = NSColor.clear.cgColor
        passOutline.strokeColor = NSColor(srgbRed: 0.42, green: 0.78, blue: 0.98, alpha: 0.75).cgColor
        passOutline.lineWidth = 2
        passOutline.lineDashPattern = [6, 4]
        passOutline.isHidden = true
        layer?.addSublayer(passOutline)
    }

    required init?(coder: NSCoder) { fatalError() }

    func setPassThrough(_ on: Bool) {
        passOutline.isHidden = !on
        layer?.borderColor = on ? NSColor.clear.cgColor
                                : NSColor.white.withAlphaComponent(0.12).cgColor
    }

    override func layout() {
        super.layout()
        passOutline.frame = bounds
        passOutline.path = CGPath(roundedRect: bounds.insetBy(dx: 1, dy: 1),
                                  cornerWidth: 13, cornerHeight: 13, transform: nil)
    }
}

// MARK: - Colunas

/// Duas colunas independentes: sua fala e a saída do sistema. Com o áudio do
/// sistema desligado, a coluna do microfone ocupa a largura toda.
final class ColumnsView: NSView {

    let micScroll = NSScrollView()
    let micText = NSTextView()
    let sysScroll = NSScrollView()
    let sysText = NSTextView()

    private let micHeader = NSTextField(labelWithString: "VOCÊ")
    private let sysHeader = NSTextField(labelWithString: "SISTEMA")
    private let divider = NSBox()

    var showsSystem = false { didSet { needsLayout = true; applyVisibility() } }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)

        for (header, color) in [(micHeader, NSColor.white),
                                (sysHeader, NSColor(srgbRed: 0.42, green: 0.78, blue: 0.98, alpha: 1))] {
            header.font = NSFont.systemFont(ofSize: 9, weight: .semibold)
            header.textColor = color.withAlphaComponent(0.55)
            addSubview(header)
        }

        for (scroll, text) in [(micScroll, micText), (sysScroll, sysText)] {
            text.isEditable = false
            text.isSelectable = false
            text.drawsBackground = false
            text.textContainerInset = NSSize(width: 14, height: 8)
            text.isVerticallyResizable = true
            text.isHorizontallyResizable = false
            scroll.drawsBackground = false
            scroll.hasVerticalScroller = false
            scroll.documentView = text
            addSubview(scroll)
        }

        divider.boxType = .separator
        addSubview(divider)
        applyVisibility()
    }

    required init?(coder: NSCoder) { fatalError() }

    private func applyVisibility() {
        sysScroll.isHidden = !showsSystem
        divider.isHidden = !showsSystem
        micHeader.isHidden = !showsSystem      // sem duas colunas, rótulo é ruído
        sysHeader.isHidden = !showsSystem
    }

    override func layout() {
        super.layout()
        let headerHeight: CGFloat = showsSystem ? 16 : 0

        guard showsSystem else {
            micScroll.frame = bounds
            return
        }

        let half = (bounds.width - 1) / 2
        micHeader.frame = NSRect(x: 14, y: bounds.maxY - headerHeight,
                                 width: half - 14, height: headerHeight)
        sysHeader.frame = NSRect(x: half + 15, y: bounds.maxY - headerHeight,
                                 width: half - 14, height: headerHeight)
        micScroll.frame = NSRect(x: 0, y: 0, width: half, height: bounds.height - headerHeight)
        divider.frame = NSRect(x: half, y: 4, width: 1, height: bounds.height - headerHeight - 8)
        sysScroll.frame = NSRect(x: half + 1, y: 0, width: half, height: bounds.height - headerHeight)
    }
}

// MARK: - Controller

final class Captions: NSObject, NSApplicationDelegate, NSMenuDelegate {

    static weak var shared: Captions?

    private var window: CaptionWindow!
    private var backdrop: CaptionBackdrop!
    private var columns: ColumnsView!
    private var status: NSTextField!
    private var statusItem: NSStatusItem?

    private let defaults = UserDefaults.standard
    private var hotKeys: [EventHotKeyRef?] = []
    private var hotKeyFailures: [String] = []
    private var controlStamp: Date?
    private var pollTimer: Timer?

    /// Um par transcritor + fonte por entrada. O transcritor é o mesmo código
    /// nas duas; só a origem do áudio muda.
    private var micTranscriber: Transcriber!
    private var sysTranscriber: Transcriber!
    private let micSource = MicrophoneSource()
    private let sysSource = SystemAudioSource()

    private var micCommitted = "", micPartial = ""
    private var sysCommitted = "", sysPartial = ""

    private var fontSize: CGFloat = 20 {
        didSet { render(); defaults.set(Double(fontSize), forKey: Pref.fontSize) }
    }

    private var passThrough = false {
        didSet {
            window.ignoresMouseEvents = passThrough
            backdrop.setPassThrough(passThrough)
            defaults.set(passThrough, forKey: Pref.passThrough)
            updateStatus()
        }
    }

    private var systemAudio = false {
        didSet {
            columns.showsSystem = systemAudio
            defaults.set(systemAudio, forKey: Pref.systemAudio)
            systemAudio ? startSystem() : stopSystem()
            render()
        }
    }

    // MARK: Ciclo de vida

    func applicationDidFinishLaunching(_ notification: Notification) {
        Captions.shared = self
        defaults.register(defaults: [
            Pref.w: 820.0, Pref.h: 220.0, Pref.fontSize: 20.0, Pref.opacity: 1.0,
            Pref.passThrough: false, Pref.hotkeys: true, Pref.locale: "pt-BR",
            Pref.systemAudio: false,
        ])

        let locale = defaults.string(forKey: Pref.locale) ?? "pt-BR"
        micTranscriber = Transcriber(localeID: locale)
        sysTranscriber = Transcriber(localeID: locale)

        micTranscriber.onUpdate = { [weak self] c, p in
            self?.micCommitted = c; self?.micPartial = p; self?.render()
        }
        sysTranscriber.onUpdate = { [weak self] c, p in
            self?.sysCommitted = c; self?.sysPartial = p; self?.render()
        }
        micTranscriber.onStateChange = { [weak self] in self?.updateStatus() }
        sysTranscriber.onStateChange = { [weak self] in self?.updateStatus() }

        micSource.onBuffer = { [weak self] buffer in self?.micTranscriber.feed(buffer) }
        sysSource.onBuffer = { [weak self] buffer in self?.sysTranscriber.feed(buffer) }

        buildWindow()
        installHotKeys()
        installStatusItem()

        pollTimer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            self?.pollControl()
        }

        startMic()
        if defaults.bool(forKey: Pref.systemAudio) { systemAudio = true }
        render()
    }

    private func buildWindow() {
        let size = CGSize(width: defaults.double(forKey: Pref.w),
                          height: defaults.double(forKey: Pref.h))
        let screen = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        var origin = NSPoint(x: screen.midX - size.width / 2, y: screen.minY + 120)
        if defaults.object(forKey: Pref.x) != nil {
            origin = NSPoint(x: defaults.double(forKey: Pref.x), y: defaults.double(forKey: Pref.y))
        }

        window = CaptionWindow(contentRect: NSRect(origin: origin, size: size),
                               styleMask: [.borderless, .nonactivatingPanel],
                               backing: .buffered, defer: false)
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = true
        window.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.overlayWindow)))
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        window.alphaValue = CGFloat(defaults.double(forKey: Pref.opacity))
        window.isMovableByWindowBackground = false

        // As legendas ficam visíveis para você e ausentes da gravação.
        window.sharingType = .none

        backdrop = CaptionBackdrop(frame: NSRect(origin: .zero, size: size))
        backdrop.autoresizingMask = [.width, .height]

        columns = ColumnsView(frame: NSRect(x: 0, y: 20, width: size.width, height: size.height - 20))
        columns.autoresizingMask = [.width, .height]

        status = NSTextField(labelWithString: "")
        status.font = NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .medium)
        status.textColor = NSColor.white.withAlphaComponent(0.5)
        status.alignment = .center
        status.frame = NSRect(x: 0, y: 5, width: size.width, height: 13)
        status.autoresizingMask = [.width]

        backdrop.addSubview(columns)
        backdrop.addSubview(status)

        fontSize = CGFloat(defaults.double(forKey: Pref.fontSize))

        window.contentView = CaptionHostView(captions: self, backdrop: backdrop)
        window.orderFrontRegardless()
        passThrough = defaults.bool(forKey: Pref.passThrough)
    }

    // MARK: Fontes

    private func startMic() {
        micTranscriber.start()
        micSource.start { [weak self] error in
            if let error { self?.micTranscriber.reportExternal(error) }
            self?.updateStatus()
        }
    }

    private func stopMic() {
        micSource.stop()
        micTranscriber.stop()
    }

    private func startSystem() {
        sysTranscriber.start()
        sysSource.start { [weak self] error in
            if let error {
                self?.sysTranscriber.reportExternal(error)
                self?.sysTranscriber.stop()
            }
            self?.updateStatus()
        }
    }

    private func stopSystem() {
        sysSource.stop()
        sysTranscriber.stop()
        sysCommitted = ""; sysPartial = ""
    }

    // MARK: Texto

    private func render() {
        fill(columns.micText, committed: micCommitted, partial: micPartial)
        fill(columns.sysText, committed: sysCommitted, partial: sysPartial)
        scrollToBottom(columns.micScroll, columns.micText)
        if systemAudio { scrollToBottom(columns.sysScroll, columns.sysText) }
        updateStatus()
    }

    /// Confirmado em branco, provisório apagado — dá para ver a frase se formando.
    private func fill(_ view: NSTextView, committed: String, partial: String) {
        guard let storage = view.textStorage else { return }
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = fontSize * 0.28

        let result = NSMutableAttributedString(string: committed, attributes: [
            .font: NSFont.systemFont(ofSize: fontSize, weight: .regular),
            .foregroundColor: NSColor.white,
            .paragraphStyle: paragraph,
        ])
        if !partial.isEmpty {
            result.append(NSAttributedString(
                string: (committed.isEmpty ? "" : " ") + partial,
                attributes: [
                    .font: NSFont.systemFont(ofSize: fontSize, weight: .regular),
                    .foregroundColor: NSColor.white.withAlphaComponent(0.45),
                    .paragraphStyle: paragraph,
                ]))
        }
        storage.setAttributedString(result)
    }

    private func scrollToBottom(_ scroll: NSScrollView, _ view: NSTextView) {
        guard let manager = view.layoutManager, let container = view.textContainer else { return }
        manager.ensureLayout(for: container)
        let height = manager.usedRect(for: container).height + view.textContainerInset.height * 2
        let y = max(0, height - scroll.contentView.bounds.height)
        scroll.contentView.scroll(to: NSPoint(x: 0, y: y))
        scroll.reflectScrolledClipView(scroll.contentView)
    }

    private func updateStatus() {
        var line = micTranscriber.isListening ? "● você" : "❙❙ você"
        line += systemAudio
            ? "  ·  ⚠ sistema ligado DESATIVA o microfone (⌃⌥⌘H)"
            : "  ·  sistema desligado (⌃⌥⌘H)"
        line += "  ·  \(micTranscriber.localeID)"
        line += passThrough ? "  ·  ⇢ cliques passam" : ""

        if let error = micTranscriber.lastError { line = "⚠ você: \(error)" }
        else if let error = sysTranscriber.lastError, systemAudio { line = "⚠ sistema: \(error)" }
        if !hotKeyFailures.isEmpty {
            line += "  ·  ⚠ em conflito: " + hotKeyFailures.joined(separator: " ")
        }
        status.stringValue = line
    }

    // MARK: Comandos

    func apply(command: String) {
        let parts = command.split(separator: " ", maxSplits: 1).map(String.init)
        guard let verb = parts.first else { return }
        let arg = parts.count > 1 ? parts[1] : ""

        switch verb {
        case "start", "listen": startMic()
        case "stop": stopMic()
        case "toggle": micTranscriber.isListening ? stopMic() : startMic()
        case "system":
            switch arg {
            case "on", "true", "1": systemAudio = true
            case "off", "false", "0": systemAudio = false
            default: systemAudio.toggle()
            }
        case "clear":
            micTranscriber.clear(); sysTranscriber.clear()
            micCommitted = ""; micPartial = ""; sysCommitted = ""; sysPartial = ""
            render()
        case "copy": copyTranscript()
        case "save": saveTranscript(to: arg)
        case "locale":
            if !arg.isEmpty {
                defaults.set(arg, forKey: Pref.locale)
                micTranscriber.localeID = arg
                sysTranscriber.localeID = arg
            }
        case "font": if let v = Double(arg) { fontSize = CGFloat(v).clamped(11, 60) }
        case "bigger": fontSize = (fontSize + 2).clamped(11, 60)
        case "smaller": fontSize = (fontSize - 2).clamped(11, 60)
        case "opacity":
            if let v = Double(arg) { setOpacity(v > 1 ? CGFloat(v / 100) : CGFloat(v)) }
        case "dimmer": setOpacity(window.alphaValue - 0.1)
        case "brighter": setOpacity(window.alphaValue + 0.1)
        case "pass", "click":
            switch arg {
            case "on", "true", "1": passThrough = true
            case "off", "false", "0": passThrough = false
            default: passThrough.toggle()
            }
        case "hide": window.orderOut(nil)
        case "show": window.orderFrontRegardless()
        case "state": dumpState(to: arg)
        case "dump":
            // Diagnóstico: grava 20s do áudio convertido para inspeção externa.
            let path = arg.isEmpty ? "/tmp/captions-dump.wav" : (arg as NSString).expandingTildeInPath
            arg.hasSuffix("raw.wav") ? sysSource.startRawDump(to: path) : sysSource.startDump(to: path)
            DispatchQueue.main.asyncAfter(deadline: .now() + 20) { [weak self] in
                self?.sysSource.stopDump()
            }
        case "camera": Companion.toggle(name: "CamCircle", bundleID: "com.startse.camcircle")
        case "prompter": Companion.toggle(name: "Teleprompter", bundleID: "com.startse.teleprompter")
        case "quit": quit()
        default: break
        }
        updateStatus()
    }

    /// Diagnóstico: o painel é invisível na captura, então este é o único jeito
    /// de inspecionar o estado de fora.
    private func dumpState(to arg: String) {
        let target = arg.isEmpty
            ? NSString(string: "~/Desktop/captions-state.txt").expandingTildeInPath
            : (arg as NSString).expandingTildeInPath
        let rec = SFSpeechRecognizer(locale: Locale(identifier: micTranscriber.localeID))
        let report = """
            idioma: \(micTranscriber.localeID)
            autorização de fala: \(SFSpeechRecognizer.authorizationStatus().rawValue) (3 = ok)
            permissão de microfone: \(AVCaptureDevice.authorizationStatus(for: .audio).rawValue) (3 = ok)
            on-device suportado: \(rec?.supportsOnDeviceRecognition.description ?? "n/d")

            MICROFONE
              transcrevendo: \(micTranscriber.isListening)
              fonte ativa: \(micSource.isRunning)
              caracteres: \(micTranscriber.text.count)
              erro: \(micTranscriber.lastError ?? "nenhum")

            SAÍDA DO SISTEMA
              ligado: \(systemAudio)
              transcrevendo: \(sysTranscriber.isListening)
              tap ativo: \(sysSource.isRunning)
              amostras entregues: \(sysSource.deliveredFrames)
              pico de áudio: \(String(format: "%.4f", sysSource.peakLevel)) (agora) / \(String(format: "%.4f", sysSource.peakEver)) (máximo)
              caracteres: \(sysTranscriber.text.count)
              streams: \(sysSource.bufferSummary)
              erro: \(sysTranscriber.lastError ?? "nenhum")
            """
        try? report.write(toFile: target, atomically: true, encoding: .utf8)
    }

    private func pollControl() {
        guard let stamp = try? FileManager.default
            .attributesOfItem(atPath: controlPath)[.modificationDate] as? Date else { return }
        guard stamp != controlStamp else { return }
        controlStamp = stamp
        guard let raw = try? String(contentsOfFile: controlPath, encoding: .utf8) else { return }
        let line = raw.split(separator: "\n").first.map(String.init) ?? ""
        apply(command: line.trimmingCharacters(in: .whitespaces))
    }

    /// Com as duas fontes ativas, a cópia sai rotulada — senão não há como saber
    /// quem disse o quê.
    private var transcript: String {
        guard systemAudio, !sysTranscriber.text.isEmpty else { return micTranscriber.text }
        return "VOCÊ\n\(micTranscriber.text)\n\nSISTEMA\n\(sysTranscriber.text)"
    }

    func copyTranscript() {
        let text = transcript
        guard !text.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    private func saveTranscript(to path: String) {
        let target = path.isEmpty
            ? NSString(string: "~/Desktop/transcricao.txt").expandingTildeInPath
            : (path as NSString).expandingTildeInPath
        try? transcript.write(toFile: target, atomically: true, encoding: .utf8)
    }

    func setOpacity(_ value: CGFloat) {
        let clamped = value.clamped(0.25, 1.0)
        window.alphaValue = clamped
        defaults.set(Double(clamped), forKey: Pref.opacity)
    }

    func drag(with event: NSEvent) {
        window.performDrag(with: event)
        savePosition()
    }

    func resize(by delta: CGSize) {
        var frame = window.frame
        frame.size.width = (frame.width + delta.width).clamped(320, 2400)
        frame.size.height = (frame.height + delta.height).clamped(90, 900)
        frame.origin.y -= delta.height
        window.setFrame(frame, display: true)
        defaults.set(Double(frame.width), forKey: Pref.w)
        defaults.set(Double(frame.height), forKey: Pref.h)
        render()
    }

    private func savePosition() {
        defaults.set(Double(window.frame.origin.x), forKey: Pref.x)
        defaults.set(Double(window.frame.origin.y), forKey: Pref.y)
    }

    func quit() {
        stopMic()
        stopSystem()
        savePosition()
        NSApp.terminate(nil)
    }

    // MARK: Atalhos globais

    private enum HotKey: UInt32 {
        case toggle = 1, clear = 2, copyText = 3, pass = 4, visibility = 5
        case dimmer = 6, brighter = 7, system = 8
    }

    private func installHotKeys() {
        guard defaults.bool(forKey: Pref.hotkeys) else { return }

        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                                 eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ -> OSStatus in
            var id = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject),
                              EventParamType(typeEventHotKeyID), nil,
                              MemoryLayout<EventHotKeyID>.size, nil, &id)
            let value = id.id
            DispatchQueue.main.async { Captions.shared?.handleHotKey(value) }
            return noErr
        }, 1, &spec, nil, nil)

        // ⌃⌥⌘ como nos outros dois, em letras que eles não usam:
        // o Teleprompter tem Space ↑ ↓ R V L T C [ ] /, o CamCircle tem P.
        let mods = UInt32(controlKey | optionKey | cmdKey)
        register(kVK_ANSI_J, mods, .toggle, "⌃⌥⌘J")
        register(kVK_ANSI_H, mods, .system, "⌃⌥⌘H")
        register(kVK_ANSI_K, mods, .clear, "⌃⌥⌘K")
        register(kVK_ANSI_Y, mods, .copyText, "⌃⌥⌘Y")
        register(kVK_ANSI_N, mods, .pass, "⌃⌥⌘N")
        register(kVK_ANSI_G, mods, .visibility, "⌃⌥⌘G")
        register(kVK_ANSI_Minus, mods, .dimmer, "⌃⌥⌘-")
        register(kVK_ANSI_Equal, mods, .brighter, "⌃⌥⌘=")
    }

    private func register(_ keyCode: Int, _ mods: UInt32, _ id: HotKey, _ label: String) {
        var ref: EventHotKeyRef?
        let hotKeyID = EventHotKeyID(signature: OSType(0x43_43_50_54), id: id.rawValue)  // 'CCPT'
        if RegisterEventHotKey(UInt32(keyCode), mods, hotKeyID,
                               GetApplicationEventTarget(), 0, &ref) == noErr {
            hotKeys.append(ref)
        } else {
            hotKeyFailures.append(label)
        }
    }

    func handleHotKey(_ raw: UInt32) {
        switch HotKey(rawValue: raw) {
        case .toggle: apply(command: "toggle")
        case .system: systemAudio.toggle()
        case .clear: apply(command: "clear")
        case .copyText: copyTranscript()
        case .pass: passThrough.toggle()
        case .visibility: window.isVisible ? window.orderOut(nil) : window.orderFrontRegardless()
        case .dimmer: setOpacity(window.alphaValue - 0.1)
        case .brighter: setOpacity(window.alphaValue + 0.1)
        case .none: break
        }
        updateStatus()
    }

    // MARK: Barra de menus

    private func installStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.image = NSImage(systemSymbolName: "captions.bubble",
                                    accessibilityDescription: "Captions")
        item.button?.image?.isTemplate = true
        let menu = NSMenu()
        menu.delegate = self
        item.menu = menu
        statusItem = item
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()

        add(menu, micTranscriber.isListening ? "Parar de escutar você" : "Escutar você",
            #selector(menuToggle))
        add(menu, "Transcrever o áudio do sistema", #selector(menuSystem), on: systemAudio)
        menu.addItem(.separator())

        add(menu, "Limpar", #selector(menuClear))
        add(menu, "Copiar transcrição", #selector(menuCopy))
        add(menu, "Salvar na Mesa", #selector(menuSave))
        menu.addItem(.separator())

        for (title, id) in [("Português (Brasil)", "pt-BR"), ("English (US)", "en-US"),
                            ("Español", "es-ES")] {
            let item = add(menu, title, #selector(menuLocale(_:)),
                           on: micTranscriber.localeID == id)
            item.representedObject = id
        }
        menu.addItem(.separator())

        add(menu, "Cliques atravessam o painel", #selector(menuPass), on: passThrough)
        add(menu, "Fonte maior", #selector(menuBigger))
        add(menu, "Fonte menor", #selector(menuSmaller))
        menu.addItem(.separator())

        add(menu, Companion.isRunning(bundleID: "com.startse.camcircle")
            ? "Fechar câmera" : "Abrir câmera", #selector(menuCamera))
        add(menu, Companion.isRunning(bundleID: "com.startse.teleprompter")
            ? "Fechar teleprompter" : "Abrir teleprompter", #selector(menuPrompter))
        menu.addItem(.separator())
        add(menu, "Sair", #selector(menuQuit))
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

    @objc private func menuToggle() { apply(command: "toggle") }
    @objc private func menuSystem() { systemAudio.toggle() }
    @objc private func menuClear() { apply(command: "clear") }
    @objc private func menuCopy() { copyTranscript() }
    @objc private func menuSave() { apply(command: "save") }
    @objc private func menuLocale(_ sender: NSMenuItem) {
        if let id = sender.representedObject as? String { apply(command: "locale \(id)") }
    }
    @objc private func menuPass() { passThrough.toggle() }
    @objc private func menuBigger() { apply(command: "bigger") }
    @objc private func menuSmaller() { apply(command: "smaller") }
    @objc private func menuCamera() { apply(command: "camera") }
    @objc private func menuPrompter() { apply(command: "prompter") }
    @objc private func menuQuit() { quit() }
}

// MARK: - Eventos

final class CaptionHostView: NSView {

    private weak var captions: Captions?
    private var resizeAnchor: NSPoint?

    init(captions: Captions, backdrop: NSView) {
        self.captions = captions
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
            captions?.drag(with: event)
        }
    }

    override func mouseDragged(with event: NSEvent) {
        guard let anchor = resizeAnchor else { return }
        let now = NSEvent.mouseLocation
        captions?.resize(by: CGSize(width: now.x - anchor.x, height: anchor.y - now.y))
        resizeAnchor = now
    }

    override func mouseUp(with event: NSEvent) { resizeAnchor = nil }

    override func keyDown(with event: NSEvent) {
        switch event.charactersIgnoringModifiers?.lowercased() ?? "" {
        case " ": captions?.apply(command: "toggle")
        case "h": captions?.apply(command: "system")
        case "k": captions?.apply(command: "clear")
        case "c": captions?.copyTranscript()
        case "s": captions?.apply(command: "save")
        case "+", "=": captions?.apply(command: "bigger")
        case "-", "_": captions?.apply(command: "smaller")
        case "[": captions?.apply(command: "dimmer")
        case "]": captions?.apply(command: "brighter")
        case "q", "\u{1B}": captions?.quit()
        default: super.keyDown(with: event)
        }
    }
}

private extension CGFloat {
    func clamped(_ lo: CGFloat, _ hi: CGFloat) -> CGFloat { Swift.min(Swift.max(self, lo), hi) }
}

// MARK: - main

@main
struct CaptionsApp {
    static let captions = Captions()

    static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        app.delegate = captions
        app.run()
    }
}
