import AppKit

let output = CommandLine.arguments[1]
let iconset = URL(fileURLWithPath: output).deletingLastPathComponent().appendingPathComponent("AppIcon.iconset")
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
for size in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let pixels = size * scale
        let image = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
                                     bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                     colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: image)
        let affine = NSAffineTransform(); affine.scale(by: CGFloat(pixels) / 1024); affine.concat()
        let base = NSBezierPath(roundedRect: NSRect(x: 66, y: 66, width: 892, height: 892), xRadius: 200, yRadius: 200)
        NSGradient(starting: NSColor(calibratedRed: 0.08, green: 0.54, blue: 0.96, alpha: 1), ending: NSColor(calibratedRed: 0.12, green: 0.27, blue: 0.76, alpha: 1))!.draw(in: base, angle: -75)
        NSColor.white.withAlphaComponent(0.96).setFill()
        NSBezierPath(roundedRect: NSRect(x: 252, y: 218, width: 520, height: 598), xRadius: 62, yRadius: 62).fill()
        let blue = NSColor(calibratedRed: 0.12, green: 0.39, blue: 0.83, alpha: 1)
        for y in [650, 510, 370] {
            blue.setStroke()
            let check = NSBezierPath(); check.move(to: NSPoint(x: 316, y: y)); check.line(to: NSPoint(x: 346, y: y - 30)); check.line(to: NSPoint(x: 397, y: y + 35))
            check.lineWidth = 26; check.lineCapStyle = .round; check.lineJoinStyle = .round; check.stroke()
            blue.withAlphaComponent(0.30).setFill()
            NSBezierPath(roundedRect: NSRect(x: 450, y: y - 12, width: 235, height: 25), xRadius: 12, yRadius: 12).fill()
        }
        NSGraphicsContext.restoreGraphicsState()
        let name = "icon_\(size)x\(size)\(scale == 2 ? "@2x" : "").png"
        try image.representation(using: .png, properties: [:])!.write(to: iconset.appendingPathComponent(name))
    }
}
func appendLength(_ value: Int, to data: inout Data) {
    var bigEndian = UInt32(value).bigEndian
    withUnsafeBytes(of: &bigEndian) { data.append(contentsOf: $0) }
}
var chunks = Data()
for (type, file) in [("ic07", "icon_128x128.png"), ("ic08", "icon_256x256.png"), ("ic09", "icon_512x512.png"), ("ic10", "icon_512x512@2x.png")] {
    let png = try Data(contentsOf: iconset.appendingPathComponent(file))
    chunks.append(Data(type.utf8)); appendLength(png.count + 8, to: &chunks); chunks.append(png)
}
var result = Data("icns".utf8); appendLength(chunks.count + 8, to: &result); result.append(chunks)
try result.write(to: URL(fileURLWithPath: output))
try FileManager.default.removeItem(at: iconset)
