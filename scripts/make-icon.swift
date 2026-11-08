#!/usr/bin/env swift
// Builds the macOS app icon set from the logo file.
// Usage: swift scripts/make-icon.swift Branding/logo.png Sources/Resources/Assets.xcassets/AppIcon.appiconset
import AppKit

let arguments = CommandLine.arguments
guard arguments.count == 3 else {
    print("usage: make-icon.swift <logo image> <output .appiconset folder>")
    exit(2)
}
guard let source = NSImage(contentsOfFile: arguments[1]),
      let logo = source.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
    print("cannot read \(arguments[1])")
    exit(1)
}
let output = URL(fileURLWithPath: arguments[2])
try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)

/// The white square with rounded corners and the margin that macOS icons have.
func render(pixels: Int) -> Data {
    let scale = CGFloat(pixels) / 1024
    let context = CGContext(
        data: nil, width: pixels, height: pixels, bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpace(name: CGColorSpace.sRGB)!,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    )!
    context.interpolationQuality = .high
    let plate = CGRect(x: 100 * scale, y: 100 * scale, width: 824 * scale, height: 824 * scale)
    context.addPath(CGPath(roundedRect: plate, cornerWidth: 185 * scale, cornerHeight: 185 * scale, transform: nil) as CGPath)
    context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
    context.fillPath()

    let available = 660 * scale
    let fit = min(available / CGFloat(logo.width), available / CGFloat(logo.height))
    let size = CGSize(width: CGFloat(logo.width) * fit, height: CGFloat(logo.height) * fit)
    let origin = CGPoint(x: (CGFloat(pixels) - size.width) / 2, y: (CGFloat(pixels) - size.height) / 2)
    context.draw(logo, in: CGRect(origin: origin, size: size))

    let image = NSBitmapImageRep(cgImage: context.makeImage()!)
    return image.representation(using: .png, properties: [:])!
}

var entries: [[String: String]] = []
for points in [16, 32, 128, 256, 512] {
    for factor in [1, 2] {
        let name = "icon_\(points)x\(points)\(factor == 2 ? "@2x" : "").png"
        try render(pixels: points * factor).write(to: output.appending(path: name))
        entries.append(["idiom": "mac", "size": "\(points)x\(points)", "scale": "\(factor)x", "filename": name])
    }
}
let contents: [String: Any] = ["images": entries, "info": ["author": "xcode", "version": 1]]
try JSONSerialization.data(withJSONObject: contents, options: [.prettyPrinted, .sortedKeys])
    .write(to: output.appending(path: "Contents.json"))
print("wrote \(entries.count) icons to \(output.path)")
