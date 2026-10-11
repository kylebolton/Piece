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

// Drop shadow under the tile.
context.saveGState()
context.setShadow(offset: CGSize(width: 0, height: -12), blur: 28, color: color(0x000000, 0.32))
context.addPath(shape)
context.setFillColor(color(0x2A1B7A))
context.fillPath()
context.restoreGState()

// Background: deep indigo to violet.
context.saveGState()
context.addPath(shape)
context.clip()
let background = CGGradient(colorsSpace: space, colors: [color(0x8B6CFF), color(0x5B3FE8), color(0x2E1A8F)] as CFArray,
                            locations: [0, 0.5, 1])!
context.drawLinearGradient(background, start: CGPoint(x: 280, y: 924), end: CGPoint(x: 744, y: 100),
                           options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
let glow = CGGradient(colorsSpace: space, colors: [color(0xC4B5FF, 0.55), color(0xC4B5FF, 0)] as CFArray, locations: [0, 1])!
context.drawRadialGradient(glow, startCenter: CGPoint(x: 330, y: 860), startRadius: 0,
                           endCenter: CGPoint(x: 330, y: 860), endRadius: 560, options: [])
let shade = CGGradient(colorsSpace: space, colors: [color(0x0E0640, 0), color(0x0E0640, 0.45)] as CFArray, locations: [0, 1])!
context.drawLinearGradient(shade, start: CGPoint(x: 512, y: 480), end: CGPoint(x: 512, y: 100), options: [])
context.restoreGState()

// Glyph: a swarm of peers funnelling into a download arrow.
func dot(_ x: CGFloat, _ y: CGFloat, _ r: CGFloat, _ fill: CGColor) {
    context.saveGState()
    context.setShadow(offset: CGSize(width: 0, height: -6), blur: 14, color: color(0x14084D, 0.4))
    context.setFillColor(fill)
    context.fillEllipse(in: CGRect(x: x - r, y: y - r, width: r * 2, height: r * 2))
    context.restoreGState()
}

let mint = color(0x7CF5D0)
let mintSoft = color(0x7CF5D0, 0.7)
// (x, y, radius): wide at the top, narrowing toward the arrow.
let swarm: [(CGFloat, CGFloat, CGFloat)] = [
    (290, 790, 34), (400, 842, 28), (512, 800, 40), (624, 846, 30), (734, 786, 34),
    (350, 706, 26), (452, 730, 32), (572, 724, 26), (674, 700, 30),
]
for (index, d) in swarm.enumerated() { dot(d.0, d.1, d.2, index % 3 == 0 ? mint : mintSoft) }

context.setLineCap(.round)
context.setLineJoin(.round)
context.setLineWidth(96)
func stroke(_ points: [CGPoint], _ strokeColor: CGColor, shadow: Bool = true) {
    context.saveGState()
    if shadow { context.setShadow(offset: CGSize(width: 0, height: -10), blur: 22, color: color(0x14084D, 0.45)) }
    context.setStrokeColor(strokeColor)
    context.move(to: points[0])
    for point in points.dropFirst() { context.addLine(to: point) }
    context.strokePath()
    context.restoreGState()
}
stroke([CGPoint(x: 512, y: 640), CGPoint(x: 512, y: 270)], color(0xFFFFFF))
stroke([CGPoint(x: 352, y: 420), CGPoint(x: 512, y: 270), CGPoint(x: 672, y: 420)], color(0xFFFFFF), shadow: false)


// Top highlight on the tile edge.
context.saveGState()
context.addPath(shape)
context.clip()
context.addPath(CGPath(roundedRect: body.insetBy(dx: 3, dy: 3), cornerWidth: 183, cornerHeight: 183, transform: nil))
context.setLineWidth(6)
context.replacePathWithStrokedPath()
context.clip()
let rim = CGGradient(colorsSpace: space, colors: [color(0xFFFFFF, 0.45), color(0xFFFFFF, 0)] as CFArray, locations: [0, 1])!
context.drawLinearGradient(rim, start: CGPoint(x: 512, y: 924), end: CGPoint(x: 512, y: 560), options: [])
context.restoreGState()

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
