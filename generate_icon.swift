#!/usr/bin/env swift
import AppKit
import CoreGraphics

func drawBroomIcon(size: CGFloat) -> NSImage {
    let image = NSImage(size: NSSize(width: size, height: size))
    image.lockFocus()

    guard let ctx = NSGraphicsContext.current?.cgContext else {
        image.unlockFocus()
        return image
    }

    let scale = size / 1024.0
    ctx.saveGState()
    ctx.scaleBy(x: scale, y: scale)

    let colorSpace = CGColorSpaceCreateDeviceRGB()

    // 1. macOS Squircle Background with Drop Shadow
    let inset: CGFloat = 100.0
    let rect = CGRect(x: inset, y: inset, width: 1024 - inset * 2, height: 1024 - inset * 2)
    let cornerRadius: CGFloat = 185.0
    let bgPath = CGPath(roundedRect: rect, cornerWidth: cornerRadius, cornerHeight: cornerRadius, transform: nil)

    ctx.saveGState()
    ctx.setShadow(
        offset: CGSize(width: 0, height: -22),
        blur: 36,
        color: CGColor(red: 0.02, green: 0.05, blue: 0.15, alpha: 0.48)
    )
    ctx.addPath(bgPath)
    ctx.setFillColor(CGColor(red: 0.08, green: 0.16, blue: 0.36, alpha: 1.0))
    ctx.fillPath()
    ctx.restoreGState()

    // Clip to squircle for interior gradients & glow
    ctx.saveGState()
    ctx.addPath(bgPath)
    ctx.clip()

    // Main background gradient (deep royal blue -> vibrant cyan-blue)
    let bgColors = [
        CGColor(red: 0.07, green: 0.13, blue: 0.32, alpha: 1.0),
        CGColor(red: 0.11, green: 0.28, blue: 0.58, alpha: 1.0),
        CGColor(red: 0.16, green: 0.48, blue: 0.78, alpha: 1.0)
    ] as CFArray
    let bgLocations: [CGFloat] = [0.0, 0.55, 1.0]
    if let bgGrad = CGGradient(colorsSpace: colorSpace, colors: bgColors, locations: bgLocations) {
        ctx.drawLinearGradient(
            bgGrad,
            start: CGPoint(x: 512, y: inset),
            end: CGPoint(x: 512, y: 1024 - inset),
            options: []
        )
    }

    // Subtle radial glow behind the broom head
    let glowColors = [
        CGColor(red: 0.30, green: 0.82, blue: 0.98, alpha: 0.42),
        CGColor(red: 0.30, green: 0.82, blue: 0.98, alpha: 0.0)
    ] as CFArray
    if let glowGrad = CGGradient(colorsSpace: colorSpace, colors: glowColors, locations: [0.0, 1.0]) {
        ctx.drawRadialGradient(
            glowGrad,
            startCenter: CGPoint(x: 410, y: 380),
            startRadius: 20,
            endCenter: CGPoint(x: 410, y: 380),
            endRadius: 340,
            options: []
        )
    }

    // Sweep motion arc (clean trail)
    ctx.saveGState()
    let sweepPath = CGMutablePath()
    sweepPath.move(to: CGPoint(x: 220, y: 310))
    sweepPath.addQuadCurve(to: CGPoint(x: 760, y: 290), control: CGPoint(x: 470, y: 150))
    sweepPath.addQuadCurve(to: CGPoint(x: 260, y: 370), control: CGPoint(x: 490, y: 235))
    sweepPath.closeSubpath()
    ctx.addPath(sweepPath)
    ctx.setFillColor(CGColor(red: 0.55, green: 0.92, blue: 1.0, alpha: 0.22))
    ctx.fillPath()
    ctx.restoreGState()

    // 2. Draw the Broom (rotated at -35 degrees around center)
    ctx.saveGState()
    ctx.translateBy(x: 512, y: 512)
    ctx.rotate(by: -35.0 * .pi / 180.0)

    // Shadow for entire broom
    ctx.setShadow(
        offset: CGSize(width: 10, height: -18),
        blur: 24,
        color: CGColor(red: 0.0, green: 0.04, blue: 0.14, alpha: 0.50)
    )

    // --- A. Wooden Handle (Stick) ---
    let handleWidth: CGFloat = 46.0
    let handleBottomY: CGFloat = -20.0
    let handleTopY: CGFloat = 355.0
    let handleRect = CGRect(x: -handleWidth / 2.0, y: handleBottomY, width: handleWidth, height: handleTopY - handleBottomY)
    let handlePath = CGPath(roundedRect: handleRect, cornerWidth: handleWidth / 2.0, cornerHeight: handleWidth / 2.0, transform: nil)

    ctx.saveGState()
    ctx.addPath(handlePath)
    ctx.clip()
    let woodColors = [
        CGColor(red: 0.58, green: 0.33, blue: 0.14, alpha: 1.0),
        CGColor(red: 0.85, green: 0.56, blue: 0.28, alpha: 1.0),
        CGColor(red: 0.45, green: 0.24, blue: 0.09, alpha: 1.0)
    ] as CFArray
    if let woodGrad = CGGradient(colorsSpace: colorSpace, colors: woodColors, locations: [0.0, 0.4, 1.0]) {
        ctx.drawLinearGradient(
            woodGrad,
            start: CGPoint(x: -handleWidth / 2.0, y: 0),
            end: CGPoint(x: handleWidth / 2.0, y: 0),
            options: []
        )
    }
    // Hanging hole at top of handle
    ctx.setFillColor(CGColor(red: 0.10, green: 0.22, blue: 0.45, alpha: 0.85))
    ctx.fillEllipse(in: CGRect(x: -8, y: handleTopY - 34, width: 16, height: 16))
    ctx.restoreGState()

    // --- B. Broom Bristles (Flared Golden Head) ---
    let bristlePath = CGMutablePath()
    // Top of bristles (inside cap)
    bristlePath.move(to: CGPoint(x: -48, y: -15))
    bristlePath.addLine(to: CGPoint(x: 48, y: -15))
    // Right curve flaring out to bottom-right
    bristlePath.addCurve(
        to: CGPoint(x: 165, y: -275),
        control1: CGPoint(x: 82, y: -85),
        control2: CGPoint(x: 145, y: -185)
    )
    // Sweeping bottom edge with slight dynamic wave
    bristlePath.addQuadCurve(
        to: CGPoint(x: -145, y: -285),
        control: CGPoint(x: 10, y: -325)
    )
    // Left curve back to cap
    bristlePath.addCurve(
        to: CGPoint(x: -48, y: -15),
        control1: CGPoint(x: -135, y: -190),
        control2: CGPoint(x: -80, y: -85)
    )
    bristlePath.closeSubpath()

    ctx.saveGState()
    ctx.addPath(bristlePath)
    ctx.clip()

    let bristleColors = [
        CGColor(red: 1.00, green: 0.86, blue: 0.32, alpha: 1.0),
        CGColor(red: 0.96, green: 0.68, blue: 0.16, alpha: 1.0),
        CGColor(red: 0.82, green: 0.48, blue: 0.08, alpha: 1.0)
    ] as CFArray
    if let bristleGrad = CGGradient(colorsSpace: colorSpace, colors: bristleColors, locations: [0.0, 0.55, 1.0]) {
        ctx.drawLinearGradient(
            bristleGrad,
            start: CGPoint(x: 0, y: -15),
            end: CGPoint(x: 0, y: -310),
            options: []
        )
    }

    // Bristle texture lines
    ctx.setShadow(offset: .zero, blur: 0, color: nil)
    ctx.setLineWidth(3.5)
    ctx.setLineCap(.round)
    for i in -8...8 {
        let topX = CGFloat(i) * 5.2
        let botX = CGFloat(i) * 18.0
        let line = CGMutablePath()
        line.move(to: CGPoint(x: topX, y: -30))
        line.addQuadCurve(
            to: CGPoint(x: botX, y: -295),
            control: CGPoint(x: (topX + botX) * 0.52, y: -160)
        )
        ctx.addPath(line)
        if i % 2 == 0 {
            ctx.setStrokeColor(CGColor(red: 0.68, green: 0.36, blue: 0.04, alpha: 0.38))
        } else {
            ctx.setStrokeColor(CGColor(red: 1.00, green: 0.94, blue: 0.58, alpha: 0.42))
        }
        ctx.strokePath()
    }

    // Red/Orange stitched binding band across bristles
    let stitchPath = CGMutablePath()
    stitchPath.move(to: CGPoint(x: -92, y: -115))
    stitchPath.addQuadCurve(to: CGPoint(x: 96, y: -115), control: CGPoint(x: 0, y: -132))
    ctx.addPath(stitchPath)
    ctx.setLineWidth(14)
    ctx.setStrokeColor(CGColor(red: 0.86, green: 0.23, blue: 0.18, alpha: 0.92))
    ctx.strokePath()

    ctx.restoreGState()

    // --- C. Metallic Cap / Ferrule (connecting handle to bristles) ---
    let capPath = CGMutablePath()
    capPath.move(to: CGPoint(x: -36, y: 24))
    capPath.addLine(to: CGPoint(x: 36, y: 24))
    capPath.addLine(to: CGPoint(x: 56, y: -32))
    capPath.addQuadCurve(to: CGPoint(x: -56, y: -32), control: CGPoint(x: 0, y: -44))
    capPath.closeSubpath()

    ctx.saveGState()
    ctx.addPath(capPath)
    ctx.clip()
    let metalColors = [
        CGColor(red: 0.72, green: 0.78, blue: 0.86, alpha: 1.0),
        CGColor(red: 0.95, green: 0.97, blue: 1.00, alpha: 1.0),
        CGColor(red: 0.52, green: 0.58, blue: 0.68, alpha: 1.0)
    ] as CFArray
    if let metalGrad = CGGradient(colorsSpace: colorSpace, colors: metalColors, locations: [0.0, 0.45, 1.0]) {
        ctx.drawLinearGradient(
            metalGrad,
            start: CGPoint(x: -56, y: 0),
            end: CGPoint(x: 56, y: 0),
            options: []
        )
    }
    ctx.restoreGState()

    ctx.restoreGState() // End rotated broom

    // 3. Sparkling Clean Stars (4-point stars around the broom)
    func drawSparkle(cx: CGFloat, cy: CGFloat, radius: CGFloat, alpha: CGFloat) {
        ctx.saveGState()
        let star = CGMutablePath()
        let inner = radius * 0.24
        star.move(to: CGPoint(x: cx, y: cy + radius))
        star.addQuadCurve(to: CGPoint(x: cx + radius, y: cy), control: CGPoint(x: cx + inner, y: cy + inner))
        star.addQuadCurve(to: CGPoint(x: cx, y: cy - radius), control: CGPoint(x: cx + inner, y: cy - inner))
        star.addQuadCurve(to: CGPoint(x: cx - radius, y: cy), control: CGPoint(x: cx - inner, y: cy - inner))
        star.addQuadCurve(to: CGPoint(x: cx, y: cy + radius), control: CGPoint(x: cx - inner, y: cy + inner))
        star.closeSubpath()

        ctx.setShadow(
            offset: .zero,
            blur: 14,
            color: CGColor(red: 0.65, green: 0.95, blue: 1.0, alpha: 0.85)
        )
        ctx.addPath(star)
        ctx.setFillColor(CGColor(red: 1.0, green: 1.0, blue: 1.0, alpha: alpha))
        ctx.fillPath()
        ctx.restoreGState()
    }

    drawSparkle(cx: 265, cy: 640, radius: 46, alpha: 0.96)
    drawSparkle(cx: 745, cy: 420, radius: 38, alpha: 0.92)
    drawSparkle(cx: 650, cy: 250, radius: 28, alpha: 0.85)
    drawSparkle(cx: 330, cy: 760, radius: 22, alpha: 0.80)

    // 4. Inner Glass Rim Border on Squircle
    ctx.addPath(bgPath)
    ctx.setLineWidth(6.0)
    ctx.setStrokeColor(CGColor(red: 1.0, green: 1.0, blue: 1.0, alpha: 0.24))
    ctx.strokePath()

    ctx.restoreGState() // End squircle clip
    ctx.restoreGState() // End scale

    image.unlockFocus()
    return image
}

func savePNG(image: NSImage, to url: URL, pixelSize: Int) throws {
    guard let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: pixelSize,
        pixelsHigh: pixelSize,
        bitsPerSample: 8,
        samplesPerPixel: 4,
        hasAlpha: true,
        isPlanar: false,
        colorSpaceName: .deviceRGB,
        bytesPerRow: 0,
        bitsPerPixel: 0
    ) else {
        throw NSError(domain: "IconGen", code: 1)
    }

    rep.size = NSSize(width: pixelSize, height: pixelSize)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    image.draw(
        in: NSRect(x: 0, y: 0, width: pixelSize, height: pixelSize),
        from: .zero,
        operation: .copy,
        fraction: 1.0
    )
    NSGraphicsContext.restoreGraphicsState()

    guard let pngData = rep.representation(using: .png, properties: [:]) else {
        throw NSError(domain: "IconGen", code: 2)
    }
    try pngData.write(to: url)
}

let fm = FileManager.default
let iconsetURL = URL(fileURLWithPath: "AppIcon.iconset", isDirectory: true)
try? fm.removeItem(at: iconsetURL)
try fm.createDirectory(at: iconsetURL, withIntermediateDirectories: true)

let specs: [(String, Int)] = [
    ("icon_16x16.png", 16),
    ("icon_16x16@2x.png", 32),
    ("icon_32x32.png", 32),
    ("icon_32x32@2x.png", 64),
    ("icon_128x128.png", 128),
    ("icon_128x128@2x.png", 256),
    ("icon_256x256.png", 256),
    ("icon_256x256@2x.png", 512),
    ("icon_512x512.png", 512),
    ("icon_512x512@2x.png", 1024)
]

let masterImage = drawBroomIcon(size: 1024)
for (filename, px) in specs {
    let fileURL = iconsetURL.appendingPathComponent(filename)
    try savePNG(image: masterImage, to: fileURL, pixelSize: px)
}

print("✅ AppIcon.iconset gerado com sucesso.")
