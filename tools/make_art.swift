import AppKit

// Рисует картинки «Развилки»: иконку приложения во всех размерах (для .icns), иконку для README,
// фон окна установщика .dmg (обычный и для Retina) и картинку того, как выглядит окно установщика.
//
//     swiftc -O -o build/make_art tools/make_art.swift && build/make_art <папка>
//
// В папке появятся AppIcon.iconset/, icon-256.png, dmg-background.png, dmg-background@2x.png, dmg-preview.png.

let tealTop = NSColor(srgbRed: 0.14, green: 0.68, blue: 0.53, alpha: 1)
let tealBottom = NSColor(srgbRed: 0.03, green: 0.35, blue: 0.27, alpha: 1)
let tealDeep = NSColor(srgbRed: 0.02, green: 0.24, blue: 0.19, alpha: 1)
let amber = NSColor(srgbRed: 0.98, green: 0.78, blue: 0.46, alpha: 1)

/// Холст заданного размера в пикселях; рисование в координатах width×height (ось y вверх).
func render(pixelsWide: Int, pixelsHigh: Int, width: CGFloat, height: CGFloat, _ draw: (CGContext) -> Void) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixelsWide, pixelsHigh: pixelsHigh,
                               bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    let g = NSGraphicsContext(bitmapImageRep: rep)!
    NSGraphicsContext.current = g
    g.imageInterpolation = .high
    let ctx = g.cgContext
    ctx.scaleBy(x: CGFloat(pixelsWide) / width, y: CGFloat(pixelsHigh) / height)
    draw(ctx)
    NSGraphicsContext.restoreGraphicsState()
    rep.size = NSSize(width: width, height: height)   // плотность точек для Retina-картинок (@2x = 144 dpi)
    return rep.representation(using: .png, properties: [:])!
}

/// Наконечник стрелки: острие в направлении d от точки end.
func arrowHead(_ ctx: CGContext, end: CGPoint, d: CGVector, length: CGFloat, halfWidth: CGFloat, color: NSColor) {
    let p = CGVector(dx: d.dy, dy: -d.dx)
    let apex = CGPoint(x: end.x + d.dx * length, y: end.y + d.dy * length)
    let base = CGPoint(x: end.x - d.dx * length * 0.2, y: end.y - d.dy * length * 0.2)
    ctx.beginPath()
    ctx.move(to: apex)
    ctx.addLine(to: CGPoint(x: base.x + p.dx * halfWidth, y: base.y + p.dy * halfWidth))
    ctx.addLine(to: CGPoint(x: base.x - p.dx * halfWidth, y: base.y - p.dy * halfWidth))
    ctx.closePath()
    ctx.setFillColor(color.cgColor)
    ctx.setStrokeColor(color.cgColor)
    ctx.setLineWidth(length * 0.22)
    ctx.setLineJoin(.round)
    ctx.drawPath(using: .fillStroke)
}

func unit(_ from: CGPoint, _ to: CGPoint) -> CGVector {
    let dx = to.x - from.x, dy = to.y - from.y
    let len = (dx * dx + dy * dy).squareRoot()
    return CGVector(dx: dx / len, dy: dy / len)
}

/// Иконка в координатах 1024×1024 по сетке значков macOS: тело 824×824 с отступом 100.
func drawIcon(_ ctx: CGContext) {
    let body = CGRect(x: 100, y: 100, width: 824, height: 824)
    let bodyPath = CGPath(roundedRect: body, cornerWidth: 185, cornerHeight: 185, transform: nil)

    // Тень под телом
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -10), blur: 26, color: NSColor.black.withAlphaComponent(0.30).cgColor)
    ctx.addPath(bodyPath)
    ctx.setFillColor(tealBottom.cgColor)
    ctx.fillPath()
    ctx.restoreGState()

    // Тело: сверху светлее, снизу глубже
    ctx.saveGState()
    ctx.addPath(bodyPath)
    ctx.clip()
    let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                              colors: [tealTop.cgColor, tealBottom.cgColor] as CFArray, locations: [0, 1])!
    ctx.drawLinearGradient(gradient, start: CGPoint(x: 512, y: 924), end: CGPoint(x: 512, y: 100), options: [])

    let fork = CGPoint(x: 512, y: 500)
    let stemStart = CGPoint(x: 512, y: 238)
    let leftEnd = CGPoint(x: 352, y: 752)
    let rightEnd = CGPoint(x: 672, y: 752)
    let road: CGFloat = 108

    func stroke(_ points: [CGPoint], _ color: NSColor, width: CGFloat, offset: CGFloat = 0) {
        ctx.beginPath()
        ctx.move(to: CGPoint(x: points[0].x, y: points[0].y + offset))
        for p in points.dropFirst() { ctx.addLine(to: CGPoint(x: p.x, y: p.y + offset)) }
        ctx.setStrokeColor(color.cgColor)
        ctx.setLineWidth(width)
        ctx.setLineCap(.round)
        ctx.setLineJoin(.round)
        ctx.strokePath()
    }

    // Мягкая тень дороги
    let shadow = tealDeep.withAlphaComponent(0.35)
    stroke([stemStart, fork, leftEnd], shadow, width: road, offset: -18)
    stroke([fork, rightEnd], shadow, width: road, offset: -18)

    // Правая ветка (янтарная) уходит из-под белой дороги
    let dr = unit(fork, rightEnd)
    stroke([fork, rightEnd], amber, width: road)
    arrowHead(ctx, end: rightEnd, d: dr, length: 96, halfWidth: 104, color: amber)

    let dl = unit(fork, leftEnd)
    stroke([stemStart, fork, leftEnd], .white, width: road)
    arrowHead(ctx, end: leftEnd, d: dl, length: 96, halfWidth: 104, color: .white)

    // Разметка посередине ствола
    ctx.beginPath()
    ctx.move(to: CGPoint(x: 512, y: 262))
    ctx.addLine(to: CGPoint(x: 512, y: 452))
    ctx.setStrokeColor(tealBottom.withAlphaComponent(0.85).cgColor)
    ctx.setLineWidth(11)
    ctx.setLineCap(.round)
    ctx.setLineDash(phase: 0, lengths: [30, 28])
    ctx.strokePath()
    ctx.setLineDash(phase: 0, lengths: [])

    // Лёгкий блик по верхнему краю
    let shine = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                           colors: [NSColor.white.withAlphaComponent(0.16).cgColor, NSColor.white.withAlphaComponent(0).cgColor] as CFArray,
                           locations: [0, 1])!
    ctx.drawLinearGradient(shine, start: CGPoint(x: 512, y: 924), end: CGPoint(x: 512, y: 700), options: [])
    ctx.restoreGState()

    // Тонкая обводка, чтобы тело не терялось на белом фоне
    ctx.addPath(bodyPath)
    ctx.setStrokeColor(NSColor.black.withAlphaComponent(0.10).cgColor)
    ctx.setLineWidth(2)
    ctx.strokePath()
}

func iconPNG(_ px: Int) -> Data {
    render(pixelsWide: px, pixelsHigh: px, width: 1024, height: 1024, drawIcon)
}

// MARK: Окно установщика

let dmgW: CGFloat = 660, dmgH: CGFloat = 380
/// Центры значков в координатах Finder (от левого верхнего угла); те же числа в packaging/dmg_settings.py.
let appSpot = CGPoint(x: 170, y: 140), appsSpot = CGPoint(x: 490, y: 140)

func text(_ s: String, size: CGFloat, weight: NSFont.Weight, color: NSColor, in rect: CGRect) {
    let style = NSMutableParagraphStyle()
    style.alignment = .center
    style.lineSpacing = 3
    NSAttributedString(string: s, attributes: [
        .font: NSFont.systemFont(ofSize: size, weight: weight),
        .foregroundColor: color,
        .paragraphStyle: style,
    ]).draw(with: rect, options: [.usesLineFragmentOrigin])
}

func drawBackground(_ ctx: CGContext) {
    NSColor(srgbRed: 0.97, green: 0.965, blue: 0.95, alpha: 1).setFill()
    CGRect(x: 0, y: 0, width: dmgW, height: dmgH).fill()

    // Стрелка от значка программы к «Программам»
    let y = dmgH - appSpot.y
    let from = CGPoint(x: appSpot.x + 82, y: y), to = CGPoint(x: appsSpot.x - 92, y: y)
    ctx.beginPath()
    ctx.move(to: from)
    ctx.addCurve(to: to, control1: CGPoint(x: from.x + 50, y: y + 34), control2: CGPoint(x: to.x - 50, y: y + 34))
    ctx.setStrokeColor(amber.blended(withFraction: 0.25, of: .brown)!.cgColor)
    ctx.setLineWidth(6)
    ctx.setLineCap(.round)
    ctx.strokePath()
    arrowHead(ctx, end: to, d: unit(CGPoint(x: to.x - 50, y: y + 34), to), length: 16, halfWidth: 13,
              color: amber.blended(withFraction: 0.25, of: .brown)!)

    let ink = NSColor(srgbRed: 0.16, green: 0.16, blue: 0.15, alpha: 1)
    let muted = NSColor(srgbRed: 0.42, green: 0.42, blue: 0.40, alpha: 1)
    text("Перетащите «Развилку» в папку «Программы»", size: 16, weight: .semibold, color: ink,
         in: CGRect(x: 30, y: 112, width: dmgW - 60, height: 24))
    text("При первом запуске macOS предупредит, что не может проверить программу.\nОткройте «Системные настройки» → «Конфиденциальность и безопасность»\nи нажмите «Открыть всё равно».",
         size: 12.5, weight: .regular, color: muted, in: CGRect(x: 30, y: 30, width: dmgW - 60, height: 72))
}

func backgroundPNG(scale: Int) -> Data {
    render(pixelsWide: Int(dmgW) * scale, pixelsHigh: Int(dmgH) * scale, width: dmgW, height: dmgH, drawBackground)
}

/// Как выглядит окно установщика: фон, значки и подписи. Для README и для показа до публикации.
func previewPNG() -> Data {
    let titleBar: CGFloat = 28
    let w = dmgW, h = dmgH + titleBar
    return render(pixelsWide: Int(w) * 2, pixelsHigh: Int(h) * 2, width: w, height: h) { ctx in
        let window = CGPath(roundedRect: CGRect(x: 0, y: 0, width: w, height: h), cornerWidth: 12, cornerHeight: 12, transform: nil)
        ctx.addPath(window)
        ctx.clip()
        drawBackground(ctx)
        NSColor(srgbRed: 0.93, green: 0.925, blue: 0.91, alpha: 1).setFill()
        CGRect(x: 0, y: dmgH, width: w, height: titleBar).fill()
        for (i, c) in [NSColor.systemRed, .systemYellow, .systemGreen].enumerated() {
            c.setFill()
            NSBezierPath(ovalIn: CGRect(x: 12 + CGFloat(i) * 20, y: dmgH + 8, width: 12, height: 12)).fill()
        }
        text("Развилка", size: 13, weight: .semibold, color: .darkGray, in: CGRect(x: 0, y: dmgH + 6, width: w, height: 18))
        let iconSize: CGFloat = 112
        let appIcon = NSImage(data: iconPNG(256))!
        let folder = NSWorkspace.shared.icon(forFile: "/Applications")
        for (image, spot, label) in [(appIcon, appSpot, "Развилка"), (folder, appsSpot, "Программы")] {
            let y = dmgH - spot.y
            image.draw(in: CGRect(x: spot.x - iconSize / 2, y: y - iconSize / 2, width: iconSize, height: iconSize))
            text(label, size: 13, weight: .regular, color: .black, in: CGRect(x: spot.x - 80, y: y - iconSize / 2 - 22, width: 160, height: 18))
        }
        ctx.resetClip()
        ctx.addPath(window)
        ctx.setStrokeColor(NSColor.black.withAlphaComponent(0.18).cgColor)
        ctx.setLineWidth(1)
        ctx.strokePath()
    }
}

// MARK: main

let out = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "build/art", isDirectory: true)
let iconset = out.appendingPathComponent("AppIcon.iconset", isDirectory: true)
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
for base in [16, 32, 128, 256, 512] {
    try iconPNG(base).write(to: iconset.appendingPathComponent("icon_\(base)x\(base).png"))
    try iconPNG(base * 2).write(to: iconset.appendingPathComponent("icon_\(base)x\(base)@2x.png"))
}
try iconPNG(256).write(to: out.appendingPathComponent("icon-256.png"))
try backgroundPNG(scale: 1).write(to: out.appendingPathComponent("dmg-background.png"))
try backgroundPNG(scale: 2).write(to: out.appendingPathComponent("dmg-background@2x.png"))
try previewPNG().write(to: out.appendingPathComponent("dmg-preview.png"))
print("art ok")
