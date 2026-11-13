// Renders the disk image window background: a light wallpaper, a hint, and an
// arrow from where the app icon sits to where the Applications alias sits.
//
//   swift scripts/DMGBackground.swift <output.png> <scale>
//
// Geometry must match scripts/make-dmg.sh: a 660 × 420 window, icons centred
// at (180, 210) and (480, 210) in Finder's top-left coordinates.

import AppKit

let width: CGFloat = 660, height: CGFloat = 420
let arguments = CommandLine.arguments
guard arguments.count == 3, let scale = Double(arguments[2]) else {
    FileHandle.standardError.write("usage: DMGBackground.swift <output.png> <scale>\n".data(using: .utf8)!)
    exit(1)
}
let s = CGFloat(scale)

func color(_ hex: UInt32, _ alpha: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
}

func gradient(_ stops: [(CGColor, CGFloat)]) -> CGGradient {
    CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB),
               colors: stops.map(\.0) as CFArray, locations: stops.map(\.1))!
}

let context = CGContext(
    data: nil, width: Int(width * s), height: Int(height * s), bitsPerComponent: 8, bytesPerRow: 0,
    space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
)!
context.scaleBy(x: s, y: s)

// Wallpaper: the light variant of the README banner's palette.
context.setFillColor(color(0xF5F8FE))
context.fill(CGRect(x: 0, y: 0, width: width, height: height))
func blob(_ x: CGFloat, _ y: CGFloat, _ r: CGFloat, _ hex: UInt32, _ a: CGFloat) {
    context.drawRadialGradient(
        gradient([(color(hex, a), 0), (color(hex, a * 0.4), 0.5), (color(hex, 0), 1)]),
        startCenter: CGPoint(x: x, y: y), startRadius: 0, endCenter: CGPoint(x: x, y: y), endRadius: r, options: []
    )
}
blob(60, 380, 320, 0x7CB3FF, 0.45)
blob(640, 40, 340, 0xB39DFF, 0.38)
blob(380, -40, 240, 0x7FE3F0, 0.30)

// Arrow between the two icons (y = 210 from the top).
let y = height - 210
context.setStrokeColor(color(0x3B5BDB, 0.55))
context.setLineWidth(5)
context.setLineCap(.round)
context.setLineJoin(.round)
context.setLineDash(phase: 0, lengths: [0.1, 12])
context.move(to: CGPoint(x: 268, y: y))
context.addLine(to: CGPoint(x: 378, y: y))
context.strokePath()
context.setLineDash(phase: 0, lengths: [])
context.move(to: CGPoint(x: 376, y: y + 14))
context.addLine(to: CGPoint(x: 392, y: y))
context.addLine(to: CGPoint(x: 376, y: y - 14))
context.strokePath()

// Hint.
NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
func centred(_ string: String, y: CGFloat, size: CGFloat, weight: NSFont.Weight, alpha: CGFloat) {
    let text = NSAttributedString(string: string, attributes: [
        .font: NSFont.systemFont(ofSize: size, weight: weight),
        .foregroundColor: NSColor(srgbRed: 0.07, green: 0.09, blue: 0.16, alpha: alpha),
    ])
    text.draw(at: CGPoint(x: (width - text.size().width) / 2, y: y))
}
centred("Install GlassFTP", y: height - 72, size: 22, weight: .bold, alpha: 0.9)
centred("Drag the app onto the Applications folder.", y: height - 98, size: 13, weight: .regular, alpha: 0.55)

let image = context.makeImage()!
let url = URL(fileURLWithPath: arguments[1])
let destination = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil)!
CGImageDestinationAddImage(destination, image, [kCGImagePropertyDPIWidth: 72 * s, kCGImagePropertyDPIHeight: 72 * s] as CFDictionary)
CGImageDestinationFinalize(destination)
