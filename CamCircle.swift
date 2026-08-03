import AppKit
import AVFoundation
import Carbon.HIToolbox
import CoreImage
import CoreMedia

// MARK: - Preferências persistidas

private enum Pref {
    static let size = "size"
    static let originX = "originX"
    static let originY = "originY"
    static let mirror = "mirror"
    static let corner = "corner"
    static let deviceID = "deviceID"
    static let ringStyle = "ringStyle"
    static let theme = "theme"
    static let feather = "feather"
    static let grade = "grade"
    static let voice = "voice"
    static let framing = "framing"
    static let shadow = "shadow"
    static let zoom = "zoom"
    static let panX = "panX"
    static let panY = "panY"
}

private let minSize: CGFloat = 90
private let maxSize: CGFloat = 900

/// Respiro em volta do círculo, em fração do lado da janela.
/// A janela é maior que o círculo para a sombra e o glow caírem suaves,
/// sem serem cortados na borda.
private let padRatio: CGFloat = 0.12

/// Converte diâmetro visível → lado da janela.
private func windowSide(forDiameter diameter: CGFloat) -> CGFloat {
    diameter / (1 - 2 * padRatio)
}

// MARK: - Estilo

enum RingStyle: Int, CaseIterable {
    case none, solid, gradient

    var label: String {
        switch self {
        case .none: return "sem anel"
        case .solid: return "sólido"
        case .gradient: return "gradiente animado"
        }
    }
}

struct Theme {
    let name: String
    let colors: [NSColor]

    static let all: [Theme] = [
        Theme(name: "Aurora", colors: [
            NSColor(srgbRed: 0.42, green: 0.36, blue: 0.98, alpha: 1),
            NSColor(srgbRed: 0.85, green: 0.34, blue: 0.86, alpha: 1),
            NSColor(srgbRed: 0.31, green: 0.78, blue: 0.98, alpha: 1),
            NSColor(srgbRed: 0.42, green: 0.36, blue: 0.98, alpha: 1),
        ]),
        Theme(name: "Ember", colors: [
            NSColor(srgbRed: 0.98, green: 0.55, blue: 0.18, alpha: 1),
            NSColor(srgbRed: 0.95, green: 0.26, blue: 0.36, alpha: 1),
            NSColor(srgbRed: 0.99, green: 0.80, blue: 0.34, alpha: 1),
            NSColor(srgbRed: 0.98, green: 0.55, blue: 0.18, alpha: 1),
        ]),
        Theme(name: "Mint", colors: [
            NSColor(srgbRed: 0.13, green: 0.83, blue: 0.62, alpha: 1),
            NSColor(srgbRed: 0.22, green: 0.72, blue: 0.95, alpha: 1),
            NSColor(srgbRed: 0.62, green: 0.95, blue: 0.72, alpha: 1),
            NSColor(srgbRed: 0.13, green: 0.83, blue: 0.62, alpha: 1),
        ]),
        Theme(name: "Studio", colors: [
            NSColor(white: 1.00, alpha: 0.95),
            NSColor(white: 0.70, alpha: 0.95),
            NSColor(white: 1.00, alpha: 0.95),
            NSColor(white: 0.70, alpha: 0.95),
        ]),
    ]
}

// MARK: - Nível do microfone

/// Lê o microfone e reporta um nível suavizado de 0 a 1.
final class VoiceMeter {
    private var engine: AVAudioEngine?
    private var level: Float = 0
    var onLevel: ((CGFloat) -> Void)?

    func start() {
        guard engine == nil else { return }
        AVCaptureDevice.requestAccess(for: .audio) { [weak self] granted in
            guard granted else { return }
            DispatchQueue.main.async { self?.attach() }
        }
    }

    private func attach() {
        let engine = AVAudioEngine()
        let input = engine.inputNode
        let format = input.inputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else { return }

        input.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, _ in
            guard let channel = buffer.floatChannelData?[0] else { return }
            let frames = Int(buffer.frameLength)
            guard frames > 0 else { return }
            var sum: Float = 0
            for i in 0..<frames { sum += channel[i] * channel[i] }
            let rms = (sum / Float(frames)).squareRoot()
            let db = 20 * log10(max(rms, 0.000_01))          // -50 dB → 0, 0 dB → 1
            let normalized = max(0, min(1, (db + 50) / 50))
            guard let self else { return }
            // ataque rápido, decaimento suave
            self.level += (normalized - self.level) * (normalized > self.level ? 0.55 : 0.12)
            let value = CGFloat(self.level)
            DispatchQueue.main.async { self.onLevel?(value) }
        }

        do {
            try engine.start()
            self.engine = engine
        } catch {
            input.removeTap(onBus: 0)
        }
    }

    func stop() {
        engine?.inputNode.removeTap(onBus: 0)
        engine?.stop()
        engine = nil
        level = 0
        onLevel?(0)
    }
}

// MARK: - Janela

final class OverlayWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

// MARK: - View com a câmera e os efeitos

final class CameraCircleView: NSView {

    private let session = AVCaptureSession()
    private let preview = AVCaptureVideoPreviewLayer()
    private let container = CALayer()
    private let clip = CALayer()
    private let vignette = CAGradientLayer()
    private let glow = CAShapeLayer()
    private let ringHolder = CALayer()
    private let ringGradient = CAGradientLayer()
    private let ringMask = CAShapeLayer()
    private let rim = CAShapeLayer()
    private let featherMask = CAGradientLayer()
    private let crosshair = CAShapeLayer()
    private let closeButton = CALayer()
    private let closeDisc = CAShapeLayer()
    private let closeGlyph = CAShapeLayer()

    private var currentInput: AVCaptureDeviceInput?
    private let voiceMeter = VoiceMeter()
    private let defaults = UserDefaults.standard

    private(set) var devices: [AVCaptureDevice] = []
    private(set) var currentDevice: AVCaptureDevice?

    /// 0.5 = círculo, 0.22 = squircle, 0 = quadrado
    var cornerFactor: CGFloat = 0.5 {
        didSet { relayout(); defaults.set(cornerFactor, forKey: Pref.corner) }
    }

    var mirrored = true {
        didSet { applyMirror(); defaults.set(mirrored, forKey: Pref.mirror) }
    }

    var ringStyle: RingStyle = .gradient {
        didSet { applyRingStyle(); defaults.set(ringStyle.rawValue, forKey: Pref.ringStyle) }
    }

    var themeIndex = 0 {
        didSet { applyTheme(); defaults.set(themeIndex, forKey: Pref.theme) }
    }

    var feathered = false {
        didSet { applyFeather(); defaults.set(feathered, forKey: Pref.feather) }
    }

    var graded = true {
        didSet { applyGrade(); defaults.set(graded, forKey: Pref.grade) }
    }

    var voiceReactive = false {
        didSet { applyVoice(); defaults.set(voiceReactive, forKey: Pref.voice) }
    }

    var autoFraming = false {
        didSet { applyFraming(); defaults.set(autoFraming, forKey: Pref.framing) }
    }

    var shadowed = true {
        didSet { applyShadow(); defaults.set(shadowed, forKey: Pref.shadow) }
    }

    /// Zoom do enquadramento (1 = imagem inteira cabendo no círculo).
    var zoom: CGFloat = 1.3 {
        didSet {
            zoom = zoom.clamped(1.0, 3.0)
            let current = pan
            pan = current                // reaplica os limites, que dependem do zoom
            relayout()
            defaults.set(Double(zoom), forKey: Pref.zoom)
        }
    }

    /// Deslocamento do enquadramento, em fração do quadro de vídeo.
    /// Limitado ao que existe de imagem, para nunca sobrar borda vazia.
    var pan = CGPoint(x: 0, y: 0) {
        didSet {
            pan = clamp(pan)
            relayout(animated: animatePan)
            defaults.set(Double(pan.x), forKey: Pref.panX)
            defaults.set(Double(pan.y), forKey: Pref.panY)
        }
    }

    /// Modo de mira: o próximo clique define o centro do enquadramento.
    var aiming = false {
        didSet { crosshair.isHidden = !aiming }
    }

    /// Mouse sobre o círculo: mostra o X de fechar.
    var hovering = false {
        didSet { animateCloseButton() }
    }

    /// Área clicável do X, em coordenadas da view.
    private(set) var closeButtonFrame: CGRect = .zero

    /// Área onde o hover é considerado (só o círculo visível, não o respiro).
    var hoverRect: CGRect { circleRect }

    private var animatePan = false
    private var videoAspect: CGFloat = 16.0 / 9.0

    var theme: Theme { Theme.all[min(max(themeIndex, 0), Theme.all.count - 1)] }

    /// Retângulo do círculo dentro da janela (deixando o respiro em volta).
    private var circleRect: CGRect {
        bounds.insetBy(dx: bounds.width * padRatio, dy: bounds.height * padRatio)
    }

    private var diameter: CGFloat { min(circleRect.width, circleRect.height) }
    private var ringWidth: CGFloat { max(2, diameter * 0.018) }

    /// Tamanho da camada de vídeo: cobre o círculo respeitando o aspecto real da
    /// câmera e depois aplica o zoom. O que passa do círculo é imagem disponível
    /// para deslocar — por isso o pan nunca revela borda vazia.
    private func previewSize(in local: CGSize) -> CGSize {
        guard local.width > 0, local.height > 0 else { return local }
        let clipAspect = local.width / local.height
        var base = local
        if videoAspect >= clipAspect {
            base = CGSize(width: local.height * videoAspect, height: local.height)
        } else {
            base = CGSize(width: local.width, height: local.width / videoAspect)
        }
        return CGSize(width: base.width * zoom, height: base.height * zoom)
    }

    /// Limita o pan ao excedente de imagem em cada eixo.
    private func clamp(_ point: CGPoint) -> CGPoint {
        let local = circleRect.size
        guard local.width > 1 else { return point }
        let size = previewSize(in: local)
        let maxX = size.width > local.width ? (size.width - local.width) / (2 * size.width) : 0
        let maxY = size.height > local.height ? (size.height - local.height) / (2 * size.height) : 0
        return CGPoint(x: point.x.clamped(-maxX, maxX), y: point.y.clamped(-maxY, maxY))
    }

    // MARK: Init

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer = CALayer()
        layer?.backgroundColor = .clear

        container.backgroundColor = .clear
        container.shadowColor = NSColor.black.cgColor

        clip.masksToBounds = true
        clip.backgroundColor = NSColor.black.cgColor

        preview.videoGravity = .resizeAspectFill

        // Vinheta: escurece de leve as bordas e joga o rosto pra frente.
        vignette.type = .radial
        vignette.colors = [
            NSColor.black.withAlphaComponent(0).cgColor,
            NSColor.black.withAlphaComponent(0).cgColor,
            NSColor.black.withAlphaComponent(0.32).cgColor,
        ]
        vignette.locations = [0, 0.64, 1]
        vignette.startPoint = CGPoint(x: 0.5, y: 0.5)
        vignette.endPoint = CGPoint(x: 1, y: 1)

        glow.fillColor = NSColor.clear.cgColor
        glow.shadowOpacity = 0.7
        glow.shadowOffset = .zero

        ringGradient.type = .conic
        ringGradient.startPoint = CGPoint(x: 0.5, y: 0.5)
        ringGradient.endPoint = CGPoint(x: 0.5, y: 0)
        ringMask.fillColor = NSColor.clear.cgColor
        ringMask.strokeColor = NSColor.white.cgColor
        ringHolder.addSublayer(ringGradient)
        ringHolder.mask = ringMask

        // Aro de vidro por dentro do anel: acabamento.
        rim.fillColor = NSColor.clear.cgColor
        rim.strokeColor = NSColor.white.withAlphaComponent(0.26).cgColor
        rim.lineWidth = 1

        featherMask.type = .radial
        featherMask.colors = [
            NSColor.white.cgColor,
            NSColor.white.cgColor,
            NSColor.white.withAlphaComponent(0).cgColor,
        ]
        featherMask.locations = [0, 0.78, 1]
        featherMask.startPoint = CGPoint(x: 0.5, y: 0.5)
        featherMask.endPoint = CGPoint(x: 1, y: 1)

        // Mira: alvo no centro, visível só no modo de mira.
        crosshair.fillColor = NSColor.clear.cgColor
        crosshair.strokeColor = NSColor.white.withAlphaComponent(0.95).cgColor
        crosshair.lineWidth = 1.5
        crosshair.shadowColor = NSColor.black.cgColor
        crosshair.shadowOpacity = 0.6
        crosshair.shadowRadius = 2
        crosshair.shadowOffset = .zero
        crosshair.isHidden = true

        // Botão de fechar: disco escuro translúcido com um X, aparece no hover.
        closeDisc.fillColor = NSColor.black.withAlphaComponent(0.62).cgColor
        closeDisc.strokeColor = NSColor.white.withAlphaComponent(0.3).cgColor
        closeDisc.lineWidth = 1
        closeDisc.shadowColor = NSColor.black.cgColor
        closeDisc.shadowOpacity = 0.5
        closeDisc.shadowRadius = 4
        closeDisc.shadowOffset = CGSize(width: 0, height: -1)
        closeGlyph.strokeColor = NSColor.white.withAlphaComponent(0.95).cgColor
        closeGlyph.fillColor = NSColor.clear.cgColor
        closeGlyph.lineCap = .round
        closeButton.addSublayer(closeDisc)
        closeButton.addSublayer(closeGlyph)
        closeButton.opacity = 0
        closeButton.transform = CATransform3DMakeScale(0.85, 0.85, 1)

        clip.addSublayer(preview)
        clip.addSublayer(vignette)
        clip.addSublayer(crosshair)
        container.addSublayer(clip)
        container.addSublayer(glow)
        container.addSublayer(ringHolder)
        container.addSublayer(rim)
        container.addSublayer(closeButton)
        layer?.addSublayer(container)

        session.sessionPreset = .high
        preview.session = session

        voiceMeter.onLevel = { [weak self] level in self?.pulse(level) }

        reloadDevices()
        let savedID = defaults.string(forKey: Pref.deviceID)
        if let target = devices.first(where: { $0.uniqueID == savedID }) ?? devices.first {
            select(device: target)
        }

        NotificationCenter.default.addObserver(
            self, selector: #selector(devicesChanged),
            name: AVCaptureDevice.wasConnectedNotification, object: nil)
        NotificationCenter.default.addObserver(
            self, selector: #selector(devicesChanged),
            name: AVCaptureDevice.wasDisconnectedNotification, object: nil)
    }

    required init?(coder: NSCoder) { fatalError() }

    /// Reaplica tudo (usado depois de carregar as preferências).
    func refreshAll() {
        relayout()
        applyTheme()
        applyRingStyle()
        applyFeather()
        applyGrade()
        applyVoice()
        applyFraming()
        applyShadow()
        applyMirror()
    }

    // MARK: Layout

    override func layout() {
        super.layout()
        relayout()
    }

    private func relayout(animated: Bool = false) {
        guard bounds.width > 1 else { return }
        let rect = circleRect
        let local = CGRect(origin: .zero, size: rect.size)
        let radius = min(rect.width, rect.height) * cornerFactor
        let width = ringWidth

        CATransaction.begin()
        CATransaction.setDisableActions(true)

        container.frame = bounds
        container.shadowPath = CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil)

        clip.frame = rect
        clip.cornerRadius = radius

        vignette.frame = local
        featherMask.frame = local
        crosshair.frame = local
        crosshair.path = crosshairPath(in: local)

        let ringRect = rect.insetBy(dx: width / 2, dy: width / 2)
        let ringRadius = max(0, radius - width / 2)
        let ringPath = CGPath(roundedRect: ringRect, cornerWidth: ringRadius,
                              cornerHeight: ringRadius, transform: nil)

        glow.frame = bounds
        glow.path = ringPath
        glow.lineWidth = width

        ringHolder.frame = bounds
        ringMask.frame = bounds
        ringMask.path = ringPath
        ringMask.lineWidth = width

        // Maior que a janela para não aparecer canto ao girar o gradiente.
        let side = bounds.width * 1.6
        ringGradient.bounds = CGRect(x: 0, y: 0, width: side, height: side)
        ringGradient.position = CGPoint(x: bounds.midX, y: bounds.midY)

        let rimRect = rect.insetBy(dx: width + 0.5, dy: width + 0.5)
        rim.frame = bounds
        rim.path = CGPath(roundedRect: rimRect,
                          cornerWidth: max(0, radius - width - 0.5),
                          cornerHeight: max(0, radius - width - 0.5), transform: nil)

        layoutCloseButton(in: rect)

        CATransaction.commit()

        // Zoom/pan: a camada de vídeo é maior que o clip e desliza dentro dele.
        // Fica numa transação separada para poder animar o reenquadramento.
        let size = previewSize(in: local.size)
        let target = CGRect(x: (local.width - size.width) / 2 + pan.x * size.width,
                            y: (local.height - size.height) / 2 + pan.y * size.height,
                            width: size.width, height: size.height)
        CATransaction.begin()
        if animated {
            CATransaction.setAnimationDuration(0.3)
            CATransaction.setAnimationTimingFunction(CAMediaTimingFunction(name: .easeOut))
        } else {
            CATransaction.setDisableActions(true)
        }
        preview.frame = target
        CATransaction.commit()

        applyShadow()
        applyTheme()
    }

    /// X de fechar, encostado na diagonal superior direita do círculo.
    private func layoutCloseButton(in rect: CGRect) {
        let size = max(18, diameter * 0.15)
        // 0.72 do raio na diagonal: fica sobre o anel tanto no círculo
        // quanto no squircle, e um pouco dentro no formato quadrado.
        let k: CGFloat = 0.72
        let center = CGPoint(x: rect.midX + rect.width / 2 * k,
                             y: rect.midY + rect.height / 2 * k)
        let frame = CGRect(x: center.x - size / 2, y: center.y - size / 2,
                           width: size, height: size)
        closeButtonFrame = frame
        closeButton.frame = frame

        let local = CGRect(origin: .zero, size: frame.size)
        closeDisc.frame = local
        closeDisc.path = CGPath(ellipseIn: local.insetBy(dx: 0.5, dy: 0.5), transform: nil)

        let inset = size * 0.32
        let glyph = CGMutablePath()
        glyph.move(to: CGPoint(x: inset, y: inset))
        glyph.addLine(to: CGPoint(x: size - inset, y: size - inset))
        glyph.move(to: CGPoint(x: size - inset, y: inset))
        glyph.addLine(to: CGPoint(x: inset, y: size - inset))
        closeGlyph.frame = local
        closeGlyph.path = glyph
        closeGlyph.lineWidth = max(1.5, size * 0.11)
    }

    private func animateCloseButton() {
        CATransaction.begin()
        CATransaction.setAnimationDuration(hovering ? 0.16 : 0.14)
        CATransaction.setAnimationTimingFunction(CAMediaTimingFunction(name: .easeOut))
        closeButton.opacity = hovering ? 1 : 0
        closeButton.transform = hovering
            ? CATransform3DIdentity
            : CATransform3DMakeScale(0.85, 0.85, 1)
        CATransaction.commit()
    }

    /// O ponto está sobre o X? (com uma folga para facilitar o clique)
    func closeButtonHit(_ point: CGPoint) -> Bool {
        hovering && closeButtonFrame.insetBy(dx: -4, dy: -4).contains(point)
    }

    /// Alvo central usado no modo de mira.
    private func crosshairPath(in local: CGRect) -> CGPath {
        let center = CGPoint(x: local.midX, y: local.midY)
        let radius = max(6, min(local.width, local.height) * 0.05)
        let tick = radius * 0.9
        let path = CGMutablePath()
        path.addEllipse(in: CGRect(x: center.x - radius, y: center.y - radius,
                                   width: radius * 2, height: radius * 2))
        path.move(to: CGPoint(x: center.x - radius - tick, y: center.y))
        path.addLine(to: CGPoint(x: center.x - radius, y: center.y))
        path.move(to: CGPoint(x: center.x + radius, y: center.y))
        path.addLine(to: CGPoint(x: center.x + radius + tick, y: center.y))
        path.move(to: CGPoint(x: center.x, y: center.y - radius - tick))
        path.addLine(to: CGPoint(x: center.x, y: center.y - radius))
        path.move(to: CGPoint(x: center.x, y: center.y + radius))
        path.addLine(to: CGPoint(x: center.x, y: center.y + radius + tick))
        return path
    }

    /// Centraliza o enquadramento no ponto clicado (coordenadas da view).
    /// Retorna false se o clique caiu fora do círculo.
    @discardableResult
    func center(onViewPoint point: CGPoint) -> Bool {
        let rect = circleRect
        guard rect.width > 1 else { return false }
        let local = CGRect(origin: .zero, size: rect.size)
        let local_point = CGPoint(x: point.x - rect.minX, y: point.y - rect.minY)

        // Dentro do círculo? (usa a forma atual: círculo, squircle ou quadrado)
        let radius = min(rect.width, rect.height) * cornerFactor
        let shape = CGPath(roundedRect: local, cornerWidth: radius, cornerHeight: radius, transform: nil)
        guard shape.contains(local_point) else { return false }

        // Ponto clicado nas coordenadas da camada de vídeo.
        let frame = preview.frame
        let onVideo = CGPoint(x: local_point.x - frame.minX, y: local_point.y - frame.minY)
        // Nova origem que leva esse ponto para o centro do clip.
        let origin = CGPoint(x: local.midX - onVideo.x, y: local.midY - onVideo.y)

        animatePan = true
        pan = CGPoint(x: (origin.x - (local.width - frame.width) / 2) / frame.width,
                      y: (origin.y - (local.height - frame.height) / 2) / frame.height)
        animatePan = false
        return true
    }

    // MARK: Efeitos

    private func applyShadow() {
        container.shadowOpacity = shadowed ? 0.32 : 0
        container.shadowRadius = diameter * 0.06
        container.shadowOffset = CGSize(width: 0, height: -diameter * 0.02)
    }

    private func applyTheme() {
        let accent = theme.colors[0]
        if ringStyle == .solid {
            ringGradient.colors = Array(repeating: accent.cgColor, count: 2)
        } else {
            ringGradient.colors = theme.colors.map { $0.cgColor }
        }
        glow.strokeColor = accent.withAlphaComponent(0.85).cgColor
        glow.shadowColor = accent.cgColor
        glow.shadowRadius = max(6, diameter * 0.05)
    }

    private func applyRingStyle() {
        let hidden = ringStyle == .none || feathered
        ringHolder.isHidden = hidden
        glow.isHidden = hidden
        rim.isHidden = hidden
        applyTheme()
        if ringStyle == .gradient && !hidden { startSpin() } else { stopSpin() }
    }

    private func startSpin() {
        guard ringGradient.animation(forKey: "spin") == nil else { return }
        let spin = CABasicAnimation(keyPath: "transform.rotation.z")
        spin.fromValue = 0
        spin.toValue = CGFloat.pi * 2
        spin.duration = 9
        spin.repeatCount = .infinity
        spin.isRemovedOnCompletion = false
        ringGradient.add(spin, forKey: "spin")
    }

    private func stopSpin() {
        ringGradient.removeAnimation(forKey: "spin")
    }

    private func applyFeather() {
        clip.mask = feathered ? featherMask : nil
        vignette.isHidden = feathered
        applyRingStyle()
    }

    private func applyGrade() {
        guard graded else { preview.filters = nil; return }
        var filters: [CIFilter] = []
        if let controls = CIFilter(name: "CIColorControls", parameters: [
            kCIInputSaturationKey: 1.10,
            kCIInputContrastKey: 1.06,
            kCIInputBrightnessKey: 0.015,
        ]) { filters.append(controls) }
        if let vibrance = CIFilter(name: "CIVibrance", parameters: ["inputAmount": 0.22]) {
            filters.append(vibrance)
        }
        preview.filters = filters.isEmpty ? nil : filters
    }

    private func applyVoice() {
        voiceReactive ? voiceMeter.start() : voiceMeter.stop()
    }

    /// O glow abre e fecha junto com a voz.
    private func pulse(_ level: CGFloat) {
        guard voiceReactive, ringStyle != .none, !feathered else { return }
        let eased = pow(level, 1.6)
        CATransaction.begin()
        CATransaction.setAnimationDuration(0.08)
        glow.shadowOpacity = Float(0.4 + eased * 0.6)
        glow.shadowRadius = max(6, diameter * (0.04 + eased * 0.07))
        CATransaction.commit()
    }

    private func applyFraming() {
        guard supportsAutoFraming else { return }
        // No macOS, Center Stage é controlado por propriedades de classe;
        // o app só pode mexer depois de assumir o controle.
        AVCaptureDevice.centerStageControlMode = .app
        AVCaptureDevice.isCenterStageEnabled = autoFraming
    }

    var supportsAutoFraming: Bool {
        currentDevice?.activeFormat.isCenterStageSupported ?? false
    }

    func resetFraming() {
        animatePan = true
        zoom = 1.0
        pan = .zero
        animatePan = false
    }

    /// Aspecto real do vídeo, usado para dimensionar a camada sem distorcer.
    private func updateAspect() {
        guard let format = currentDevice?.activeFormat else { return }
        let dims = CMVideoFormatDescriptionGetDimensions(format.formatDescription)
        guard dims.width > 0, dims.height > 0 else { return }
        videoAspect = CGFloat(dims.width) / CGFloat(dims.height)
    }

    // MARK: Câmeras

    @objc private func devicesChanged() {
        reloadDevices()
        if let current = currentDevice,
           !devices.contains(where: { $0.uniqueID == current.uniqueID }),
           let first = devices.first {
            select(device: first)
        }
    }

    func reloadDevices() {
        let types: [AVCaptureDevice.DeviceType] = [
            .builtInWideAngleCamera, .external, .continuityCamera,
        ]
        devices = AVCaptureDevice.DiscoverySession(
            deviceTypes: types, mediaType: .video, position: .unspecified).devices
    }

    func select(device: AVCaptureDevice) {
        session.beginConfiguration()
        if let currentInput { session.removeInput(currentInput) }
        currentInput = nil
        if let input = try? AVCaptureDeviceInput(device: device), session.canAddInput(input) {
            session.addInput(input)
            currentInput = input
            currentDevice = device
            defaults.set(device.uniqueID, forKey: Pref.deviceID)
        }
        session.commitConfiguration()
        updateAspect()
        applyMirror()
        applyFraming()
        relayout()
        if !session.isRunning {
            DispatchQueue.global(qos: .userInitiated).async { [session] in session.startRunning() }
        }
    }

    func cycleCamera() {
        reloadDevices()
        guard devices.count > 1, let current = currentDevice,
              let idx = devices.firstIndex(where: { $0.uniqueID == current.uniqueID })
        else { return }
        select(device: devices[(idx + 1) % devices.count])
    }

    private func applyMirror() {
        guard let connection = preview.connection, connection.isVideoMirroringSupported else { return }
        connection.automaticallyAdjustsVideoMirroring = false
        connection.isVideoMirrored = mirrored
    }

    func stop() {
        voiceMeter.stop()
        if session.isRunning { session.stopRunning() }
    }

    /// Entrada com spring.
    func playIntro() {
        let scale = CASpringAnimation(keyPath: "transform.scale")
        scale.fromValue = 0.84
        scale.toValue = 1.0
        scale.damping = 14
        scale.stiffness = 190
        scale.mass = 1
        scale.duration = scale.settlingDuration
        container.add(scale, forKey: "intro")

        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 0
        fade.toValue = 1
        fade.duration = 0.3
        container.add(fade, forKey: "fade")
    }
}

// MARK: - Painel de atalhos

/// Cartão translúcido com a lista de atalhos. Não rouba o foco do círculo.
final class HelpPanel {

    private var window: NSWindow?

    private static let items: [(String, String)] = [
        ("passar o mouse", "mostra o X de fechar"),
        ("arrastar", "mover o círculo"),
        ("scroll", "tamanho"),
        ("⌥ scroll", "zoom do enquadramento"),
        ("P + clique", "centralizar naquele ponto"),
        ("⌥ clique", "centralizar direto"),
        ("← → ↑ ↓", "ajuste fino do enquadramento"),
        ("Z", "ciclar zoom"),
        ("0", "voltar ao enquadramento padrão"),
        ("1 2 3", "pequeno / médio / grande"),
        ("+ −", "aumentar / diminuir"),
        ("S", "círculo / squircle / quadrado"),
        ("B", "anel: nenhum / sólido / gradiente"),
        ("T", "cor do anel"),
        ("D", "sombra"),
        ("F", "borda esfumaçada"),
        ("L", "realce studio"),
        ("V", "anel reage à voz"),
        ("A", "enquadramento automático"),
        ("M", "espelhar"),
        ("C", "trocar de câmera"),
        ("clique direito", "menu completo"),
        ("⌃⌥⌘P", "abre/fecha o teleprompter (funciona de qualquer app)"),
        ("H", "abrir/fechar esta lista"),
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
        let text = NSTextField(labelWithAttributedString: Self.attributedList())
        text.translatesAutoresizingMaskIntoConstraints = false

        let backdrop = NSVisualEffectView()
        backdrop.material = .hudWindow
        backdrop.blendingMode = .behindWindow
        backdrop.state = .active
        backdrop.wantsLayer = true
        backdrop.layer?.cornerRadius = 14
        backdrop.layer?.masksToBounds = true
        backdrop.addSubview(text)

        let pad: CGFloat = 18
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
        panel.contentView = backdrop
        panel.setFrame(Self.position(frame, near: host), display: false)

        // Janela filha: acompanha o círculo e nunca vira a janela ativa.
        host.addChildWindow(panel, ordered: .above)
        panel.orderFront(nil)
        window = panel
    }

    /// À esquerda do círculo; se não couber na tela, à direita.
    private static func position(_ frame: NSRect, near host: NSWindow) -> NSRect {
        let hostFrame = host.frame
        let visible = (host.screen ?? NSScreen.main)?.visibleFrame
            ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let gap: CGFloat = 8

        var x = hostFrame.minX - frame.width - gap
        if x < visible.minX { x = hostFrame.maxX + gap }
        if x + frame.width > visible.maxX { x = visible.maxX - frame.width - gap }

        var y = hostFrame.midY - frame.height / 2
        y = min(max(y, visible.minY + gap), visible.maxY - frame.height - gap)
        return NSRect(x: x, y: y, width: frame.width, height: frame.height)
    }

    private static func attributedList() -> NSAttributedString {
        let result = NSMutableAttributedString()

        let title = NSAttributedString(string: "CamCircle · atalhos\n\n", attributes: [
            .font: NSFont.systemFont(ofSize: 13, weight: .semibold),
            .foregroundColor: NSColor.white,
        ])
        result.append(title)

        // Duas colunas por tabulação: tecla à esquerda, ação à direita.
        let stops = [NSTextTab(textAlignment: .left, location: 110, options: [:])]
        let paragraph = NSMutableParagraphStyle()
        paragraph.tabStops = stops
        paragraph.lineSpacing = 3

        let keyFont = NSFont.monospacedSystemFont(ofSize: 11, weight: .semibold)
        let bodyFont = NSFont.systemFont(ofSize: 11.5)

        for (key, action) in items {
            let line = NSMutableAttributedString(string: key, attributes: [
                .font: keyFont,
                .foregroundColor: NSColor.white,
                .paragraphStyle: paragraph,
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

final class Overlay: NSObject, NSApplicationDelegate {

    static weak var shared: Overlay?

    private var window: OverlayWindow!
    private var cam: CameraCircleView!
    private let defaults = UserDefaults.standard
    private let help = HelpPanel()
    private var hotKey: EventHotKeyRef?

    func applicationDidFinishLaunching(_ notification: Notification) {
        Overlay.shared = self
        defaults.register(defaults: [
            Pref.size: 260.0,
            Pref.mirror: true,
            Pref.corner: 0.5,
            Pref.ringStyle: RingStyle.gradient.rawValue,
            Pref.theme: 0,
            Pref.feather: false,
            Pref.grade: true,
            Pref.voice: false,
            Pref.framing: false,
            Pref.shadow: true,
            Pref.zoom: 1.3,
            Pref.panX: 0.0,
            Pref.panY: 0.0,
        ])

        let diameter = CGFloat(defaults.double(forKey: Pref.size)).clamped(minSize, maxSize)
        let side = windowSide(forDiameter: diameter)
        let screen = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        var origin = NSPoint(x: screen.maxX - side - 24, y: screen.minY + 24)
        if defaults.object(forKey: Pref.originX) != nil {
            origin = NSPoint(x: defaults.double(forKey: Pref.originX),
                             y: defaults.double(forKey: Pref.originY))
        }

        window = OverlayWindow(
            contentRect: NSRect(origin: origin, size: CGSize(width: side, height: side)),
            styleMask: [.borderless], backing: .buffered, defer: false)
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        // O arraste é feito à mão (performDrag), senão o AppKit engoliria o
        // clique que usamos para reenquadrar.
        window.isMovableByWindowBackground = false
        window.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.overlayWindow)))
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]

        cam = CameraCircleView(frame: NSRect(origin: .zero, size: CGSize(width: side, height: side)))
        cam.cornerFactor = CGFloat(defaults.double(forKey: Pref.corner))
        cam.mirrored = defaults.bool(forKey: Pref.mirror)
        cam.themeIndex = defaults.integer(forKey: Pref.theme)
        cam.ringStyle = RingStyle(rawValue: defaults.integer(forKey: Pref.ringStyle)) ?? .gradient
        cam.feathered = defaults.bool(forKey: Pref.feather)
        cam.graded = defaults.bool(forKey: Pref.grade)
        cam.voiceReactive = defaults.bool(forKey: Pref.voice)
        cam.autoFraming = defaults.bool(forKey: Pref.framing)
        cam.shadowed = defaults.bool(forKey: Pref.shadow)
        cam.zoom = CGFloat(defaults.double(forKey: Pref.zoom))
        cam.pan = CGPoint(x: defaults.double(forKey: Pref.panX),
                          y: defaults.double(forKey: Pref.panY))
        cam.refreshAll()

        window.contentView = HostView(overlay: self, cam: cam)
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        cam.playIntro()
        installTeleprompterHotKey()

        AVCaptureDevice.requestAccess(for: .video) { granted in
            if !granted { DispatchQueue.main.async { self.showNoPermissionAlert() } }
        }
    }

    private func showNoPermissionAlert() {
        let alert = NSAlert()
        alert.messageText = "Sem acesso à câmera"
        alert.informativeText = "Libere em Ajustes do Sistema › Privacidade e Segurança › Câmera › CamCircle e abra o app de novo."
        alert.addButton(withTitle: "Abrir Ajustes")
        alert.addButton(withTitle: "Fechar")
        if alert.runModal() == .alertFirstButtonReturn,
           let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Camera") {
            NSWorkspace.shared.open(url)
        }
        NSApp.terminate(nil)
    }

    // MARK: Tamanho e posição

    func resize(by delta: CGFloat) {
        let current = window.frame.width * (1 - 2 * padRatio)
        setSize((current + delta).clamped(minSize, maxSize), animated: false)
    }

    func setSize(_ newDiameter: CGFloat, animated: Bool = true) {
        let side = windowSide(forDiameter: newDiameter)
        let frame = window.frame
        let target = NSRect(x: frame.midX - side / 2, y: frame.midY - side / 2,
                            width: side, height: side)
        move(to: target, animated: animated)
        defaults.set(Double(newDiameter), forKey: Pref.size)
    }

    private func move(to target: NSRect, animated: Bool) {
        if animated {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.22
                context.timingFunction = CAMediaTimingFunction(name: .easeOut)
                window.animator().setFrame(target, display: true)
            }
        } else {
            window.setFrame(target, display: true)
        }
        savePosition(target.origin)
    }

    /// Encaixa no canto mais próximo quando o círculo é solto perto dele.
    func snapToCorner() {
        guard let screen = window.screen ?? NSScreen.main else { savePosition(); return }
        let visible = screen.visibleFrame
        let frame = window.frame
        let margin: CGFloat = 6      // o respiro da janela já dá a folga visual
        let threshold: CGFloat = 110

        var x = frame.origin.x
        var y = frame.origin.y
        if abs(frame.minX - visible.minX) < threshold { x = visible.minX + margin }
        if abs(frame.maxX - visible.maxX) < threshold { x = visible.maxX - frame.width - margin }
        if abs(frame.minY - visible.minY) < threshold { y = visible.minY + margin }
        if abs(frame.maxY - visible.maxY) < threshold { y = visible.maxY - frame.height - margin }

        if x != frame.origin.x || y != frame.origin.y {
            move(to: NSRect(x: x, y: y, width: frame.width, height: frame.height), animated: true)
        } else {
            savePosition()
        }
    }

    func savePosition(_ origin: NSPoint? = nil) {
        let point = origin ?? window.frame.origin
        defaults.set(Double(point.x), forKey: Pref.originX)
        defaults.set(Double(point.y), forKey: Pref.originY)
    }

    // MARK: Enquadramento

    func zoom(by delta: CGFloat) { cam.zoom += delta }

    func cycleZoom() {
        let steps: [CGFloat] = [1.0, 1.15, 1.3, 1.5, 1.8]
        let next = steps.first(where: { $0 > cam.zoom + 0.01 }) ?? steps[0]
        cam.zoom = next
    }

    func pan(dx: CGFloat, dy: CGFloat) {
        cam.pan = CGPoint(x: cam.pan.x + dx, y: cam.pan.y + dy)
    }

    func resetFraming() { cam.resetFraming() }

    // MARK: Mira (clique para centralizar)

    private var cursorPushed = false

    var isAiming: Bool { cam.aiming }

    func setAiming(_ on: Bool) {
        cam.aiming = on
        if on && !cursorPushed {
            NSCursor.crosshair.push()
            cursorPushed = true
        } else if !on && cursorPushed {
            NSCursor.pop()
            cursorPushed = false
        }
    }

    func toggleAiming() { setAiming(!cam.aiming) }

    /// Leva o ponto clicado para o centro do círculo.
    func centerOn(point: CGPoint) {
        // Se o zoom está em 1 não há imagem sobrando para deslocar:
        // dá um zoom mínimo para o reenquadramento ter efeito.
        if cam.zoom < 1.05 { cam.zoom = 1.25 }
        cam.center(onViewPoint: point)
    }

    // MARK: Toggles

    func cycleShape() {
        let steps: [CGFloat] = [0.5, 0.22, 0.0]
        let idx = steps.firstIndex(where: { abs($0 - cam.cornerFactor) < 0.01 }) ?? 0
        cam.cornerFactor = steps[(idx + 1) % steps.count]
    }

    func cycleRing() {
        let all = RingStyle.allCases
        let idx = all.firstIndex(of: cam.ringStyle) ?? 0
        cam.ringStyle = all[(idx + 1) % all.count]
    }

    func cycleTheme() { cam.themeIndex = (cam.themeIndex + 1) % Theme.all.count }
    func toggleMirror() { cam.mirrored.toggle() }
    func toggleFeather() { cam.feathered.toggle() }
    func toggleGrade() { cam.graded.toggle() }
    func toggleVoice() { cam.voiceReactive.toggle() }
    func toggleFraming() { cam.autoFraming.toggle() }
    func toggleShadow() { cam.shadowed.toggle() }
    func cycleCamera() { cam.cycleCamera() }

    func setHovering(_ on: Bool) { cam.hovering = on }
    func closeButtonHit(_ point: CGPoint) -> Bool { cam.closeButtonHit(point) }

    var isHelpVisible: Bool { help.isVisible }
    func toggleHelp() { help.toggle(relativeTo: window) }
    func hideHelp() { help.hide() }

    // MARK: Ponte com o teleprompter

    /// ⌃⌥⌘P abre/fecha o teleprompter de qualquer app. Só este atalho é global
    /// aqui — o resto do CamCircle é local, porque o círculo é fácil de clicar.
    /// ⌃⌥⌘ de propósito: ⌥⌘P seria sequestrado do sistema (Configurar página).
    private func installTeleprompterHotKey() {
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                                 eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, _, _ -> OSStatus in
            DispatchQueue.main.async { Overlay.shared?.toggleTeleprompter() }
            return noErr
        }, 1, &spec, nil, nil)

        let id = EventHotKeyID(signature: OSType(0x43_41_4D_43), id: 1)   // 'CAMC'
        RegisterEventHotKey(UInt32(kVK_ANSI_P),
                            UInt32(controlKey | optionKey | cmdKey),
                            id, GetApplicationEventTarget(), 0, &hotKey)
    }

    func toggleTeleprompter() {
        Companion.toggle(name: "Teleprompter", bundleID: "com.startse.teleprompter")
    }

    var isTeleprompterRunning: Bool {
        Companion.isRunning(bundleID: "com.startse.teleprompter")
    }

    func quit() {
        help.hide()
        savePosition()
        cam.stop()
        NSApp.terminate(nil)
    }

    // MARK: Menu de contexto

    func contextMenu() -> NSMenu {
        let menu = NSMenu()

        cam.reloadDevices()
        if cam.devices.count > 1 {
            let header = NSMenuItem(title: "Câmera", action: nil, keyEquivalent: "")
            header.isEnabled = false
            menu.addItem(header)
            for device in cam.devices {
                let item = NSMenuItem(title: "   " + device.localizedName,
                                      action: #selector(pickDevice(_:)), keyEquivalent: "")
                item.target = self
                item.representedObject = device
                item.state = device.uniqueID == cam.currentDevice?.uniqueID ? .on : .off
                menu.addItem(item)
            }
            menu.addItem(.separator())
        }

        for (title, value) in [("Pequeno", 160.0), ("Médio", 260.0), ("Grande", 400.0)] {
            let item = NSMenuItem(title: title, action: #selector(pickSize(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = value
            menu.addItem(item)
        }
        menu.addItem(.separator())

        add(menu, String(format: "Zoom: %.0f%%  (Z)", Double(cam.zoom * 100)), #selector(menuZoom), "z")
        add(menu, "Centralizar em um ponto (clique depois)", #selector(menuAim), "p", on: cam.aiming)
        add(menu, "Voltar ao enquadramento padrão", #selector(menuResetFraming), "0")
        menu.addItem(.separator())

        add(menu, "Formato: círculo / squircle / quadrado", #selector(menuShape), "s")
        add(menu, "Anel: \(cam.ringStyle.label)", #selector(menuRing), "b")
        add(menu, "Cor do anel: \(cam.theme.name)", #selector(menuTheme), "t")
        add(menu, "Sombra", #selector(menuShadow), "d", on: cam.shadowed)
        add(menu, "Borda esfumaçada", #selector(menuFeather), "f", on: cam.feathered)
        add(menu, "Realce de imagem (studio)", #selector(menuGrade), "l", on: cam.graded)
        add(menu, "Anel reage à voz", #selector(menuVoice), "v", on: cam.voiceReactive)
        let framing = add(menu, "Enquadramento automático", #selector(menuFraming), "a", on: cam.autoFraming)
        framing.isEnabled = cam.supportsAutoFraming
        add(menu, "Espelhar imagem", #selector(menuMirror), "m", on: cam.mirrored)

        menu.addItem(.separator())
        // Mostra ⌃⌥⌘P, não "P" — no círculo o P é o modo de mira.
        let tp = add(menu, isTeleprompterRunning ? "Fechar teleprompter" : "Abrir teleprompter",
                     #selector(menuTeleprompter), "p")
        tp.keyEquivalentModifierMask = [.control, .option, .command]
        add(menu, "Atalhos…", #selector(menuHelp), "h", on: help.isVisible)
        add(menu, "Sair", #selector(menuQuit), "q")
        return menu
    }

    @discardableResult
    private func add(_ menu: NSMenu, _ title: String, _ action: Selector,
                     _ key: String, on: Bool? = nil) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.target = self
        if let on { item.state = on ? .on : .off }
        menu.addItem(item)
        return item
    }

    @objc private func pickDevice(_ sender: NSMenuItem) {
        if let device = sender.representedObject as? AVCaptureDevice { cam.select(device: device) }
    }
    @objc private func pickSize(_ sender: NSMenuItem) {
        if let value = sender.representedObject as? Double { setSize(CGFloat(value)) }
    }
    @objc private func menuZoom() { cycleZoom() }
    @objc private func menuAim() { toggleAiming() }
    @objc private func menuResetFraming() { resetFraming() }
    @objc private func menuShape() { cycleShape() }
    @objc private func menuRing() { cycleRing() }
    @objc private func menuTheme() { cycleTheme() }
    @objc private func menuShadow() { toggleShadow() }
    @objc private func menuFeather() { toggleFeather() }
    @objc private func menuGrade() { toggleGrade() }
    @objc private func menuVoice() { toggleVoice() }
    @objc private func menuFraming() { toggleFraming() }
    @objc private func menuMirror() { toggleMirror() }
    @objc private func menuHelp() { toggleHelp() }
    @objc private func menuTeleprompter() { toggleTeleprompter() }
    @objc private func menuQuit() { quit() }
}

// MARK: - View de eventos

final class HostView: NSView {

    private weak var overlay: Overlay?
    private weak var cam: CameraCircleView?
    private var hoverArea: NSTrackingArea?

    init(overlay: Overlay, cam: CameraCircleView) {
        self.overlay = overlay
        self.cam = cam
        super.init(frame: cam.frame)
        autoresizesSubviews = true
        cam.autoresizingMask = [.width, .height]
        addSubview(cam)
    }

    required init?(coder: NSCoder) { fatalError() }

    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    /// Hover só sobre o círculo visível, e com `activeAlways` para funcionar
    /// mesmo com outro app em foco.
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverArea { removeTrackingArea(hoverArea) }
        let rect = cam?.hoverRect ?? bounds
        let area = NSTrackingArea(rect: rect,
                                  options: [.mouseEnteredAndExited, .activeAlways],
                                  owner: self, userInfo: nil)
        addTrackingArea(area)
        hoverArea = area
    }

    override func mouseEntered(with event: NSEvent) {
        overlay?.setHovering(true)
    }

    override func mouseExited(with event: NSEvent) {
        overlay?.setHovering(false)
    }

    /// Scroll = tamanho. Option + scroll = zoom do enquadramento.
    override func scrollWheel(with event: NSEvent) {
        if event.modifierFlags.contains(.option) {
            overlay?.zoom(by: event.scrollingDeltaY * 0.01)
        } else {
            overlay?.resize(by: event.scrollingDeltaY * 1.5)
        }
    }

    override func magnify(with event: NSEvent) {
        if event.modifierFlags.contains(.option) {
            overlay?.zoom(by: CGFloat(event.magnification))
        } else {
            overlay?.resize(by: CGFloat(event.magnification) * 300)
        }
    }

    /// No modo de mira (ou com option) o clique reenquadra;
    /// fora dele, o clique arrasta a janela.
    override func mouseDown(with event: NSEvent) {
        guard let overlay else { return }
        let point = convert(event.locationInWindow, from: nil)

        if overlay.closeButtonHit(point) {
            overlay.quit()
            return
        }

        if overlay.isAiming || event.modifierFlags.contains(.option) {
            overlay.centerOn(point: point)
            overlay.setAiming(false)
            return
        }

        window?.performDrag(with: event)   // retorna quando o usuário solta
        overlay.snapToCorner()
    }

    override func rightMouseDown(with event: NSEvent) {
        guard let menu = overlay?.contextMenu() else { return }
        NSMenu.popUpContextMenu(menu, with: event, for: self)
    }

    override func keyDown(with event: NSEvent) {
        let step: CGFloat = 0.02
        switch event.charactersIgnoringModifiers?.lowercased() ?? "" {
        case "\u{1B}":                     // Esc fecha mira/ajuda antes de encerrar
            if overlay?.isAiming == true { overlay?.setAiming(false) }
            else if overlay?.isHelpVisible == true { overlay?.hideHelp() }
            else { overlay?.quit() }
        case "q": overlay?.quit()
        case "h", "?": overlay?.toggleHelp()
        case "p": overlay?.toggleAiming()
        case "m": overlay?.toggleMirror()
        case "s": overlay?.cycleShape()
        case "c": overlay?.cycleCamera()
        case "b": overlay?.cycleRing()
        case "t": overlay?.cycleTheme()
        case "d": overlay?.toggleShadow()
        case "f": overlay?.toggleFeather()
        case "l": overlay?.toggleGrade()
        case "v": overlay?.toggleVoice()
        case "a": overlay?.toggleFraming()
        case "z": overlay?.cycleZoom()
        case "0": overlay?.resetFraming()
        case "+", "=": overlay?.resize(by: 30)
        case "-", "_": overlay?.resize(by: -30)
        case "1": overlay?.setSize(160)
        case "2": overlay?.setSize(260)
        case "3": overlay?.setSize(400)
        case String(UnicodeScalar(NSUpArrowFunctionKey)!):    overlay?.pan(dx: 0, dy: -step)
        case String(UnicodeScalar(NSDownArrowFunctionKey)!):  overlay?.pan(dx: 0, dy: step)
        case String(UnicodeScalar(NSLeftArrowFunctionKey)!):  overlay?.pan(dx: step, dy: 0)
        case String(UnicodeScalar(NSRightArrowFunctionKey)!): overlay?.pan(dx: -step, dy: 0)
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
struct CamCircleApp {
    /// Retém o delegate — NSApplication.delegate é weak.
    static let overlay = Overlay()

    static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        app.delegate = overlay
        app.run()
    }
}
