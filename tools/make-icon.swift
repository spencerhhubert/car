// Render the app icon: the owl on a dark field, one PNG per macOS icon size.
//
//     swift tools/make-icon.swift        (from the repo root)
//
// Writes owl/Assets.xcassets in place; the output is committed, and build.sh
// runs this only when the catalog is missing.
import AppKit

let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let set = root.appendingPathComponent("owl/Assets.xcassets/AppIcon.appiconset")
try FileManager.default.createDirectory(at: set, withIntermediateDirectories: true)

func render(_ px: Int) -> Data {
    let n = CGFloat(px)
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px,
                               bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                               isPlanar: false, colorSpaceName: .deviceRGB,
                               bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let inset = n * 100 / 1024
    let box = NSRect(x: inset, y: inset, width: n - 2 * inset, height: n - 2 * inset)
    NSColor(calibratedRed: 0.09, green: 0.10, blue: 0.13, alpha: 1).setFill()
    NSBezierPath(roundedRect: box, xRadius: box.width * 0.225, yRadius: box.width * 0.225).fill()
    let text = NSAttributedString(string: "🦉", attributes: [.font: NSFont.systemFont(ofSize: n * 0.58)])
    let size = text.size()
    text.draw(at: NSPoint(x: (n - size.width) / 2, y: (n - size.height) / 2 + n * 0.01))
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

var images: [[String: String]] = []
for (pt, scale) in [(16, 1), (16, 2), (32, 1), (32, 2), (128, 1), (128, 2),
                    (256, 1), (256, 2), (512, 1), (512, 2)] {
    let name = "icon_\(pt)x\(pt)@\(scale)x.png"
    try render(pt * scale).write(to: set.appendingPathComponent(name))
    images.append(["size": "\(pt)x\(pt)", "idiom": "mac", "scale": "\(scale)x", "filename": name])
}
let contents: [String: Any] = ["images": images, "info": ["version": 1, "author": "xcode"]]
try JSONSerialization.data(withJSONObject: contents, options: [.prettyPrinted, .sortedKeys])
    .write(to: set.appendingPathComponent("Contents.json"))
try #"{"info":{"version":1,"author":"xcode"}}"#.data(using: .utf8)!
    .write(to: root.appendingPathComponent("owl/Assets.xcassets/Contents.json"))
print("wrote \(images.count) icons")
