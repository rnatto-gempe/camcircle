import AppKit

// Gera os .iconset dos dois apps. A App Store exige ícone em todos os tamanhos,
// e um app sem ícone é rejeitado na revisão antes de qualquer outra coisa.
//
// Uso: swift MakeIcons.swift <diretório-de-saída>

let sizes = [16, 32, 64, 128, 256, 512, 1024]

/// Fundo squircle padrão do macOS, com o respiro que a Apple espera.
func squircle(in rect: CGRect) -> NSBezierPath {
    NSBezierPath(roundedRect: rect, xRadius: rect.width * 0.222, yRadius: rect.width * 0.222)
}

func render(_ side: CGFloat, draw: (CGRect, CGFloat) -> Void) -> NSImage {
    let image = NSImage(size: CGSize(width: side, height: side))
    image.lockFocus()
    NSGraphicsContext.current?.imageInterpolation = .high

    // 10% de respiro em cada lado: o ícone não encosta na borda do slot.
    let inset = side * 0.10
    let plate = CGRect(x: inset, y: inset, width: side - inset * 2, height: side - inset * 2)

    NSColor(srgbRed: 0.09, green: 0.09, blue: 0.11, alpha: 1).setFill()
    squircle(in: plate).fill()

    draw(plate, side)
    image.unlockFocus()
    return image
}

/// CamCircle: o círculo com o anel gradiente, que é a identidade do app.
func camCircleIcon(_ side: CGFloat) -> NSImage {
    render(side) { plate, side in
        let d = plate.width * 0.62
        let circle = CGRect(x: plate.midX - d / 2, y: plate.midY - d / 2, width: d, height: d)
        let ring = max(1, side * 0.055)

        // Anel: aproximação do gradiente cônico em segmentos.
        let colors = [
            NSColor(srgbRed: 0.42, green: 0.36, blue: 0.98, alpha: 1),
            NSColor(srgbRed: 0.85, green: 0.34, blue: 0.86, alpha: 1),
            NSColor(srgbRed: 0.31, green: 0.78, blue: 0.98, alpha: 1),
            NSColor(srgbRed: 0.42, green: 0.36, blue: 0.98, alpha: 1),
        ]
        let steps = max(24, Int(side / 6))
        for i in 0..<steps {
            let t = CGFloat(i) / CGFloat(steps)
            let idx = t * CGFloat(colors.count - 1)
            let lo = colors[Int(idx)]
            let hi = colors[min(Int(idx) + 1, colors.count - 1)]
            let f = idx - CGFloat(Int(idx))
            lo.blended(withFraction: f, of: hi)?.setStroke()

            let arc = NSBezierPath()
            arc.appendArc(withCenter: CGPoint(x: circle.midX, y: circle.midY),
                          radius: d / 2 - ring / 2,
                          startAngle: t * 360 - 1.5,
                          endAngle: (CGFloat(i + 1) / CGFloat(steps)) * 360 + 1.5)
            arc.lineWidth = ring
            arc.stroke()
        }

        // Miolo: silhueta de cabeça e ombros, sugerindo a webcam.
        NSColor(srgbRed: 0.16, green: 0.17, blue: 0.21, alpha: 1).setFill()
        NSBezierPath(ovalIn: circle.insetBy(dx: ring, dy: ring)).fill()

        NSColor(srgbRed: 0.62, green: 0.68, blue: 0.78, alpha: 1).setFill()
        let head = d * 0.24
        NSBezierPath(ovalIn: CGRect(x: circle.midX - head / 2,
                                    y: circle.midY + d * 0.04,
                                    width: head, height: head)).fill()
        let shoulders = CGRect(x: circle.midX - d * 0.23, y: circle.minY + ring * 1.1,
                               width: d * 0.46, height: d * 0.30)
        NSBezierPath(roundedRect: shoulders,
                     xRadius: shoulders.width * 0.45,
                     yRadius: shoulders.width * 0.45).fill()
    }
}

/// Teleprompter: linhas de texto com a linha de leitura destacada.
func teleprompterIcon(_ side: CGFloat) -> NSImage {
    render(side) { plate, side in
        let inner = plate.insetBy(dx: plate.width * 0.14, dy: plate.width * 0.17)
        let accent = NSColor(srgbRed: 0.42, green: 0.78, blue: 0.98, alpha: 1)

        // Linhas de texto, com opacidade caindo nas pontas (o fade do painel).
        let count = 5
        let gap = inner.height / CGFloat(count)
        let h = max(1, gap * 0.30)
        for i in 0..<count {
            let y = inner.maxY - gap * CGFloat(i) - gap * 0.5
            let isReading = i == 2
            let w = isReading ? inner.width : inner.width * [0.82, 0.94, 1.0, 0.90, 0.70][i]
            let alpha: CGFloat = isReading ? 1.0 : [0.30, 0.55, 1, 0.55, 0.28][i]

            (isReading ? NSColor.white : NSColor.white.withAlphaComponent(alpha)).setFill()
            let bar = CGRect(x: inner.midX - w / 2, y: y - h / 2, width: w, height: h)
            NSBezierPath(roundedRect: bar, xRadius: h / 2, yRadius: h / 2).fill()
        }

        // A linha de leitura: o traço azul do painel.
        accent.setStroke()
        let line = NSBezierPath()
        let ly = inner.maxY - gap * 2 - gap * 0.5 - gap * 0.46
        line.move(to: CGPoint(x: inner.minX, y: ly))
        line.line(to: CGPoint(x: inner.maxX, y: ly))
        line.lineWidth = max(1, side * 0.016)
        line.stroke()
    }
}

// MARK: - Escrita

let out = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "."

func write(_ name: String, _ maker: (CGFloat) -> NSImage) {
    let dir = "\(out)/\(name).iconset"
    try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)

    // iconutil espera exatamente estes nomes.
    let plan: [(Int, String)] = [
        (16, "icon_16x16"), (32, "icon_16x16@2x"),
        (32, "icon_32x32"), (64, "icon_32x32@2x"),
        (128, "icon_128x128"), (256, "icon_128x128@2x"),
        (256, "icon_256x256"), (512, "icon_256x256@2x"),
        (512, "icon_512x512"), (1024, "icon_512x512@2x"),
    ]

    for (side, file) in plan {
        let image = maker(CGFloat(side))
        guard let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:])
        else { continue }
        try? png.write(to: URL(fileURLWithPath: "\(dir)/\(file).png"))
    }
    print("\(dir)")
}

write("CamCircle", camCircleIcon)
write("Teleprompter", teleprompterIcon)
