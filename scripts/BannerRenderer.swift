// Renders the README banner variants to PNG.
//
//   swift scripts/BannerRenderer.swift <app-icon-1024.png> <output-directory>
//
// Same approach as IconRenderer.swift: Core Graphics, Core Image and AppKit
// text only, so it runs with the Command Line Tools. Glass panels are drawn as
// the background blurred behind them, a frosted tint, light pooling under the
// top edge and a specular rim.

import AppKit
import CoreImage

let width: CGFloat = 1280
/// 400 for the README banner; the social preview reuses the window layout at
/// 640, shifted up by `layoutOffset` so it sits in the middle.
var height: CGFloat = 400
var layoutOffset: CGFloat = 0
let scale: CGFloat = 2
var canvas: CGRect { CGRect(x: 0, y: 0, width: width, height: height) }

// MARK: - Helpers

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

func makeContext() -> CGContext {
    let context = CGContext(
        data: nil, width: Int(width * scale), height: Int(height * scale),
        bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpace(name: CGColorSpace.displayP3)!,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    )!
    context.scaleBy(x: scale, y: scale)
    context.interpolationQuality = .high
    return context
}

/// A soft coloured light, the way a wallpaper's blobs read.
func blob(_ context: CGContext, center: CGPoint, radius: CGFloat, _ hex: UInt32, _ alpha: CGFloat) {
    context.drawRadialGradient(
        gradient([(color(hex, alpha), 0), (color(hex, alpha * 0.45), 0.45), (color(hex, 0), 1)]),
        startCenter: center, startRadius: 0, endCenter: center, endRadius: radius,
        options: []
    )
}

let ciContext = CIContext(options: [.workingColorSpace: CGColorSpace(name: CGColorSpace.displayP3)!])

func blurred(_ image: CGImage, radius: CGFloat) -> CGImage {
    let input = CIImage(cgImage: image).clampedToExtent()
    let output = input.applyingGaussianBlur(sigma: radius * scale)
        .cropped(to: CGRect(x: 0, y: 0, width: image.width, height: image.height))
    return ciContext.createCGImage(output, from: output.extent)!
}

/// A Liquid Glass panel over whatever `backdrop` holds.
func glass(
    _ context: CGContext, _ rect: CGRect, radius: CGFloat, backdrop: CGImage,
    tint: CGColor = white(0.10), rim: CGFloat = 0.55, shadow: CGFloat = 0.28
) {
    let shape = roundedRect(rect, radius)

    // Shadow beneath.
    context.saveGState()
    context.setShadow(offset: CGSize(width: 0, height: -10), blur: 30, color: black(shadow))
    context.addPath(shape)
    context.setFillColor(black(0.25))
    context.fillPath()
    context.restoreGState()

    // The backdrop seen through it, blurred.
    context.saveGState()
    context.addPath(shape)
    context.clip()
    // Snapshots are of the whole bitmap, so undo the layout shift.
    context.draw(backdrop, in: canvas.offsetBy(dx: 0, dy: -layoutOffset))
    context.setFillColor(tint)
    context.fill(rect)
    // Light pooling inside the top edge.
    context.drawLinearGradient(
        gradient([(white(0.22), 0), (white(0.04), 0.35), (white(0), 1)]),
        start: CGPoint(x: rect.midX, y: rect.maxY),
        end: CGPoint(x: rect.midX, y: rect.minY),
        options: []
    )
    context.restoreGState()

    // Specular rim: bright along the top, fading down the sides.
    context.saveGState()
    context.addPath(shape)
    context.setLineWidth(1.2)
    context.replacePathWithStrokedPath()
    context.clip()
    context.drawLinearGradient(
        gradient([(white(rim), 0), (white(rim * 0.25), 0.5), (white(rim * 0.5), 1)]),
        start: CGPoint(x: rect.minX, y: rect.maxY),
        end: CGPoint(x: rect.maxX, y: rect.minY),
        options: []
    )
    context.restoreGState()
}

func snapshot(_ context: CGContext) -> CGImage { context.makeImage()! }

/// Draws text with its baseline-left corner at `origin`; returns its width.
@discardableResult
func text(
    _ context: CGContext, _ string: String, at origin: CGPoint, size: CGFloat,
    weight: NSFont.Weight, color: NSColor, kern: CGFloat = 0, centered: Bool = false
) -> CGFloat {
    let font = NSFont.systemFont(ofSize: size, weight: weight)
    let attributed = NSAttributedString(string: string, attributes: [
        .font: font, .foregroundColor: color, .kern: kern,
    ])
    let measured = attributed.size().width
    let previous = NSGraphicsContext.current
    NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
    let x = centered ? origin.x - measured / 2 : origin.x
    attributed.draw(at: CGPoint(x: x, y: origin.y + font.descender))
    NSGraphicsContext.current = previous
    return measured
}

func textWidth(_ string: String, size: CGFloat, weight: NSFont.Weight) -> CGFloat {
    NSAttributedString(string: string, attributes: [
        .font: NSFont.systemFont(ofSize: size, weight: weight),
    ]).size().width
}

func drawIcon(_ context: CGContext, _ icon: CGImage, center: CGPoint, size: CGFloat, shadow: CGFloat = 0.35) {
    context.saveGState()
    context.setShadow(offset: CGSize(width: 0, height: -size * 0.05), blur: size * 0.12, color: black(shadow))
    context.draw(icon, in: CGRect(x: center.x - size / 2, y: center.y - size / 2, width: size, height: size))
    context.restoreGState()
}

/// Small glass capsules carrying a word each.
func chips(
    _ context: CGContext, _ labels: [String], origin: CGPoint, backdrop: CGImage,
    textColor: NSColor, tint: CGColor, centered: Bool = false
) {
    let size: CGFloat = 15, padding: CGFloat = 16, gap: CGFloat = 10, chipHeight: CGFloat = 34
    let widths = labels.map { textWidth($0, size: size, weight: .semibold) + padding * 2 }
    let total = widths.reduce(0, +) + gap * CGFloat(labels.count - 1)
    var x = centered ? origin.x - total / 2 : origin.x
    for (label, chipWidth) in zip(labels, widths) {
        let rect = CGRect(x: x, y: origin.y, width: chipWidth, height: chipHeight)
        glass(context, rect, radius: chipHeight / 2, backdrop: backdrop, tint: tint, rim: 0.6, shadow: 0.12)
        text(context, label, at: CGPoint(x: rect.minX + padding, y: rect.minY + 11.5),
             size: size, weight: .semibold, color: textColor)
        x += chipWidth + gap
    }
}

func save(_ context: CGContext, _ directory: URL, _ name: String) {
    let image = context.makeImage()!
    let url = directory.appendingPathComponent("banner-\(name).png")
    let destination = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil)!
    CGImageDestinationAddImage(destination, image, nil)
    CGImageDestinationFinalize(destination)
}

let tagline = "A native SFTP client for macOS, shaped like the Finder."
let features = ["SFTP", "Liquid Glass", "Column view", "macOS 26"]

// MARK: - 1. Midnight — dark wallpaper, icon left, title and chips

func midnight(icon: CGImage) -> CGContext {
    let context = makeContext()
    context.drawLinearGradient(
        gradient([(color(0x070B1F), 0), (color(0x10195A), 0.55), (color(0x1A1046), 1)]),
        start: CGPoint(x: 0, y: height), end: CGPoint(x: width, y: 0), options: []
    )
    blob(context, center: CGPoint(x: 230, y: 120), radius: 420, 0x2F6BFF, 0.55)
    blob(context, center: CGPoint(x: 1080, y: 380), radius: 460, 0x8B5CF6, 0.40)
    blob(context, center: CGPoint(x: 820, y: -40), radius: 360, 0x22D3EE, 0.30)
    let backdrop = blurred(snapshot(context), radius: 18)

    drawIcon(context, icon, center: CGPoint(x: 250, y: 200), size: 300, shadow: 0.5)

    let left: CGFloat = 430
    text(context, "GlassFTP", at: CGPoint(x: left - 4, y: 216), size: 92, weight: .bold, color: .white, kern: -2)
    text(context, tagline, at: CGPoint(x: left, y: 164), size: 25, weight: .regular,
         color: NSColor.white.withAlphaComponent(0.72))
    chips(context, features, origin: CGPoint(x: left, y: 98), backdrop: backdrop,
          textColor: NSColor.white.withAlphaComponent(0.92), tint: white(0.10))
    return context
}

// MARK: - 2. Daylight — light wallpaper, everything centred

func daylight(icon: CGImage) -> CGContext {
    let context = makeContext()
    context.setFillColor(color(0xF4F7FD))
    context.fill(canvas)
    blob(context, center: CGPoint(x: 140, y: 360), radius: 460, 0x7CB3FF, 0.55)
    blob(context, center: CGPoint(x: 1160, y: 60), radius: 480, 0xB39DFF, 0.45)
    blob(context, center: CGPoint(x: 640, y: -60), radius: 380, 0x7FE3F0, 0.35)
    blob(context, center: CGPoint(x: 1180, y: 420), radius: 300, 0xFFC4E1, 0.35)
    let backdrop = blurred(snapshot(context), radius: 18)

    // One wide glass shelf behind the lockup.
    glass(context, CGRect(x: 250, y: 46, width: 780, height: 308), radius: 44,
          backdrop: backdrop, tint: white(0.38), rim: 0.95, shadow: 0.10)

    drawIcon(context, icon, center: CGPoint(x: 640, y: 282), size: 124, shadow: 0.22)
    let ink = NSColor(srgbRed: 0.07, green: 0.09, blue: 0.16, alpha: 1)
    text(context, "GlassFTP", at: CGPoint(x: 640, y: 166), size: 58, weight: .bold, color: ink, kern: -1.2, centered: true)
    text(context, tagline, at: CGPoint(x: 640, y: 126), size: 20, weight: .regular,
         color: ink.withAlphaComponent(0.6), centered: true)
    let chipBackdrop = blurred(snapshot(context), radius: 10)
    chips(context, features, origin: CGPoint(x: 640, y: 70), backdrop: chipBackdrop,
          textColor: ink.withAlphaComponent(0.78), tint: white(0.45), centered: true)
    return context
}

// MARK: - 3. Window — title left, a glass Finder-style window on the right

func window(icon: CGImage) -> CGContext {
    let context = makeContext()
    let dy = layoutOffset
    context.translateBy(x: 0, y: dy)
    context.drawLinearGradient(
        gradient([(color(0x0D2A6B), 0), (color(0x1747B8), 0.5), (color(0x3A2C9E), 1)]),
        start: CGPoint(x: 0, y: -dy), end: CGPoint(x: width, y: height - dy),
        options: [.drawsBeforeStartLocation, .drawsAfterEndLocation]
    )
    blob(context, center: CGPoint(x: 980, y: 230), radius: 420, 0x5EA8FF, 0.55)
    blob(context, center: CGPoint(x: 120, y: 420), radius: 380, 0x7C5CFF, 0.35)
    blob(context, center: CGPoint(x: 1240, y: -20), radius: 300, 0x2EE6D6, 0.35)
    let backdrop = blurred(snapshot(context), radius: 22)

    // The window, running off the right and bottom edges.
    let frame = CGRect(x: 640, y: -40 - dy, width: 700, height: 390 + dy)
    glass(context, frame, radius: 26, backdrop: backdrop, tint: white(0.12), rim: 0.7, shadow: 0.35)
    let inner = blurred(snapshot(context), radius: 6)

    // Traffic lights.
    for (index, hex) in [UInt32(0xFF5F57), 0xFEBC2E, 0x28C840].enumerated() {
        context.setFillColor(color(hex))
        context.fillEllipse(in: CGRect(x: frame.minX + 22 + CGFloat(index) * 20, y: frame.maxY - 30, width: 12, height: 12))
    }

    // Sidebar: a glass slab of its own, as in macOS 26.
    let sidebar = CGRect(x: frame.minX + 10, y: frame.minY + 10, width: 170, height: frame.height - 52)
    glass(context, sidebar, radius: 18, backdrop: inner, tint: white(0.10), rim: 0.5, shadow: 0.15)
    let sideRows: [(CGFloat, Bool)] = [(80, true), (110, false), (64, false), (96, false)]
    for (index, (rowWidth, selected)) in sideRows.enumerated() {
        let y = sidebar.maxY - 40 - CGFloat(index) * 30
        if selected {
            context.setFillColor(white(0.16))
            context.addPath(roundedRect(CGRect(x: sidebar.minX + 8, y: y - 7, width: sidebar.width - 16, height: 26), 9))
            context.fillPath()
        }
        context.setFillColor(color(0x9CC8FF))
        context.addPath(roundedRect(CGRect(x: sidebar.minX + 18, y: y, width: 14, height: 12), 3))
        context.fillPath()
        context.setFillColor(white(selected ? 0.85 : 0.5))
        context.addPath(roundedRect(CGRect(x: sidebar.minX + 40, y: y + 2, width: rowWidth, height: 8), 4))
        context.fillPath()
    }

    // Three columns of rows, a blue selection walking down the trail.
    let columnWidth: CGFloat = 170
    let selections = [1, 3, 2]
    for column in 0..<3 {
        let x = sidebar.maxX + 14 + CGFloat(column) * (columnWidth + 1)
        if column > 0 {
            context.setFillColor(white(0.12))
            context.fill(CGRect(x: x - 1, y: frame.minY, width: 1, height: frame.height - 40))
        }
        for row in 0..<9 {
            let y = frame.maxY - 66 - CGFloat(row) * 28
            let isSelected = row == selections[column]
            if isSelected {
                context.setFillColor(column == 2 ? color(0x0A84FF) : white(0.18))
                context.addPath(roundedRect(CGRect(x: x + 6, y: y - 8, width: columnWidth - 12, height: 26), 8))
                context.fillPath()
            }
            let isFolder = (row + column) % 3 != 2
            context.setFillColor(isFolder ? color(0x7DB8FF) : white(0.75))
            context.addPath(roundedRect(CGRect(x: x + 16, y: y - 1, width: 14, height: 12), 3))
            context.fillPath()
            context.setFillColor(white(isSelected ? 0.95 : 0.55))
            let rowWidth = CGFloat(44 + (row * 37 + column * 23) % 56)
            context.addPath(roundedRect(CGRect(x: x + 38, y: y + 1, width: rowWidth, height: 8), 4))
            context.fillPath()
            if isFolder {
                context.setStrokeColor(white(isSelected ? 0.9 : 0.4))
                context.setLineWidth(1.6)
                context.setLineCap(.round)
                context.move(to: CGPoint(x: x + columnWidth - 22, y: y + 9))
                context.addLine(to: CGPoint(x: x + columnWidth - 18, y: y + 5))
                context.addLine(to: CGPoint(x: x + columnWidth - 22, y: y + 1))
                context.strokePath()
            }
        }
    }

    // Lockup on the left.
    drawIcon(context, icon, center: CGPoint(x: 140, y: 270), size: 150, shadow: 0.45)
    let left: CGFloat = 74
    text(context, "GlassFTP", at: CGPoint(x: left - 3, y: 132), size: 70, weight: .bold, color: .white, kern: -1.5)
    text(context, "A native SFTP client for macOS,", at: CGPoint(x: left, y: 94), size: 22, weight: .regular,
         color: NSColor.white.withAlphaComponent(0.75))
    text(context, "shaped like the Finder.", at: CGPoint(x: left, y: 66), size: 22, weight: .regular,
         color: NSColor.white.withAlphaComponent(0.75))
    return context
}

// MARK: - Main

let arguments = CommandLine.arguments
guard arguments.count == 3,
      let iconImage = NSImage(contentsOfFile: arguments[1]),
      let icon = iconImage.cgImage(forProposedRect: nil, context: nil, hints: nil)
else {
    FileHandle.standardError.write("usage: BannerRenderer.swift <icon.png> <output-directory>\n".data(using: .utf8)!)
    exit(1)
}
let output = URL(fileURLWithPath: arguments[2])
try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)

save(midnight(icon: icon), output, "1-midnight")
save(daylight(icon: icon), output, "2-daylight")
save(window(icon: icon), output, "3-window")

// GitHub's social preview size.
height = 640
layoutOffset = 120
save(window(icon: icon), output, "social-preview")
print("rendered 4 images into \(output.path)")
