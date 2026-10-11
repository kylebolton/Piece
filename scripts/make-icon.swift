#!/usr/bin/env swift
// Renders the Piece app icon into the asset catalog.
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

// Tile: deep indigo to teal glass.
context.saveGState()
context.addPath(shape)
context.clip()
let tile = CGGradient(colorsSpace: space, colors: [color(0x1E1B7A), color(0x3548EE), color(0x19C7C4)] as CFArray, locations: [0, 0.55, 1])!
context.drawLinearGradient(tile, start: CGPoint(x: 140, y: 924), end: CGPoint(x: 900, y: 110), options: [])
// Soft top light.
let glow = CGGradient(colorsSpace: space, colors: [color(0xFFFFFF, 0.28), color(0xFFFFFF, 0)] as CFArray, locations: [0, 1])!
context.drawRadialGradient(glow, startCenter: CGPoint(x: 400, y: 900), startRadius: 0, endCenter: CGPoint(x: 400, y: 900), endRadius: 620, options: [])

// Jigsaw piece geometry: a square with a knob up and right, a socket left and down.
func jigsaw(center: CGPoint, side: CGFloat) -> CGPath {
    let half = side / 2
    let path = CGMutablePath()
    // One edge from `from` to `to`; `sign` +1 bulges to the left of travel (outward when clockwise), -1 dents inward.
    func edge(from a: CGPoint, to b: CGPoint, sign: CGFloat) {
        let dx = b.x - a.x, dy = b.y - a.y
        let length = (dx * dx + dy * dy).squareRoot()
        let ux = dx / length, uy = dy / length
        let nx = -uy * sign, ny = ux * sign
        func point(_ t: CGFloat, _ h: CGFloat) -> CGPoint {
            CGPoint(x: a.x + ux * t * length + nx * h * length, y: a.y + uy * t * length + ny * h * length)
        }
        path.addLine(to: point(0.38, 0))
        path.addCurve(to: point(0.40, 0.13), control1: point(0.40, 0.05), control2: point(0.40, 0.10))
        path.addCurve(to: point(0.50, 0.31), control1: point(0.28, 0.16), control2: point(0.30, 0.31))
        path.addCurve(to: point(0.60, 0.13), control1: point(0.70, 0.31), control2: point(0.72, 0.16))
        path.addCurve(to: point(0.62, 0), control1: point(0.60, 0.10), control2: point(0.60, 0.05))
        path.addLine(to: b)
    }
    let tl = CGPoint(x: center.x - half, y: center.y + half), tr = CGPoint(x: center.x + half, y: center.y + half)
    let br = CGPoint(x: center.x + half, y: center.y - half), bl = CGPoint(x: center.x - half, y: center.y - half)
    path.move(to: tl)
    edge(from: tl, to: tr, sign: 1)
    edge(from: tr, to: br, sign: 1)
    edge(from: br, to: bl, sign: -1)
    edge(from: bl, to: tl, sign: -1)
    path.closeSubpath()
    return path
}

// Ghost neighbours: the rest of the puzzle fading away behind the hero piece.
let side: CGFloat = 340
for (dx, dy, alpha) in [(-1, 1, 0.10), (1, -1, 0.10), (-1, -1, 0.07), (1, 1, 0.07), (-2, 0, 0.04), (0, 2, 0.04)] as [(CGFloat, CGFloat, CGFloat)] {
    let ghost = jigsaw(center: CGPoint(x: 512 + dx * side * 1.0, y: 512 + dy * side * 1.0), side: side)
    context.addPath(ghost)
    context.setFillColor(color(0xFFFFFF, alpha))
    context.fillPath()
}

// Hero piece with a drop shadow.
let piece = jigsaw(center: CGPoint(x: 512, y: 512), side: side)
context.saveGState()
context.setShadow(offset: CGSize(width: 0, height: -26), blur: 50, color: color(0x0A0A4A, 0.55))
context.addPath(piece)
context.setFillColor(color(0xFFFFFF))
context.fillPath()
context.restoreGState()

context.saveGState()
context.addPath(piece)
context.clip()
let glass = CGGradient(colorsSpace: space, colors: [color(0xFFFFFF), color(0xDDE4FF), color(0xA9B8FF)] as CFArray, locations: [0, 0.6, 1])!
context.drawLinearGradient(glass, start: CGPoint(x: 400, y: 800), end: CGPoint(x: 620, y: 220), options: [])
// Specular band across the upper half.
let sheen = CGGradient(colorsSpace: space, colors: [color(0xFFFFFF, 0.55), color(0xFFFFFF, 0)] as CFArray, locations: [0, 1])!
context.drawLinearGradient(sheen, start: CGPoint(x: 512, y: 760), end: CGPoint(x: 512, y: 470), options: [])
context.restoreGState()

// Crisp rim.
context.addPath(piece)
context.setStrokeColor(color(0xFFFFFF, 0.9))
context.setLineWidth(5)
context.strokePath()
context.restoreGState()

// Outer tile rim light.
context.addPath(shape)
context.setStrokeColor(color(0xFFFFFF, 0.25))
context.setLineWidth(3)
context.strokePath()

let root = URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent().deletingLastPathComponent()
let iconset = root.appendingPathComponent("Sources/Piece/Resources/Assets.xcassets/AppIcon.appiconset")
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
