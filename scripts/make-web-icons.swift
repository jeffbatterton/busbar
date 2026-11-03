// Renders the web app's icons and launch images from web/icon.svg and web/logo.svg.
// Usage: swift scripts/make-web-icons.swift
import AppKit

let root = URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent().deletingLastPathComponent()
let web = root.appending(path: "web")
func load(_ name: String) -> NSImage {
    guard let image = NSImage(contentsOf: web.appending(path: name)) else { fatalError("Couldn't load \(name)") }
    return image
}
let icon = load("icon.svg"), logo = load("logo.svg")

func write(_ name: String, width: Int, height: Int, draw: (NSRect) -> Void) throws {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height,
                               bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    NSGraphicsContext.current?.imageInterpolation = .high
    draw(NSRect(x: 0, y: 0, width: width, height: height))
    NSGraphicsContext.restoreGraphicsState()
    let url = web.appending(path: name)
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try rep.representation(using: .png, properties: [:])!.write(to: url)
}

// Home Screen icon, and the web app manifest's.
for (name, size) in [("apple-touch-icon.png", 180), ("icon-192.png", 192), ("icon-512.png", 512)] {
    try write(name, width: size, height: size) { icon.draw(in: $0) }
}

// The launch screen's logo: 132pt, at 3x.
try write("logo.png", width: 396, height: 396) { logo.draw(in: $0) }

// Launch images: the logo centered on the app's black, one per iPhone screen size.
// Keep in step with the apple-touch-startup-image links in web/index.html.
let launchSizes = [(1320, 2868, 3), (1290, 2796, 3), (1284, 2778, 3), (1260, 2736, 3), (1206, 2622, 3),
                   (1179, 2556, 3), (1170, 2532, 3), (1125, 2436, 3), (828, 1792, 2), (750, 1334, 2)]
for (width, height, scale) in launchSizes {
    try write("launch/\(width)x\(height).png", width: width, height: height) { rect in
        NSColor(red: 0x0d / 255, green: 0x0d / 255, blue: 0x0f / 255, alpha: 1).setFill()
        rect.fill()
        let side = CGFloat(132 * scale)
        logo.draw(in: NSRect(x: (rect.width - side) / 2, y: (rect.height - side) / 2, width: side, height: side))
    }
}
print("Wrote web app icons and \(launchSizes.count) launch images to \(web.path)")
