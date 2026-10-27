#!/usr/bin/env swift
// Generates the tvOS app icon (layered), App Store icon and Top Shelf images into
// HomeBoard/Assets.xcassets, in the Quanta Insights palette. Run from the repo root:  swift tools/make-assets.swift
import AppKit
import ImageIO
import UniformTypeIdentifiers

// MARK: - Palette (Quanta Insights)

func rgb(_ hex: UInt32, _ alpha: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
}
let blue = rgb(0x4285F4), red = rgb(0xEA4335), yellow = rgb(0xFBBC04), green = rgb(0x34A853), gray = rgb(0x5F6368)
let background = rgb(0x0D1117), surface = rgb(0x161C24), surfaceTop = rgb(0x222B38), paper = rgb(0xF4F6FA)

// MARK: - Rendering

/// Draws into a top-left-origin context of `size` points at `scale`, returns PNG data.
func png(_ size: CGSize, scale: CGFloat, opaque: Bool, _ draw: (CGContext, CGSize) -> Void) -> Data {
    let w = Int(size.width * scale), h = Int(size.height * scale)
    let info = opaque ? CGImageAlphaInfo.noneSkipLast.rawValue : CGImageAlphaInfo.premultipliedLast.rawValue
    let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                        space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: info)!
    ctx.translateBy(x: 0, y: CGFloat(h))
    ctx.scaleBy(x: scale, y: -scale)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: true)
    draw(ctx, size)
    NSGraphicsContext.restoreGraphicsState()

    let data = NSMutableData()
    let dest = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(dest, ctx.makeImage()!, nil)
    CGImageDestinationFinalize(dest)
    return data as Data
}

func fill(_ ctx: CGContext, _ rect: CGRect, radius: CGFloat, _ color: CGColor) {
    ctx.addPath(CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil))
    ctx.setFillColor(color)
    ctx.fillPath()
}

func glow(_ ctx: CGContext, _ color: CGColor, at center: CGPoint, radius: CGFloat) {
    let g = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: [color, color.copy(alpha: 0)!] as CFArray, locations: [0, 1])!
    ctx.drawRadialGradient(g, startCenter: center, startRadius: 0, endCenter: center, endRadius: radius, options: [])
}

func backdrop(_ ctx: CGContext, _ s: CGSize) {
    let g = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: [surfaceTop, background] as CFArray, locations: [0, 1])!
    ctx.drawLinearGradient(g, start: .zero, end: CGPoint(x: s.width * 0.4, y: s.height), options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
    glow(ctx, rgb(0x4285F4, 0.22), at: CGPoint(x: s.width * 0.2, y: 0), radius: s.height * 0.9)
    glow(ctx, rgb(0x34A853, 0.12), at: CGPoint(x: s.width * 0.9, y: s.height), radius: s.height * 0.8)
}

func rounded(_ size: CGFloat, _ weight: NSFont.Weight) -> NSFont {
    let base = NSFont.systemFont(ofSize: size, weight: weight)
    return base.fontDescriptor.withDesign(.rounded).flatMap { NSFont(descriptor: $0, size: size) } ?? base
}

func text(_ s: String, at p: CGPoint, font: NSFont, color: CGColor) {
    NSAttributedString(string: s, attributes: [.font: font, .foregroundColor: NSColor(cgColor: color)!]).draw(at: p)
}

/// The Quanta aperture: four colored arcs around a dark lens with a highlight.
func aperture(_ ctx: CGContext, center c: CGPoint, diameter d: CGFloat, backing: Bool) {
    if backing {
        ctx.setFillColor(background)
        ctx.fillEllipse(in: CGRect(x: c.x - d / 2, y: c.y - d / 2, width: d, height: d))
    }
    let r = d * 0.36, line = d * 0.13, gap = 0.16 // radians
    ctx.setLineWidth(line)
    ctx.setLineCap(.round)
    for (i, color) in [blue, red, yellow, green].enumerated() {
        let start = Double(i) * .pi / 2 - .pi / 2 + gap
        ctx.setStrokeColor(color)
        ctx.addArc(center: c, radius: r, startAngle: start, endAngle: start + .pi / 2 - 2 * gap, clockwise: false)
        ctx.strokePath()
    }
    ctx.setFillColor(paper.copy(alpha: 0.9)!)
    let dot = d * 0.1
    ctx.fillEllipse(in: CGRect(x: c.x - d * 0.06 - dot / 2, y: c.y - d * 0.06 - dot / 2, width: dot, height: dot))
}

// MARK: - App icon layers (5:3 canvas)

func iconBack(_ ctx: CGContext, _ s: CGSize) { backdrop(ctx, s) }

/// The house body, in canvas coordinates.
func houseBody(_ s: CGSize) -> CGRect {
    CGRect(x: s.width * 0.335, y: s.height * 0.44, width: s.width * 0.33, height: s.height * 0.40)
}

func iconMiddle(_ ctx: CGContext, _ s: CGSize) {
    let body = houseBody(s), eave = s.width * 0.045
    let roof = CGMutablePath()
    roof.move(to: CGPoint(x: body.minX - eave, y: body.minY + s.height * 0.015))
    roof.addLine(to: CGPoint(x: s.width * 0.5, y: s.height * 0.13))
    roof.addLine(to: CGPoint(x: body.maxX + eave, y: body.minY + s.height * 0.015))
    roof.closeSubpath()

    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: s.height * 0.025), blur: s.height * 0.06, color: rgb(0x000000, 0.55))
    ctx.beginTransparencyLayer(auxiliaryInfo: nil)
    ctx.addPath(roof)
    ctx.setLineJoin(.round)
    ctx.setLineWidth(s.height * 0.05)
    ctx.setStrokeColor(paper)
    ctx.setFillColor(paper)
    ctx.drawPath(using: .fillStroke)
    fill(ctx, body, radius: s.height * 0.035, paper)
    ctx.endTransparencyLayer()
    ctx.restoreGState()

    // Four-color window: the board's tiles
    let pane = body.height * 0.29, gap = body.height * 0.06
    let grid = CGRect(x: body.midX - pane - gap / 2, y: body.minY + body.height * 0.2, width: pane * 2 + gap, height: pane * 2 + gap)
    for (i, color) in [blue, red, yellow, green].enumerated() {
        let rect = CGRect(x: grid.minX + CGFloat(i % 2) * (pane + gap), y: grid.minY + CGFloat(i / 2) * (pane + gap), width: pane, height: pane)
        fill(ctx, rect, radius: pane * 0.22, color)
    }
}

func iconFront(_ ctx: CGContext, _ s: CGSize) {
    let body = houseBody(s), d = s.height * 0.30
    let center = CGPoint(x: body.maxX + s.width * 0.005, y: body.maxY - s.height * 0.02)
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: s.height * 0.02), blur: s.height * 0.05, color: rgb(0x000000, 0.5))
    ctx.setFillColor(background)
    ctx.fillEllipse(in: CGRect(x: center.x - d / 2, y: center.y - d / 2, width: d, height: d))
    ctx.restoreGState()
    ctx.setStrokeColor(rgb(0xFFFFFF, 0.9))
    ctx.setLineWidth(s.height * 0.012)
    ctx.strokeEllipse(in: CGRect(x: center.x - d / 2, y: center.y - d / 2, width: d, height: d).insetBy(dx: s.height * 0.006, dy: s.height * 0.006))
    aperture(ctx, center: center, diameter: d, backing: false)
}

// MARK: - Top Shelf (720pt tall; content is laid out on a centered 1920pt stage)

func topShelf(_ ctx: CGContext, _ s: CGSize) {
    backdrop(ctx, s)
    let x0 = (s.width - 1920) / 2

    aperture(ctx, center: CGPoint(x: x0 + 210, y: 268), diameter: 120, backing: false)
    text("HomeBoard", at: CGPoint(x: x0 + 290, y: 200), font: rounded(118, .bold), color: rgb(0xFFFFFF))
    text("Weather, school and the house — at a glance.", at: CGPoint(x: x0 + 156, y: 350),
         font: rounded(40, .medium), color: rgb(0xB8C2D3))
    var lx = x0 + 156
    for (label, color) in [("Weather", blue), ("Alerts", red), ("School", yellow), ("Home", green)] {
        ctx.setFillColor(color)
        ctx.fillEllipse(in: CGRect(x: lx, y: 452, width: 22, height: 22))
        let font = rounded(30, .semibold)
        text(label, at: CGPoint(x: lx + 34, y: 442), font: font, color: rgb(0xE6EAF2))
        lx += 34 + (label as NSString).size(withAttributes: [.font: font]).width + 48
    }

    // Mini dashboard: briefing bar over weather, school and home panels
    let board = CGRect(x: x0 + 1060, y: 110, width: 720, height: 500)
    let briefing = CGRect(x: board.minX, y: board.minY, width: board.width, height: 96)
    fill(ctx, briefing, radius: 22, rgb(0x161C24, 0.95))
    aperture(ctx, center: CGPoint(x: briefing.minX + 50, y: briefing.midY), diameter: 56, backing: false)
    fill(ctx, CGRect(x: briefing.minX + 96, y: briefing.minY + 28, width: 380, height: 14), radius: 7, rgb(0xF1F4F9, 0.85))
    fill(ctx, CGRect(x: briefing.minX + 96, y: briefing.minY + 54, width: 260, height: 12), radius: 6, rgb(0xF1F4F9, 0.45))
    fill(ctx, CGRect(x: briefing.maxX - 170, y: briefing.minY + 28, width: 146, height: 40), radius: 20, rgb(0xEA4335, 0.25))
    fill(ctx, CGRect(x: briefing.maxX - 156, y: briefing.minY + 42, width: 118, height: 12), radius: 6, red)

    let gap: CGFloat = 16, top = briefing.maxY + gap
    let colW = (board.width - gap * 2) / 3, colH = board.maxY - top
    for (i, color) in [blue, yellow, green].enumerated() {
        let col = CGRect(x: board.minX + CGFloat(i) * (colW + gap), y: top, width: colW, height: colH)
        fill(ctx, col, radius: 22, rgb(0x161C24, 0.95))
        fill(ctx, CGRect(x: col.minX + 20, y: col.minY + 22, width: colW * 0.45, height: 14), radius: 7, color)
        var y = col.minY + 60
        for row in 0..<3 {
            let chip = CGRect(x: col.minX + 14, y: y, width: colW - 28, height: 82)
            fill(ctx, chip, radius: 14, color.copy(alpha: row == 0 ? 0.28 : 0.16)!)
            fill(ctx, CGRect(x: chip.minX + 16, y: chip.minY + 22, width: chip.width * 0.55, height: 14), radius: 7, rgb(0xF1F4F9, 0.85))
            fill(ctx, CGRect(x: chip.minX + 16, y: chip.minY + 46, width: chip.width * 0.35, height: 12), radius: 6, rgb(0xF1F4F9, 0.45))
            y += 96
        }
    }
}

// MARK: - Asset catalog

let root = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "HomeBoard/Assets.xcassets")
let fm = FileManager.default
let info: [String: Any] = ["author": "xcode", "version": 1]

func write(_ json: [String: Any], to dir: URL) {
    try! fm.createDirectory(at: dir, withIntermediateDirectories: true)
    let data = try! JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys])
    try! data.write(to: dir.appendingPathComponent("Contents.json"))
}

func imageset(_ dir: URL, base: String, size: CGSize, scales: [CGFloat], opaque: Bool, _ draw: @escaping (CGContext, CGSize) -> Void) {
    var images: [[String: Any]] = []
    try! fm.createDirectory(at: dir, withIntermediateDirectories: true)
    for scale in scales {
        let name = scale == 1 ? "\(base).png" : "\(base)@\(Int(scale))x.png"
        try! png(size, scale: scale, opaque: opaque, draw).write(to: dir.appendingPathComponent(name))
        images.append(["idiom": "tv", "scale": "\(Int(scale))x", "filename": name])
    }
    write(["images": images, "info": info], to: dir)
}

func imagestack(_ dir: URL, size: CGSize, scales: [CGFloat]) {
    let layers: [(String, Bool, (CGContext, CGSize) -> Void)] = [("Front", false, iconFront), ("Middle", false, iconMiddle), ("Back", true, iconBack)]
    write(["info": info, "layers": layers.map { ["filename": "\($0.0).imagestacklayer"] }], to: dir)
    for (name, opaque, draw) in layers {
        let layer = dir.appendingPathComponent("\(name).imagestacklayer")
        write(["info": info], to: layer)
        imageset(layer.appendingPathComponent("Content.imageset"), base: name.lowercased(), size: size, scales: scales, opaque: opaque, draw)
    }
}

try? fm.removeItem(at: root)
write(["info": info], to: root)
let brand = root.appendingPathComponent("App Icon & Top Shelf Image.brandassets")
write([
    "info": info,
    "assets": [
        ["filename": "App Icon - App Store.imagestack", "idiom": "tv", "role": "primary-app-icon", "size": "1280x768"],
        ["filename": "App Icon.imagestack", "idiom": "tv", "role": "primary-app-icon", "size": "400x240"],
        ["filename": "Top Shelf Image Wide.imageset", "idiom": "tv", "role": "top-shelf-image-wide", "size": "2320x720"],
        ["filename": "Top Shelf Image.imageset", "idiom": "tv", "role": "top-shelf-image", "size": "1920x720"],
    ],
], to: brand)

imagestack(brand.appendingPathComponent("App Icon.imagestack"), size: CGSize(width: 400, height: 240), scales: [1, 2])
imagestack(brand.appendingPathComponent("App Icon - App Store.imagestack"), size: CGSize(width: 1280, height: 768), scales: [1])
imageset(brand.appendingPathComponent("Top Shelf Image.imageset"), base: "topshelf", size: CGSize(width: 1920, height: 720), scales: [1, 2], opaque: true, topShelf)
imageset(brand.appendingPathComponent("Top Shelf Image Wide.imageset"), base: "topshelf-wide", size: CGSize(width: 2320, height: 720), scales: [1, 2], opaque: true, topShelf)

// Flattened previews for docs / quick review
let previews = URL(fileURLWithPath: "docs")
try? fm.createDirectory(at: previews, withIntermediateDirectories: true)
try! png(CGSize(width: 800, height: 480), scale: 1, opaque: true) { ctx, s in iconBack(ctx, s); iconMiddle(ctx, s); iconFront(ctx, s) }
    .write(to: previews.appendingPathComponent("app-icon.png"))
try! png(CGSize(width: 1920, height: 720), scale: 1, opaque: true, topShelf).write(to: previews.appendingPathComponent("top-shelf.png"))
print("Wrote \(root.path)")
