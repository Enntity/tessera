// Renders the Tessera mark into the macOS .icns and the iOS app icon. Run: swift scripts/make-icons.swift
import AppKit

func render(size: CGFloat, rounded: Bool) -> NSBitmapImageRep {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size), pixelsHigh: Int(size), bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let ctx = NSGraphicsContext.current!.cgContext
    let inset = rounded ? size * 0.1 : 0
    let plate = CGRect(x: inset, y: inset, width: size - 2 * inset, height: size - 2 * inset)
    let path = CGPath(roundedRect: plate, cornerWidth: rounded ? plate.width * 0.225 : 0, cornerHeight: rounded ? plate.width * 0.225 : 0, transform: nil)
    ctx.addPath(path)
    ctx.clip()
    let bg = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                        colors: [CGColor(red: 0.07, green: 0.09, blue: 0.14, alpha: 1), CGColor(red: 0.02, green: 0.027, blue: 0.045, alpha: 1)] as CFArray,
                        locations: [0, 1])!
    ctx.drawLinearGradient(bg, start: CGPoint(x: 0, y: size), end: CGPoint(x: 0, y: 0), options: [])
    let glow = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                          colors: [CGColor(red: 0.30, green: 0.93, blue: 0.86, alpha: 0.28), CGColor(red: 0.30, green: 0.93, blue: 0.86, alpha: 0)] as CFArray,
                          locations: [0, 1])!
    ctx.drawRadialGradient(glow, startCenter: CGPoint(x: size / 2, y: size / 2), startRadius: 0,
                           endCenter: CGPoint(x: size / 2, y: size / 2), endRadius: plate.width * 0.6, options: [])
    let mark = plate.width * 0.5
    let gap = mark * 0.08
    let tile = (mark - gap) / 2
    let x0 = size / 2 - mark / 2, y0 = size / 2 - mark / 2
    let cyan = CGColor(red: 0.30, green: 0.93, blue: 0.86, alpha: 1)
    let tiles: [(CGFloat, CGFloat, CGColor)] = [
        (0, 1, cyan), (1, 1, cyan.copy(alpha: 0.55)!), (0, 0, cyan.copy(alpha: 0.35)!),
        (1, 0, CGColor(red: 1.0, green: 0.74, blue: 0.24, alpha: 1))
    ]
    for (cx, cy, color) in tiles {
        let r = CGRect(x: x0 + cx * (tile + gap), y: y0 + cy * (tile + gap), width: tile, height: tile)
        ctx.setFillColor(color)
        ctx.addPath(CGPath(roundedRect: r, cornerWidth: tile * 0.22, cornerHeight: tile * 0.22, transform: nil))
        ctx.fillPath()
    }
    NSGraphicsContext.restoreGraphicsState()
    return rep
}

let root = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : FileManager.default.currentDirectoryPath)
let iconset = root.appendingPathComponent(".build/AppIcon.iconset")
try? FileManager.default.removeItem(at: iconset)
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
for base in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let name = scale == 1 ? "icon_\(base)x\(base).png" : "icon_\(base)x\(base)@2x.png"
        try render(size: CGFloat(base * scale), rounded: true).representation(using: .png, properties: [:])!.write(to: iconset.appendingPathComponent(name))
    }
}
let appiconset = root.appendingPathComponent("Apps/TesseraIOS/Sources/Assets.xcassets/AppIcon.appiconset")
try FileManager.default.createDirectory(at: appiconset, withIntermediateDirectories: true)
try render(size: 1024, rounded: false).representation(using: .png, properties: [:])!.write(to: appiconset.appendingPathComponent("icon-1024.png"))
try #"{"images":[{"filename":"icon-1024.png","idiom":"universal","platform":"ios","size":"1024x1024"}],"info":{"author":"xcode","version":1}}"#
    .write(to: appiconset.appendingPathComponent("Contents.json"), atomically: true, encoding: .utf8)
try #"{"info":{"author":"xcode","version":1}}"#
    .write(to: appiconset.deletingLastPathComponent().appendingPathComponent("Contents.json"), atomically: true, encoding: .utf8)
print(iconset.path)
