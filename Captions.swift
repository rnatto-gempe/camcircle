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
    static let mode = "ccMode"          // "chunk" ou "live"
    static let chunkSeconds = "ccChunkSeconds"
}

private let controlPath = NSString(string: "~/.teleprompter/captions-control").expandingTildeInPath

// MARK: - Transcrição por segmentos curtos

/// Transcreve on-device em **segmentos curtos**, um por frase.
///
/// O `SFSpeechRecognizer` foi feito para ditado curto: cada requisição cobre uma
/// fala e se encerra sozinha no silêncio. A versão anterior tentava manter uma
/// sessão contínua com requisições sobrepostas e costura de palavras — muito mais
/// complexa e frágil. Aqui, quando um segmento fecha, o próximo abre na hora, e
/// cada resultado final é uma frase pronta que só precisa ser anexada.
final class Transcriber: NSObject, SFSpeechRecognizerDelegate {

    /// Um segmento que passe disto sem fechar é encerrado à força. Medi que uma
    /// requisição longa devolve só uma janela do áudio, então não vale esperar.
    private let maxSegment: TimeInterval = 45

    private var recognizer: SFSpeechRecognizer?
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private var segmentTimer: Timer?

    private var segments: [String] = []
    private var partial = ""

    /// Áudio que chegou entre o fim de um segmento e a abertura do próximo.
    /// Sem esta fila, 30% da fala se perdia no vão — medido.
    private var gap: [AVAudioPCMBuffer] = []
    private(set) var replayed = 0

    private(set) var isListening = false
    private(set) var lastError: String?

    /// Instrumentação por etapa. Sem isto, "zero caracteres" é indistinguível
    /// entre buffer que não entra, callback que não dispara e texto vazio.
    private(set) var appended = 0
    private(set) var appendedWhileClosed = 0
    private(set) var callbacks = 0
    private(set) var partialsSeen = 0
    private(set) var finalsSeen = 0
    private(set) var errorsSeen = 0
    private(set) var segmentsOpened = 0
    /// Parciais vistos no segmento atual. Distingue "morreu com fala em curso"
    /// de "morreu no silêncio", e é isso que define a espera para reabrir.
    private var partialsThisSegment = 0
    private(set) var lastResultText = ""
    /// Códigos de erro vistos, com contagem. Suprimir erros "de rotina" sem
    /// registrá-los escondeu exatamente o que explicava a falha.
    private(set) var errorTally: [String: Int] = [:]

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
        (segments + (partial.isEmpty ? [] : [partial])).joined(separator: " ")
    }

    var diagnostics: String {
        """
        buffers: \(appended) · no vão: \(appendedWhileClosed) · devolvidos: \(replayed)
              segmentos abertos: \(segmentsOpened) · callbacks: \(callbacks)
              parciais: \(partialsSeen) · finais: \(finalsSeen) · erros: \(errorsSeen)
              último texto recebido: "\(lastResultText.prefix(60))"
              erros vistos: \(errorTally.isEmpty ? "nenhum" : errorTally.map { "\($0.key) x\($0.value)" }.joined(separator: " | "))
        """
    }

    // MARK: Ciclo

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
        guard rec.supportsOnDeviceRecognition else {
            fail("Sem modelo on-device para \(localeID). Ative o Ditado nesse idioma em Ajustes do Sistema › Teclado › Ditado.")
            return
        }
        recognizer = rec
        isListening = true
        openSegment()
        onStateChange?()
    }

    /// Abre uma requisição nova. Uma por vez: nada de sobreposição.
    private func openSegment() {
        guard isListening, let rec = recognizer else { return }

        segmentTimer?.invalidate()
        task?.cancel()

        let req = SFSpeechAudioBufferRecognitionRequest()
        req.requiresOnDeviceRecognition = true   // nada sai da máquina
        req.shouldReportPartialResults = true
        req.addsPunctuation = true
        request = req
        segmentsOpened += 1
        partialsThisSegment = 0

        // Devolve o áudio do vão antes de qualquer coisa nova, para a frase
        // começar do início e não do meio.
        if !gap.isEmpty {
            gap.forEach { req.append($0) }
            replayed += gap.count
            gap.removeAll()
        }

        task = rec.recognitionTask(with: req) { [weak self] result, error in
            DispatchQueue.main.async {
                guard let self, self.isListening else { return }
                self.callbacks += 1

                if let error {
                    self.errorsSeen += 1
                    let ns = error as NSError
                    let key = "\(ns.domain):\(ns.code) \(ns.localizedDescription)"
                    self.errorTally[key, default: 0] += 1
                    // Silêncio e cancelamento são rotina num fluxo por frases.
                    let routine = ns.code == 1110 || ns.code == 203 || ns.code == 216
                        || ns.localizedDescription.lowercased().contains("no speech")
                        || ns.localizedDescription.lowercased().contains("cancel")
                    if !routine { self.lastError = ns.localizedDescription }

                    // O segmento morre no silêncio antes de entregar o final, e
                    // o parcial já tem a frase. Descartá-lo fazia o texto
                    // aparecer e desaparecer — medido: 33 parciais, 0 finais.
                    let pending = self.partial.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !pending.isEmpty {
                        self.append(segment: pending)
                        self.partial = ""
                        self.publish()
                    }
                    self.onStateChange?()

                    // Espera adaptativa. Se havia fala em curso, reabre na hora:
                    // esperar aqui é o que fazia 48% do áudio cair no vão,
                    // medido. Se o segmento morreu sem nenhum parcial, a sala
                    // está em silêncio e vale recuar para não virar laço.
                    let hadSpeech = self.partialsThisSegment > 0
                    self.scheduleNextSegment(after: hadSpeech ? 0.02 : 0.5)
                    return
                }

                guard let result else { return }
                let text = result.bestTranscription.formattedString
                self.lastResultText = text

                if result.isFinal {
                    self.finalsSeen += 1
                    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !trimmed.isEmpty { self.append(segment: trimmed) }
                    self.partial = ""
                    self.publish()
                    self.scheduleNextSegment(after: 0.02)
                } else {
                    self.partialsSeen += 1
                    self.partialsThisSegment += 1
                    self.partial = text
                    if self.lastError != nil { self.lastError = nil; self.onStateChange?() }
                    self.publish()
                }
            }
        }

        // Rede de segurança: força o fechamento se a frase nunca terminar.
        segmentTimer = Timer.scheduledTimer(withTimeInterval: maxSegment, repeats: false) { [weak self] _ in
            self?.request?.endAudio()
        }
    }

    /// Reabre logo, mas fora do callback, para não recriar dentro da entrega.
    private func scheduleNextSegment(after delay: TimeInterval = 0.15) {
        request = nil
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self, self.isListening else { return }
            self.openSegment()
        }
    }

    private func append(segment: String) {
        segments.append(segment)
        if segments.count > 400 { segments.removeFirst(segments.count - 400) }
    }

    func feed(_ buffer: AVAudioPCMBuffer) {
        appended += 1
        if let request {
            request.append(buffer)
            return
        }
        // Nenhuma requisição aberta: guarda em vez de descartar.
        appendedWhileClosed += 1
        gap.append(buffer)
        if gap.count > 80 { gap.removeFirst(gap.count - 80) }
    }

    func stop() {
        segmentTimer?.invalidate()
        segmentTimer = nil
        request?.endAudio()
        request = nil
        task?.cancel()
        task = nil
        isListening = false
        onStateChange?()
    }

    func restart() {
        stop()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in self?.start() }
    }

    func clear() {
        segments = []
        partial = ""
        publish()
    }

    func reportExternal(_ message: String) {
        lastError = message
        onStateChange?()
    }

    private func fail(_ message: String) {
        lastError = message
        isListening = false
        onStateChange?()
    }

    private func publish() {
        onUpdate?(segments.joined(separator: " "), partial)
    }

    func speechRecognizer(_ recognizer: SFSpeechRecognizer, availabilityDidChange available: Bool) {
        if !available, isListening { fail("O reconhecedor ficou indisponível.") }
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

    var showsSystem = false {
        didSet {
            applyVisibility()
            // `needsLayout` apenas agenda, e a coluna do sistema ficava com
            // frame 0x0 até algo forçar um novo layout — era por isso que
            // esconder e mostrar a janela "fazia funcionar". O texto estava lá;
            // a view é que não tinha tamanho.
            needsLayout = true
            layoutSubtreeIfNeeded()
        }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)

        for (header, color) in [(micHeader, NSColor.white),
                                (sysHeader, NSColor(srgbRed: 0.42, green: 0.78, blue: 0.98, alpha: 1))] {
            header.font = NSFont.systemFont(ofSize: 9, weight: .semibold)
            header.textColor = color.withAlphaComponent(0.55)
            addSubview(header)
        }

        for (scroll, text) in [(micScroll, micText), (sysScroll, sysText)] {
            // Frame explícito: um NSTextView criado sem frame nasce com tamanho
            // zero, o container fica com largura zero e o texto nunca é
            // desenhado — transcreve e não aparece nada na tela.
            text.frame = NSRect(x: 0, y: 0, width: 400, height: 100)
            text.isEditable = false
            text.isSelectable = false
            text.drawsBackground = false
            text.textContainerInset = NSSize(width: 14, height: 8)
            text.isVerticallyResizable = true
            text.isHorizontallyResizable = false
            text.autoresizingMask = [.width]
            text.minSize = NSSize(width: 0, height: 0)
            text.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude,
                                  height: CGFloat.greatestFiniteMagnitude)
            text.textContainer?.widthTracksTextView = true
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
            resizeText(micText, to: micScroll)
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
        resizeText(micText, to: micScroll)
        resizeText(sysText, to: sysScroll)
    }

    /// Casa a largura do text view com a do clip view. Sem isso o container de
    /// texto mantém a largura antiga e o texto some ao redimensionar.
    private func resizeText(_ text: NSTextView, to scroll: NSScrollView) {
        let width = scroll.contentSize.width
        guard width > 0 else { return }
        text.frame.size.width = width
        text.textContainer?.containerSize = NSSize(width: width - text.textContainerInset.width * 2,
                                                  height: CGFloat.greatestFiniteMagnitude)
    }

    /// Diagnóstico de layout: o painel é invisível na captura, então é o único
    /// jeito de saber se o texto está sendo desenhado.
    var layoutReport: String {
        func describe(_ label: String, _ text: NSTextView, _ scroll: NSScrollView) -> String {
            let used = text.layoutManager.flatMap { manager -> CGFloat? in
                guard let container = text.textContainer else { return nil }
                manager.ensureLayout(for: container)
                return manager.usedRect(for: container).height
            } ?? -1
            return String(format: "%@ scroll %.0fx%.0f · text %.0fx%.0f · container %.0f · usado %.0f · chars %d",
                          label, scroll.frame.width, scroll.frame.height,
                          text.frame.width, text.frame.height,
                          text.textContainer?.containerSize.width ?? -1,
                          used, text.string.count)
        }
        return describe("você:", micText, micScroll) + "\n              "
             + describe("sistema:", sysText, sysScroll)
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

    /// Rastro de inicialização: sem ver a sequência real, um "transcrevendo:
    /// false" sem erro é indistinguível de callback que não voltou.
    private var trace: [String] = []
    private func mark(_ step: String) {
        trace.append(step)
        if trace.count > 40 { trace.removeFirst() }
    }
    private var pollTimer: Timer?

    /// Um par transcritor + fonte por entrada. O transcritor é o mesmo código
    /// nas duas; só a origem do áudio muda.
    private var micTranscriber: Transcriber!
    private var sysTranscriber: Transcriber!
    private let micSource = MicrophoneSource()
    private let sysSource = SystemAudioSource()

    /// Modo blocos: junta N segundos e transcreve o arquivo inteiro. Latência
    /// em troca de qualidade — o reconhecedor é muito melhor com contexto.
    private var micChunks: ChunkTranscriber!
    private var sysChunks: ChunkTranscriber!
    private var chunkMode = true

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
            // Layout antes de desenhar: sem tamanho, não há onde o texto caber.
            window.contentView?.layoutSubtreeIfNeeded()
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
        chunkMode = (defaults.string(forKey: Pref.mode) ?? "chunk") == "chunk"

        micTranscriber = Transcriber(localeID: locale)
        sysTranscriber = Transcriber(localeID: locale)
        micChunks = ChunkTranscriber(localeID: locale, label: "mic")
        sysChunks = ChunkTranscriber(localeID: locale, label: "sys")

        let seconds = defaults.double(forKey: Pref.chunkSeconds)
        if seconds >= 5 { micChunks.chunkSeconds = seconds; sysChunks.chunkSeconds = seconds }

        micChunks.onUpdate = { [weak self] t in self?.micCommitted = t; self?.micPartial = ""; self?.render() }
        sysChunks.onUpdate = { [weak self] t in self?.sysCommitted = t; self?.sysPartial = ""; self?.render() }
        micChunks.onStateChange = { [weak self] in self?.updateStatus() }
        sysChunks.onStateChange = { [weak self] in self?.updateStatus() }

        micTranscriber.onUpdate = { [weak self] c, p in
            self?.micCommitted = c; self?.micPartial = p; self?.render()
        }
        sysTranscriber.onUpdate = { [weak self] c, p in
            self?.sysCommitted = c; self?.sysPartial = p; self?.render()
        }
        micTranscriber.onStateChange = { [weak self] in self?.updateStatus() }
        sysTranscriber.onStateChange = { [weak self] in self?.updateStatus() }

        micSource.onBuffer = { [weak self] buffer in
            guard let self else { return }
            self.chunkMode ? self.micChunks.feed(buffer) : self.micTranscriber.feed(buffer)
        }
        sysSource.onBuffer = { [weak self] buffer in
            guard let self else { return }
            self.chunkMode ? self.sysChunks.feed(buffer) : self.sysTranscriber.feed(buffer)
        }

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
        mark("startMic chamado")
        chunkMode ? micChunks.start() : micTranscriber.start()
        mark("micTranscriber.start retornou")
        micSource.start { [weak self] error in
            self?.mark("micSource completion: \(error ?? "sem erro")")
            if let error { self?.micTranscriber.reportExternal(error) }
            self?.updateStatus()
        }
        mark("micSource.start retornou")
    }

    private func stopMic() {
        micSource.stop()
        micTranscriber.stop()
        micChunks.stop()
    }

    private func startSystem() {
        chunkMode ? sysChunks.start() : sysTranscriber.start()
        sysSource.start { [weak self] error in
            if let error {
                self?.sysTranscriber.reportExternal(error)
                self?.sysTranscriber.stop()
                self?.sysChunks.stop()
            }
            self?.updateStatus()
        }
    }

    private func stopSystem() {
        sysSource.stop()
        sysTranscriber.stop()
        sysChunks.stop()
        sysCommitted = ""; sysPartial = ""
    }

    // MARK: Texto

    private func render() {
        // Rede de segurança: se a coluna ainda não tem largura, o texto não
        // apareceria. Força o layout antes de preencher.
        if columns.showsSystem, columns.sysScroll.frame.width < 1 {
            columns.needsLayout = true
            columns.layoutSubtreeIfNeeded()
        }
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
        guard chunkMode else { return updateLiveStatus() }

        var line = micChunks.isRunning
            ? String(format: "● você %.0f/%.0fs", micChunks.currentChunkSeconds, micChunks.chunkSeconds)
            : "❙❙ você"
        if systemAudio {
            line += sysChunks.isRunning
                ? String(format: "  ·  ● sistema %.0f/%.0fs", sysChunks.currentChunkSeconds, sysChunks.chunkSeconds)
                : "  ·  ⚠ sistema"
        } else {
            line += "  ·  sistema desligado (⌃⌥⌘H)"
        }
        let inFlight = micChunks.chunksInFlight + sysChunks.chunksInFlight
        if inFlight > 0 { line += "  ·  transcrevendo \(inFlight)" }
        line += "  ·  blocos \(micChunks.chunksDone + sysChunks.chunksDone)"
        if let e = micChunks.lastError { line = "⚠ você: \(e)" }
        else if let e = sysChunks.lastError, systemAudio { line = "⚠ sistema: \(e)" }
        status.stringValue = line
    }

    private func updateLiveStatus() {
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
            micChunks.clear(); sysChunks.clear()
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
        case "mode":
            let wanted = (arg == "live") ? false : true
            if wanted != chunkMode {
                stopMic(); stopSystem()
                chunkMode = wanted
                defaults.set(wanted ? "chunk" : "live", forKey: Pref.mode)
                apply(command: "clear")
                startMic()
                if systemAudio { startSystem() }
            }
        case "chunk":
            if let v = Double(arg), v >= 5, v <= 120 {
                defaults.set(v, forKey: Pref.chunkSeconds)
                micChunks.chunkSeconds = v
                sysChunks.chunkSeconds = v
            }
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

            RASTRO
              \(trace.isEmpty ? "vazio" : trace.joined(separator: "\n              "))

            JANELA
              frame: \(Int(window.frame.origin.x)),\(Int(window.frame.origin.y)) \(Int(window.frame.width))x\(Int(window.frame.height))
              visível: \(window.isVisible)  alpha: \(String(format: "%.2f", window.alphaValue))
              layout: \(columns.layoutReport)

            MODO: \(chunkMode ? "blocos" : "streaming")

            MICROFONE
              transcrevendo: \(micTranscriber.isListening)
              fonte ativa: \(micSource.isRunning)  ·  passo: \(micSource.lastStep)
              religadas: \(micSource.restarts)
              caracteres: \(micTranscriber.text.count)
              \(chunkMode ? micChunks.diagnostics : micTranscriber.diagnostics)
              erro: \(micTranscriber.lastError ?? "nenhum")

            SAÍDA DO SISTEMA
              ligado: \(systemAudio)
              transcrevendo: \(sysTranscriber.isListening)
              tap ativo: \(sysSource.isRunning)
              amostras entregues: \(sysSource.deliveredFrames)
              pico de áudio: \(String(format: "%.4f", sysSource.peakLevel)) (agora) / \(String(format: "%.4f", sysSource.peakEver)) (máximo)
              caracteres: \(sysTranscriber.text.count)
              streams: \(sysSource.bufferSummary)
              \(chunkMode ? sysChunks.diagnostics : sysTranscriber.diagnostics)
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
        let mine = chunkMode ? micChunks.text : micTranscriber.text
        let theirs = chunkMode ? sysChunks.text : sysTranscriber.text
        guard systemAudio, !theirs.isEmpty else { return mine }
        return "VOCÊ\n\(mine)\n\nSISTEMA\n\(theirs)"
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
