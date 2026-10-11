#!/usr/bin/env swift
// Renders the Swarmly app icon into the asset catalog.
// Usage: swift scripts/make-icon.swift
import AppKit
import CoreGraphics

let size: CGFloat = 1024
let space = CGColorSpace(name: CGColorSpace.sRGB)!
let context = CGContext(data: nil, width: Int(size), height: Int(size), bitsPerComponent: 8, bytesPerRow: 0,
                        space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!

func color(_ hex: UInt32, _ alpha: CGFloat = 1) -> CGColor {
    CGColor(colorSpace: space, components: [CGFloat((hex >> 16) & 0xFF) / 255, CGFloat((hex >> 8) & 0xFF) / 255,
                                            CGFloat(hex & 0xFF) / 255, alpha])!
}

// macOS icon grid: an 824 pt rounded square centred on a 1024 pt canvas.
let body = CGRect(x: 100, y: 100, width: 824, height: 824)
let shape = CGPath(roundedRect: body, cornerWidth: 186, cornerHeight: 186, transform: nil)

// Flat tile: one solid colour, no gradients or shadows.
context.addPath(shape)
context.setFillColor(color(0x3B4CF0))
context.fillPath()

// Glyph: a download arrow dropping into a tray.
context.setLineCap(.round)
context.setLineJoin(.round)
context.setLineWidth(84)
context.setStrokeColor(color(0xFFFFFF))
func stroke(_ points: [CGPoint]) {
    context.move(to: points[0])
    for point in points.dropFirst() { context.addLine(to: point) }
    context.strokePath()
}
stroke([CGPoint(x: 512, y: 735), CGPoint(x: 512, y: 410)])
stroke([CGPoint(x: 362, y: 560), CGPoint(x: 512, y: 410), CGPoint(x: 662, y: 560)])
stroke([CGPoint(x: 300, y: 365), CGPoint(x: 300, y: 270), CGPoint(x: 724, y: 270), CGPoint(x: 724, y: 365)])

let root = URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent().deletingLastPathComponent()
let iconset = root.appendingPathComponent("Sources/Swarmly/Resources/Assets.xcassets/AppIcon.appiconset")
try? FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)

let master = context.makeImage()!
var entries: [String] = []
for (points, scale) in [(16, 1), (16, 2), (32, 1), (32, 2), (128, 1), (128, 2), (256, 1), (256, 2), (512, 1), (512, 2)] {
    let pixels = points * scale
    let scaled = CGContext(data: nil, width: pixels, height: pixels, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                           bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    scaled.interpolationQuality = .high
    scaled.draw(master, in: CGRect(x: 0, y: 0, width: pixels, height: pixels))
    let name = "icon_\(points)x\(points)\(scale == 2 ? "@2x" : "").png"
    let data = NSBitmapImageRep(cgImage: scaled.makeImage()!).representation(using: .png, properties: [:])!
    try data.write(to: iconset.appendingPathComponent(name))
    entries.append("    { \"filename\" : \"\(name)\", \"idiom\" : \"mac\", \"scale\" : \"\(scale)x\", \"size\" : \"\(points)x\(points)\" }")
}
let contents = "{\n  \"images\" : [\n\(entries.joined(separator: ",\n"))\n  ],\n  \"info\" : { \"author\" : \"xcode\", \"version\" : 1 }\n}\n"
try contents.write(to: iconset.appendingPathComponent("Contents.json"), atomically: true, encoding: .utf8)
print("Wrote \(entries.count) icon sizes to \(iconset.path)")
