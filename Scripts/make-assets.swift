#!/usr/bin/env swift

// Renders Skein's generated assets: the app icon and the accent colour.
//
// Drawn in code rather than shipped as a binary asset so it can be adjusted and
// regenerated: there is no SVG rasteriser or Pillow on a stock macOS, but
// CoreGraphics is always there.
//
//   swift Scripts/make-assets.swift
//
// The mark is a skein of yarn — a lemniscate of thread with a tie across its
// waist. It suits the name, and the two loops converging through one crossing
// point read as many strands becoming one file.

import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

// MARK: - Palette

struct RGB {
    let r: Double, g: Double, b: Double
    func cg(_ alpha: Double = 1) -> CGColor {
        CGColor(red: r, green: g, blue: b, alpha: alpha)
    }
}

let backgroundTop = RGB(r: 0.10, g: 0.18, b: 0.42)   // deep indigo
let backgroundBottom = RGB(r: 0.05, g: 0.42, b: 0.53) // teal
let strandLight = RGB(r: 0.98, g: 0.97, b: 0.93)      // warm off-white
let strandShade = RGB(r: 0.72, g: 0.82, b: 0.88)      // cool grey-blue
let tieColour = RGB(r: 0.98, g: 0.71, b: 0.30)        // amber

// The accent is drawn from the icon's teal so the two agree, but pushed toward
// cyan and away from green: "seeding" is green in the UI, and an accent close
// to it would make the two states hard to tell apart, especially for anyone
// with a red-green colour deficiency.
let accentLight = RGB(r: 0.047, g: 0.451, b: 0.600)   // on white
let accentDark = RGB(r: 0.353, g: 0.780, b: 0.902)    // on black

// MARK: - Geometry

/// One bird: a chevron pointing down, drawn as a stroked V.
func chevron(at centre: CGPoint, width: Double, sweep: Double) -> CGPath {
    let path = CGMutablePath()
    path.move(to: CGPoint(x: centre.x - width / 2, y: centre.y + sweep / 2))
    path.addLine(to: CGPoint(x: centre.x, y: centre.y - sweep / 2))
    path.addLine(to: CGPoint(x: centre.x + width / 2, y: centre.y + sweep / 2))
    return path
}

/// Draws the mark into `context`, filling a `size` x `size` square.
/// `inset` leaves the transparent margin macOS icons are expected to have.
func drawIcon(in context: CGContext, size: Double, inset: Double, rounded: Bool,
              pixels: Int) {
    let artOrigin = size * inset
    let artSize = size * (1 - 2 * inset)
    let artRect = CGRect(x: artOrigin, y: artOrigin, width: artSize, height: artSize)

    context.saveGState()

    // Background plate.
    if rounded {
        // The macOS squircle is close enough to a rounded rect at icon sizes.
        let radius = artSize * 0.2237
        context.addPath(CGPath(roundedRect: artRect, cornerWidth: radius,
                               cornerHeight: radius, transform: nil))
        context.clip()
    } else {
        context.clip(to: artRect)
    }

    let space = CGColorSpaceCreateDeviceRGB()
    if let gradient = CGGradient(
        colorsSpace: space,
        colors: [backgroundBottom.cg(), backgroundTop.cg()] as CFArray,
        locations: [0, 1]
    ) {
        context.drawLinearGradient(
            gradient,
            start: CGPoint(x: artRect.minX, y: artRect.minY),
            end: CGPoint(x: artRect.maxX, y: artRect.maxY),
            options: [])
    }

    // A skein is also a flock of geese in flight, so the mark is a descending
    // V-formation: the formation itself reads as one chevron at 16pt, and the
    // individual birds resolve at larger sizes. Pointing down suits a client
    // whose job is pulling things toward you.
    context.setLineCap(.round)
    context.setLineJoin(.round)

    let centre = CGPoint(x: artRect.midX, y: artRect.midY)
    let unit = artSize
    let leadWidth = unit * 0.26
    let leadSweep = unit * 0.15
    let stroke = unit * 0.068

    // The leader sits lowest and the rest trail up and outward, so the
    // formation points the same way the birds do. Spread is bounded so the
    // outermost pair clears the edge: 0.30 + half their width still leaves a
    // comfortable margin inside the 0.5 half-width.
    // Five birds turn to mush below about 48pt, which is the Finder sidebar and
    // menu bar size, so the small variants drop the trailing pair and fly the
    // remaining three larger. Apple's own icons simplify the same way.
    let birds: [(dx: Double, dy: Double, scale: Double, colour: RGB)]
    if pixels <= 48 {
        birds = [
            (0.000, 0.185, 1.30, tieColour),
            (-0.235, -0.105, 1.05, strandLight),
            (0.235, -0.105, 1.05, strandLight),
        ]
    } else {
        birds = [
            (0.000, 0.215, 1.00, tieColour),
            (-0.180, -0.005, 0.84, strandLight),
            (0.180, -0.005, 0.84, strandLight),
            (-0.330, -0.205, 0.66, strandShade),
            (0.330, -0.205, 0.66, strandShade),
        ]
    }

    for bird in birds {
        let position = CGPoint(x: centre.x + bird.dx * unit,
                               y: centre.y - bird.dy * unit)
        context.addPath(chevron(
            at: position,
            width: leadWidth * bird.scale,
            sweep: leadSweep * bird.scale))
        context.setStrokeColor(bird.colour.cg())
        context.setLineWidth(stroke * (0.72 + 0.28 * bird.scale))
        context.strokePath()
    }

    context.restoreGState()
}

/// `opaque` drops the alpha channel. iOS app icons must not have one — the
/// system applies its own mask, and an alpha channel is rejected at validation
/// — whereas macOS icons need transparency for the margin around the squircle.
func renderPNG(size: Int, inset: Double, rounded: Bool, opaque: Bool,
               to url: URL) throws {
    let space = CGColorSpaceCreateDeviceRGB()
    let alphaInfo: CGImageAlphaInfo = opaque ? .noneSkipLast : .premultipliedLast
    guard let context = CGContext(
        data: nil, width: size, height: size, bitsPerComponent: 8,
        bytesPerRow: 0, space: space,
        bitmapInfo: alphaInfo.rawValue)
    else {
        throw Failure("could not create a \(size)pt context")
    }
    context.setAllowsAntialiasing(true)
    context.interpolationQuality = .high

    drawIcon(in: context, size: Double(size), inset: inset, rounded: rounded,
             pixels: size)

    guard let image = context.makeImage(),
          let destination = CGImageDestinationCreateWithURL(
            url as CFURL, UTType.png.identifier as CFString, 1, nil)
    else {
        throw Failure("could not encode \(url.lastPathComponent)")
    }
    CGImageDestinationAddImage(destination, image, nil)
    guard CGImageDestinationFinalize(destination) else {
        throw Failure("could not write \(url.lastPathComponent)")
    }
}

struct Failure: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}

// MARK: - Asset catalog

struct Entry {
    let idiom: String
    let size: Double
    let scale: Int
    var pixels: Int { Int(size * Double(scale)) }
    var filename: String { "icon-\(idiom)-\(Int(size))x\(Int(size))@\(scale)x.png" }
}

// iOS wants one full-bleed square with no alpha and no rounding; the system
// applies its own mask. macOS wants the full ladder, each with its transparent
// margin baked in.
let entries: [Entry] =
    [Entry(idiom: "universal", size: 1024, scale: 1)]
    + [16.0, 32, 128, 256, 512].flatMap { size in
        [Entry(idiom: "mac", size: size, scale: 1),
         Entry(idiom: "mac", size: size, scale: 2)]
    }

let root = URL(fileURLWithPath: CommandLine.arguments.count > 1
    ? CommandLine.arguments[1]
    : "App/Resources/Assets.xcassets/AppIcon.appiconset")
try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

for entry in entries {
    let isMac = entry.idiom == "mac"
    try renderPNG(
        size: entry.pixels,
        // macOS icons sit in a transparent margin; iOS fills the square.
        inset: isMac ? 0.098 : 0,
        rounded: isMac,
        opaque: !isMac,
        to: root.appendingPathComponent(entry.filename))
}

var images: [[String: String]] = entries.map { entry in
    [
        "filename": entry.filename,
        "idiom": entry.idiom == "mac" ? "mac" : "universal",
        "scale": "\(entry.scale)x",
        "size": "\(Int(entry.size))x\(Int(entry.size))",
    ]
}
// The universal entry is iOS/iPadOS marketing art and carries no scale suffix
// in the catalog, so correct it after the fact.
images[0] = ["filename": entries[0].filename, "idiom": "universal",
             "platform": "ios", "size": "1024x1024"]

let catalog: [String: Any] = [
    "images": images,
    "info": ["author": "xcode", "version": 1],
]
let data = try JSONSerialization.data(
    withJSONObject: catalog, options: [.prettyPrinted, .sortedKeys])
try data.write(to: root.appendingPathComponent("Contents.json"))

// MARK: - Accent colour

/// Writes the AccentColor set. Xcode picks this up by name through
/// ASSETCATALOG_COMPILER_GLOBAL_ACCENT_COLOR_NAME, which Project.swift sets.
func writeAccentColour(into catalog: URL) throws {
    let set = catalog.appendingPathComponent("AccentColor.colorset")
    try FileManager.default.createDirectory(at: set, withIntermediateDirectories: true)

    func component(_ value: Double) -> String { String(format: "%.3f", value) }
    func entry(_ colour: RGB, dark: Bool) -> [String: Any] {
        var value: [String: Any] = [
            "color": [
                "color-space": "srgb",
                "components": [
                    "alpha": "1.000",
                    "red": component(colour.r),
                    "green": component(colour.g),
                    "blue": component(colour.b),
                ],
            ],
            "idiom": "universal",
        ]
        if dark {
            value["appearances"] = [["appearance": "luminosity", "value": "dark"]]
        }
        return value
    }

    let contents: [String: Any] = [
        // The first entry with no appearance is the light and fallback value.
        "colors": [entry(accentLight, dark: false), entry(accentDark, dark: true)],
        "info": ["author": "xcode", "version": 1],
    ]
    let data = try JSONSerialization.data(
        withJSONObject: contents, options: [.prettyPrinted, .sortedKeys])
    try data.write(to: set.appendingPathComponent("Contents.json"))
}

try writeAccentColour(into: root.deletingLastPathComponent())

print("Wrote \(entries.count) images and the accent colour to \(root.deletingLastPathComponent().path)")
