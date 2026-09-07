import AppKit

// Reproducible, vector-drawn icon. Run from the repository root.
let directory = URL(fileURLWithPath: "build/Fader.iconset")
try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
for size in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let pixels = size * scale
        let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
                                      bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                      isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
        let transform = NSAffineTransform()
        transform.scale(by: CGFloat(pixels) / 1024)
        transform.concat()
        NSColor(calibratedRed: 0.12, green: 0.22, blue: 0.21, alpha: 1).setFill()
        NSBezierPath(roundedRect: NSRect(x: 60, y: 60, width: 904, height: 904), xRadius: 204, yRadius: 204).fill()
        for (x, y) in [(310.0, 410.0), (512.0, 630.0), (714.0, 485.0)] {
            NSColor(calibratedRed: 0.3, green: 0.48, blue: 0.44, alpha: 1).setFill()
            NSBezierPath(roundedRect: NSRect(x: x - 14, y: 245, width: 28, height: 535), xRadius: 14, yRadius: 14).fill()
            NSColor(calibratedRed: 0.62, green: 0.9, blue: 0.77, alpha: 1).setFill()
            NSBezierPath(roundedRect: NSRect(x: x - 62, y: y - 36, width: 124, height: 72), xRadius: 22, yRadius: 22).fill()
        }
        NSGraphicsContext.restoreGraphicsState()
        let name = "icon_\(size)x\(size)\(scale == 2 ? "@2x" : "").png"
        try bitmap.representation(using: .png, properties: [:])!.write(to: directory.appendingPathComponent(name))
    }
}
