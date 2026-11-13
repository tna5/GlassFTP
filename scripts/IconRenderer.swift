// Renders the Liquid Glass app icon variants to 1024 px PNGs.
//
//   swift scripts/IconRenderer.swift <output-directory>
//
// Drawn with Core Graphics and Core Image only, so it runs with the Command
// Line Tools. Each glass element is built the same way the system's glass
// reads: the background seen through it (blurred and slightly magnified), a
// frosted tint, light pooling inside the top edge, a specular rim, and a soft
// shadow beneath.

import AppKit
import CoreImage

let size = 1024
let canvas = CGRect(x: 0, y: 0, width: size, height: size)
/// macOS icon grid: an 824 pt body centred on the 1024 canvas.
let body = CGRect(x: 100, y: 100, width: 824, height: 824)
let bodyRadius: CGFloat = 185

// MARK: - Helpers

func makeContext() -> CGContext {
    let context = CGContext(
        data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpace(name: CGColorSpace.displayP3)!,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    )!
    context.interpolationQuality = .high
    return context
}

func color(_ hex: UInt32, _ alpha: CGFloat = 1) -> CGColor {
    CGColor(
        srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
        green: CGFloat((hex >> 8) & 0xFF) / 255,
        blue: CGFloat(hex & 0xFF) / 255,
        alpha: alpha
    )
}

func white(_ alpha: CGFloat) -> CGColor { CGColor(gray: 1, alpha: alpha) }
func black(_ alpha: CGFloat) -> CGColor { CGColor(gray: 0, alpha: alpha) }

func gradient(_ stops: [(CGColor, CGFloat)]) -> CGGradient {
    CGGradient(
        colorsSpace: CGColorSpace(name: CGColorSpace.displayP3),
        colors: stops.map(\.0) as CFArray,
        locations: stops.map(\.1)
    )!
}

func roundedRect(_ rect: CGRect, _ radius: CGFloat) -> CGPath {
    CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil)
}

/// A polyline thickened into a solid shape with round caps and joins.
func stroke(_ points: [[CGPoint]], width: CGFloat) -> CGPath {
    var result: CGPath?
    for line in points {
        let path = CGMutablePath()
        path.addLines(between: line)
        let solid = path.copy(strokingWithWidth: width, lineCap: .round, lineJoin: .round, miterLimit: 10)
        result = result.map { $0.union(solid) } ?? solid
    }
    return result!
}

func blurred(_ image: CGImage, radius: Double, saturation: Double = 1.25, brightness: Double = 0.06) -> CGImage {
    let input = CIImage(cgImage: image).clampedToExtent()
    let blur = input.applyingGaussianBlur(sigma: radius)
    let adjusted = blur.applyingFilter("CIColorControls", parameters: [
        kCIInputSaturationKey: saturation,
        kCIInputBrightnessKey: brightness,
    ])
    let context = CIContext(options: [.workingColorSpace: CGColorSpace(name: CGColorSpace.displayP3)!])
    return context.createCGImage(adjusted, from: canvas)!
}

// MARK: - Glass

struct GlassStyle {
    var tint: CGColor = white(0.14)
    var magnification: CGFloat = 1.08
    var blur: Double = 22
    var rimWidth: CGFloat = 6
    var shadowAlpha: CGFloat = 0.32
}

/// Draws one glass element over whatever is already in `context`.
func drawGlass(_ path: CGPath, in context: CGContext, style: GlassStyle = GlassStyle()) {
    let backdrop = blurred(context.makeImage()!, radius: style.blur)
    let bounds = path.boundingBoxOfPath

    // Shadow underneath, cast by an opaque copy the glass then covers.
    context.saveGState()
    context.setShadow(offset: CGSize(width: 0, height: -22), blur: 44, color: black(style.shadowAlpha))
    context.addPath(path)
    context.setFillColor(black(0.35))
    context.fillPath()
    context.restoreGState()

    context.saveGState()
    context.addPath(path)
    context.clip()

    // The background through the glass: blurred and magnified about the
    // element's centre, which is what reads as refraction.
    let m = style.magnification
    let drawRect = CGRect(
        x: bounds.midX - (bounds.midX - canvas.minX) * m,
        y: bounds.midY - (bounds.midY - canvas.minY) * m,
        width: canvas.width * m,
        height: canvas.height * m
    )
    context.draw(backdrop, in: drawRect)

    // Frosted tint, brighter towards the top.
    context.setFillColor(style.tint)
    context.fill(bounds)
    context.drawLinearGradient(
        gradient([(white(0.22), 0), (white(0.0), 0.55), (white(0.06), 1)]),
        start: CGPoint(x: bounds.midX, y: bounds.maxY),
        end: CGPoint(x: bounds.midX, y: bounds.minY),
        options: []
    )

    // Light pooling inside the top edge, shade inside the bottom: inner
    // shadows cast by the area outside the shape.
    let outside = CGMutablePath()
    outside.addRect(bounds.insetBy(dx: -200, dy: -200))
    outside.addPath(path)
    context.setShadow(offset: CGSize(width: 0, height: -10), blur: 24, color: white(0.55))
    context.addPath(outside)
    context.setFillColor(white(1))
    context.fillPath(using: .evenOdd)
    context.setShadow(offset: CGSize(width: 0, height: 12), blur: 26, color: black(0.22))
    context.addPath(outside)
    context.setFillColor(black(1))
    context.fillPath(using: .evenOdd)

    // A soft specular bloom under the top edge — the liquid highlight.
    context.setShadow(offset: .zero, blur: 0, color: nil)
    context.saveGState()
    context.translateBy(x: bounds.midX, y: bounds.maxY - bounds.height * 0.08)
    context.scaleBy(x: 1, y: 0.45)
    context.drawRadialGradient(
        gradient([(white(0.38), 0), (white(0), 1)]),
        startCenter: .zero, startRadius: 0,
        endCenter: .zero, endRadius: bounds.width * 0.55,
        options: []
    )
    context.restoreGState()
    context.restoreGState()

    // Specular rim: bright where light hits (top-left), a second glint at the
    // bottom-right, faint in between.
    let rim = path.copy(strokingWithWidth: style.rimWidth, lineCap: .round, lineJoin: .round, miterLimit: 10)
    context.saveGState()
    context.addPath(rim)
    context.clip()
    context.drawLinearGradient(
        gradient([(white(1.0), 0), (white(0.55), 0.3), (white(0.15), 0.6), (white(0.75), 1)]),
        start: CGPoint(x: bounds.minX, y: bounds.maxY),
        end: CGPoint(x: bounds.maxX, y: bounds.minY),
        options: [.drawsBeforeStartLocation, .drawsAfterEndLocation]
    )
    context.restoreGState()
}

/// A solid white glyph on glass, with a hint of depth.
func drawInlay(_ path: CGPath, in context: CGContext, alpha: CGFloat = 0.96) {
    context.saveGState()
    context.setShadow(offset: CGSize(width: 0, height: -6), blur: 14, color: black(0.25))
    context.addPath(path)
    context.setFillColor(white(alpha))
    context.fillPath()
    context.restoreGState()
}

// MARK: - Background

func drawBody(in context: CGContext, base: [(CGColor, CGFloat)], blobs: [(CGPoint, CGFloat, CGColor)]) {
    let shape = roundedRect(body, bodyRadius)

    // The icon's own shadow on the desktop.
    context.saveGState()
    context.setShadow(offset: CGSize(width: 0, height: -12), blur: 28, color: black(0.35))
    context.addPath(shape)
    context.setFillColor(black(1))
    context.fillPath()
    context.restoreGState()

    context.saveGState()
    context.addPath(shape)
    context.clip()
    context.drawLinearGradient(
        gradient(base),
        start: CGPoint(x: body.midX, y: body.maxY),
        end: CGPoint(x: body.midX, y: body.minY),
        options: []
    )
    for (center, radius, tint) in blobs {
        context.drawRadialGradient(
            gradient([(tint, 0), (tint.copy(alpha: 0)!, 1)]),
            startCenter: center, startRadius: 0,
            endCenter: center, endRadius: radius,
            options: []
        )
    }
    // Sheen across the top half.
    context.drawLinearGradient(
        gradient([(white(0.18), 0), (white(0), 0.5)]),
        start: CGPoint(x: body.midX, y: body.maxY),
        end: CGPoint(x: body.midX, y: body.minY),
        options: []
    )
    context.restoreGState()

    // The body's own glass edge.
    let rim = shape.copy(strokingWithWidth: 6, lineCap: .round, lineJoin: .round, miterLimit: 10)
    context.saveGState()
    context.addPath(rim)
    context.clip()
    context.drawLinearGradient(
        gradient([(white(0.7), 0), (white(0.12), 0.45), (white(0.05), 0.7), (white(0.35), 1)]),
        start: CGPoint(x: body.minX, y: body.maxY),
        end: CGPoint(x: body.maxX, y: body.minY),
        options: []
    )
    context.restoreGState()
}

// MARK: - Variants

/// 1 — Transfer: two glass arrows, up and down, on ocean blue.
func variantTransfer() -> CGImage {
    let context = makeContext()
    drawBody(in: context, base: [(color(0x3A9BFF), 0), (color(0x1450D0), 0.6), (color(0x0B2A80), 1)], blobs: [
        (CGPoint(x: 300, y: 760), 420, color(0x7FE3FF, 0.55)),
        (CGPoint(x: 760, y: 260), 380, color(0x6A4CFF, 0.45)),
    ])

    let down = stroke([
        [CGPoint(x: 390, y: 735), CGPoint(x: 390, y: 330)],
        [CGPoint(x: 268, y: 450), CGPoint(x: 390, y: 320), CGPoint(x: 512, y: 450)],
    ], width: 104)
    let up = stroke([
        [CGPoint(x: 634, y: 289), CGPoint(x: 634, y: 694)],
        [CGPoint(x: 512, y: 574), CGPoint(x: 634, y: 704), CGPoint(x: 756, y: 574)],
    ], width: 104)

    let style = GlassStyle(tint: white(0.26), magnification: 1.12, blur: 18, rimWidth: 7, shadowAlpha: 0.4)
    drawGlass(down, in: context, style: style)
    drawGlass(up, in: context, style: style)
    return context.makeImage()!
}

/// One arrow as a solid glass shape, centred on (`x`, `y`).
func arrow(x: CGFloat, y: CGFloat, length: CGFloat, width: CGFloat, head: CGFloat, up: Bool) -> CGPath {
    let top = y + length / 2, bottom = y - length / 2
    if up {
        return stroke([
            [CGPoint(x: x, y: bottom), CGPoint(x: x, y: top - 8)],
            [CGPoint(x: x - head, y: top - head), CGPoint(x: x, y: top), CGPoint(x: x + head, y: top - head)],
        ], width: width)
    }
    return stroke([
        [CGPoint(x: x, y: top), CGPoint(x: x, y: bottom + 8)],
        [CGPoint(x: x - head, y: bottom + head), CGPoint(x: x, y: bottom), CGPoint(x: x + head, y: bottom + head)],
    ], width: width)
}

struct ArrowPair {
    /// Distance between the two shafts.
    var gap: CGFloat
    var down: (length: CGFloat, width: CGFloat, head: CGFloat)
    var up: (length: CGFloat, width: CGFloat, head: CGFloat)
    /// The down arrow sits this much higher than the up arrow.
    var stagger: CGFloat
    var tint: CGFloat = 0.26
    /// Both arrows as one glass piece: a single outline, one rim, one shadow.
    var merged = false
}

/// Variant 1's background and glass, with the arrows laid out by `pair`.
func variantTransfer(_ pair: ArrowPair) -> CGImage {
    let context = makeContext()
    drawBody(in: context, base: [(color(0x3A9BFF), 0), (color(0x1450D0), 0.6), (color(0x0B2A80), 1)], blobs: [
        (CGPoint(x: 300, y: 760), 420, color(0x7FE3FF, 0.55)),
        (CGPoint(x: 760, y: 260), 380, color(0x6A4CFF, 0.45)),
    ])
    let center: CGFloat = 512
    let down = arrow(x: center - pair.gap / 2, y: center + pair.stagger / 2,
                     length: pair.down.length, width: pair.down.width, head: pair.down.head, up: false)
    let up = arrow(x: center + pair.gap / 2, y: center - pair.stagger / 2,
                   length: pair.up.length, width: pair.up.width, head: pair.up.head, up: true)
    let style = GlassStyle(tint: white(pair.tint), magnification: 1.12, blur: 18, rimWidth: 7, shadowAlpha: 0.4)
    if pair.merged {
        drawGlass(down.union(up), in: context, style: style)
    } else {
        drawGlass(down, in: context, style: style)
        drawGlass(up, in: context, style: style)
    }
    return context.makeImage()!
}

/// The five studies on variant 1: spacing and arrow proportions.
let transferStudies: [(String, ArrowPair)] = [
    // Close together: the heads overlap, glass over glass.
    ("1a-tight", ArrowPair(gap: 150, down: (420, 100, 108), up: (420, 100, 108), stagger: 60)),
    // Wide apart and level, symmetrical and calm.
    ("1b-airy", ArrowPair(gap: 300, down: (380, 84, 100), up: (380, 84, 100), stagger: 0)),
    // Short and chunky, reads well at 16 px.
    ("1c-bold", ArrowPair(gap: 250, down: (320, 132, 118), up: (320, 132, 118), stagger: 70)),
    // Tall and slender.
    ("1d-slim", ArrowPair(gap: 210, down: (500, 62, 92), up: (500, 62, 92), stagger: 80)),
    // Download dominant: a large down arrow, a smaller up arrow.
    ("1e-download", ArrowPair(gap: 250, down: (470, 120, 125), up: (300, 78, 84), stagger: -40)),
    // 1c with the two arrows fused into a single glass shape.
    ("1f-bold-merged", ArrowPair(gap: 250, down: (320, 132, 118), up: (320, 132, 118), stagger: 70, merged: true)),
]

/// 2 — Folder: a glass folder over violet-to-cyan, with a solid transfer
/// glyph set into it.
func variantFolder() -> CGImage {
    let context = makeContext()
    drawBody(in: context, base: [(color(0x8B5CFF), 0), (color(0x4A49E8), 0.5), (color(0x10B5D9), 1)], blobs: [
        (CGPoint(x: 780, y: 800), 420, color(0xFF7AD9, 0.5)),
        (CGPoint(x: 240, y: 220), 420, color(0x3CF2D0, 0.45)),
    ])

    // Back panel with its tab, then the front panel.
    let back = CGMutablePath()
    back.addPath(roundedRect(CGRect(x: 232, y: 280, width: 560, height: 420), 58))
    back.addPath(roundedRect(CGRect(x: 232, y: 560, width: 230, height: 190), 44))
    let backShape = roundedRect(CGRect(x: 232, y: 280, width: 560, height: 420), 58)
        .union(roundedRect(CGRect(x: 232, y: 560, width: 230, height: 190), 44))
    drawGlass(backShape, in: context, style: GlassStyle(tint: white(0.10), magnification: 1.05))

    let front = roundedRect(CGRect(x: 214, y: 250, width: 596, height: 390), 62)
    drawGlass(front, in: context, style: GlassStyle(tint: white(0.16), magnification: 1.1))

    let arrows = stroke([
        [CGPoint(x: 452, y: 330), CGPoint(x: 452, y: 548)],
        [CGPoint(x: 398, y: 494), CGPoint(x: 452, y: 552), CGPoint(x: 506, y: 494)],
        [CGPoint(x: 572, y: 560), CGPoint(x: 572, y: 342)],
        [CGPoint(x: 518, y: 396), CGPoint(x: 572, y: 338), CGPoint(x: 626, y: 396)],
    ], width: 40)
    drawInlay(arrows, in: context)
    return context.makeImage()!
}

/// 3 — Orb: a glass lens over a dark aurora, ⇅ set inside it.
func variantOrb() -> CGImage {
    let context = makeContext()
    drawBody(in: context, base: [(color(0x1B2236), 0), (color(0x0B0F1C), 1)], blobs: [
        (CGPoint(x: 330, y: 700), 360, color(0x2D8CFF, 0.95)),
        (CGPoint(x: 700, y: 640), 330, color(0xB04CFF, 0.85)),
        (CGPoint(x: 560, y: 300), 360, color(0x00E0B8, 0.75)),
    ])

    let lens = CGPath(ellipseIn: CGRect(x: 232, y: 232, width: 560, height: 560), transform: nil)
    drawGlass(lens, in: context, style: GlassStyle(tint: white(0.12), magnification: 1.18, blur: 16, rimWidth: 6, shadowAlpha: 0.45))

    let arrows = stroke([
        [CGPoint(x: 445, y: 380), CGPoint(x: 445, y: 650)],
        [CGPoint(x: 377, y: 582), CGPoint(x: 445, y: 654), CGPoint(x: 513, y: 582)],
        [CGPoint(x: 579, y: 644), CGPoint(x: 579, y: 374)],
        [CGPoint(x: 511, y: 442), CGPoint(x: 579, y: 370), CGPoint(x: 647, y: 442)],
    ], width: 50)
    drawInlay(arrows, in: context)
    return context.makeImage()!
}

// MARK: - Output

func write(_ image: CGImage, to url: URL) {
    let rep = NSBitmapImageRep(cgImage: image)
    try! rep.representation(using: .png, properties: [:])!.write(to: url)
    print("wrote \(url.path)")
}

let output = URL(fileURLWithPath: CommandLine.arguments.dropFirst().first ?? ".", isDirectory: true)
try? FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
write(variantTransfer(), to: output.appendingPathComponent("icon-1-transfer.png"))
for (name, pair) in transferStudies {
    write(variantTransfer(pair), to: output.appendingPathComponent("icon-\(name).png"))
}
write(variantFolder(), to: output.appendingPathComponent("icon-2-folder.png"))
write(variantOrb(), to: output.appendingPathComponent("icon-3-orb.png"))
