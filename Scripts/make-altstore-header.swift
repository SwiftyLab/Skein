// Renders AltStore/header.png, the banner on the AltStore source's About page.
// AltStore recommends 3:2. Uses the app icon and the asset catalog's accent
// colour, so it follows them when they change.
//
//   swift Scripts/make-altstore-header.swift
import AppKit

let size = NSSize(width: 1500, height: 1000)
let assets = URL(fileURLWithPath: "App/Resources/Assets.xcassets")

/// The light-appearance accent colour from the asset catalog.
func accent() -> NSColor {
    let url = assets.appendingPathComponent("AccentColor.colorset/Contents.json")
    guard let data = try? Data(contentsOf: url),
          let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          let color = (json["colors"] as? [[String: Any]])?.first(where: { $0["appearances"] == nil })?["color"] as? [String: Any],
          let c = color["components"] as? [String: String] else { return .systemTeal }
    func value(_ key: String) -> CGFloat {
        let v = Double(c[key] ?? "0") ?? 0
        return CGFloat(v <= 1 ? v : v / 255)
    }
    return NSColor(srgbRed: value("red"), green: value("green"), blue: value("blue"), alpha: 1)
}

let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width), pixelsHigh: Int(size.height),
                           bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                           colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)

let base = accent()
NSGradient(starting: base.blended(withFraction: 0.15, of: .white)!, ending: base.blended(withFraction: 0.55, of: .black)!)!
    .draw(in: NSRect(origin: .zero, size: size), angle: -60)

// The icon, centred above the name, with a soft shadow like a home-screen icon.
let iconSide: CGFloat = 400
let iconRect = NSRect(x: (size.width - iconSide) / 2, y: 430, width: iconSide, height: iconSide)
if let icon = NSImage(contentsOf: assets.appendingPathComponent("AppIcon.appiconset/icon-universal-1024x1024@1x.png")) {
    NSGraphicsContext.saveGraphicsState()
    let shadow = NSShadow()
    shadow.shadowColor = NSColor.black.withAlphaComponent(0.35)
    shadow.shadowBlurRadius = 40
    shadow.shadowOffset = NSSize(width: 0, height: -14)
    shadow.set()
    NSBezierPath(roundedRect: iconRect, xRadius: iconSide * 0.225, yRadius: iconSide * 0.225).addClip()
    icon.draw(in: iconRect)
    NSGraphicsContext.restoreGraphicsState()
}

let centred = NSMutableParagraphStyle()
centred.alignment = .center
NSAttributedString(string: "Skein", attributes: [
    .font: NSFont.systemFont(ofSize: 150, weight: .heavy), .foregroundColor: NSColor.white,
    .paragraphStyle: centred, .kern: -2,
]).draw(in: NSRect(x: 0, y: 220, width: size.width, height: 190))
NSAttributedString(string: "BitTorrent, done natively", attributes: [
    .font: NSFont.systemFont(ofSize: 58, weight: .medium), .foregroundColor: NSColor.white.withAlphaComponent(0.85),
    .paragraphStyle: centred,
]).draw(in: NSRect(x: 0, y: 130, width: size.width, height: 80))

NSGraphicsContext.restoreGraphicsState()
let out = URL(fileURLWithPath: "AltStore/header.png")
try FileManager.default.createDirectory(at: out.deletingLastPathComponent(), withIntermediateDirectories: true)
try rep.representation(using: .png, properties: [:])!.write(to: out)
print("wrote \(out.relativePath)")
