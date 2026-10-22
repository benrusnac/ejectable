#!/usr/bin/env swift
// Draws Ejectable's app icon with CoreGraphics (no third-party or SF Symbol artwork: Apple's symbol licence excludes
// app icons) and writes Resources/AppIcon.icns through `iconutil`.
//
//   swift Tools/make-icon.swift [output.icns] [--preview preview.png]
//
// The artwork echoes the status item's `externaldrive` symbol: a rounded external-drive body (orange, like the
// Finder icon of an external disk) with a white eject triangle and bar on its face, on a light macOS icon tile.
import AppKit
import CoreGraphics
import Foundation

let args = CommandLine.arguments.dropFirst()
let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
let output = args.first(where: { !$0.hasPrefix("--") && $0.hasSuffix(".icns") })
    .map { URL(fileURLWithPath: $0) } ?? root.appendingPathComponent("Resources/AppIcon.icns")
let preview = args.firstIndex(of: "--preview").flatMap { i in args.index(after: i) < args.endIndex ? args[args.index(after: i)] : nil }

func color(_ hex: UInt32, _ alpha: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
}

func linear(_ ctx: CGContext, in path: CGPath, top: CGColor, bottom: CGColor, from y0: CGFloat, to y1: CGFloat) {
    ctx.saveGState()
    ctx.addPath(path)
    ctx.clip()
    let g = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: [bottom, top] as CFArray, locations: [0, 1])!
    ctx.drawLinearGradient(g, start: CGPoint(x: 0, y: y0), end: CGPoint(x: 0, y: y1), options: [])
    ctx.restoreGState()
}

/// |x/r|^n + |y/r|^n = 1 around (center, center): Apple's continuous-corner icon shape, closely enough for macOS 26.
func squircle(center c: Double, radius r: Double, n: Double = 5) -> CGPath {
    let p = CGMutablePath()
    for i in 0...720 {
        let t = Double(i) / 720 * 2 * Double.pi
        let ct = cos(t), st = sin(t)
        let pt = CGPoint(x: c + r * (ct < 0 ? -1 : 1) * pow(abs(ct), 2 / n), y: c + r * (st < 0 ? -1 : 1) * pow(abs(st), 2 / n))
        if i == 0 { p.move(to: pt) } else { p.addLine(to: pt) }
    }
    p.closeSubpath()
    return p
}

/// Draws the icon on a 1024 x 1024 canvas (origin bottom-left), scaled to `size` pixels.
func render(size: Int) -> CGImage {
    let ctx = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
                        space: CGColorSpace(name: CGColorSpace.sRGB)!,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.scaleBy(x: CGFloat(size) / 1024, y: CGFloat(size) / 1024)
    ctx.setShouldAntialias(true)
    ctx.interpolationQuality = .high

    // Tile: Apple's macOS grid (824 pt in 1024, 100 pt margin) as a continuous-corner squircle (superellipse n = 5),
    // and NO drop shadow: macOS 26 then shows the icon as is. A plain rounded rect, a full-bleed square or an outer
    // shadow make it shrink the artwork into its own gray tile ("icon jail"), measured with NSWorkspace.icon(forFile:).
    let tile = squircle(center: 512, radius: 412)
    ctx.saveGState()
    ctx.addPath(tile)
    ctx.setFillColor(color(0xF4F4F7))
    ctx.fillPath()
    ctx.restoreGState()
    linear(ctx, in: tile, top: color(0xFFFFFF), bottom: color(0xDCDDE3), from: 100, to: 924)

    // Drive body: wide rounded rectangle, orange gradient, with a darker base band and a status light.
    let body = CGRect(x: 190, y: 300, width: 644, height: 400)
    let bodyPath = CGPath(roundedRect: body, cornerWidth: 86, cornerHeight: 86, transform: nil)
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -14), blur: 26, color: color(0x7A3300, 0.35))
    ctx.addPath(bodyPath)
    ctx.setFillColor(color(0xF5891F))
    ctx.fillPath()
    ctx.restoreGState()
    linear(ctx, in: bodyPath, top: color(0xFFB347), bottom: color(0xEE7410), from: body.minY, to: body.maxY)

    // Base band (the drive's front edge), separated by a thin highlight line.
    ctx.saveGState()
    ctx.addPath(bodyPath)
    ctx.clip()
    let band = CGRect(x: body.minX, y: body.minY, width: body.width, height: 96)
    linear(ctx, in: CGPath(rect: band, transform: nil), top: color(0xE06A0C), bottom: color(0xC95A06), from: band.minY, to: band.maxY)
    ctx.setFillColor(color(0xFFFFFF, 0.35))
    ctx.fill(CGRect(x: body.minX, y: band.maxY, width: body.width, height: 5))
    ctx.restoreGState()
    // Status light.
    ctx.setFillColor(color(0xFFF4E0))
    ctx.fillEllipse(in: CGRect(x: body.maxX - 112, y: body.minY + 34, width: 30, height: 30))
    // Top-edge gloss.
    ctx.saveGState()
    ctx.addPath(bodyPath)
    ctx.clip()
    linear(ctx, in: CGPath(rect: CGRect(x: body.minX, y: body.maxY - 120, width: body.width, height: 120), transform: nil),
           top: color(0xFFFFFF, 0.30), bottom: color(0xFFFFFF, 0), from: body.maxY - 120, to: body.maxY)
    ctx.restoreGState()

    // Eject glyph: white triangle over a bar, centred on the face above the band.
    let cx = body.midX
    let faceMid = (band.maxY + body.maxY) / 2 + 4
    let triW: CGFloat = 220, triH: CGFloat = 112, barH: CGFloat = 36, gap: CGFloat = 26
    let total = triH + gap + barH
    let barY = faceMid - total / 2
    let triBase = barY + barH + gap
    let tri = CGMutablePath()
    tri.move(to: CGPoint(x: cx - triW / 2, y: triBase))
    tri.addLine(to: CGPoint(x: cx + triW / 2, y: triBase))
    tri.addLine(to: CGPoint(x: cx, y: triBase + triH))
    tri.closeSubpath()
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -3), blur: 6, color: color(0x8A3A00, 0.35))
    ctx.beginTransparencyLayer(auxiliaryInfo: nil)              // one shadow for the whole glyph
    ctx.setFillColor(color(0xFFFFFF))
    ctx.setLineJoin(.round)
    ctx.setLineWidth(18)
    ctx.setStrokeColor(color(0xFFFFFF))
    ctx.addPath(tri)
    ctx.drawPath(using: .fillStroke)                            // stroke rounds the corners
    ctx.addPath(CGPath(roundedRect: CGRect(x: cx - triW / 2 - 9, y: barY, width: triW + 18, height: barH),
                       cornerWidth: 12, cornerHeight: 12, transform: nil))
    ctx.fillPath()
    ctx.endTransparencyLayer()
    ctx.restoreGState()

    return ctx.makeImage()!
}

func writePNG(_ image: CGImage, to url: URL) throws {
    let rep = NSBitmapImageRep(cgImage: image)
    guard let data = rep.representation(using: .png, properties: [:]) else { throw CocoaError(.fileWriteUnknown) }
    try data.write(to: url)
}

let iconset = FileManager.default.temporaryDirectory.appendingPathComponent("Ejectable-\(getpid()).iconset", isDirectory: true)
try? FileManager.default.removeItem(at: iconset)
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
for base in [16, 32, 128, 256, 512] {
    try writePNG(render(size: base), to: iconset.appendingPathComponent("icon_\(base)x\(base).png"))
    try writePNG(render(size: base * 2), to: iconset.appendingPathComponent("icon_\(base)x\(base)@2x.png"))
}
if let preview { try writePNG(render(size: 1024), to: URL(fileURLWithPath: preview)) }

let p = Process()
p.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
p.arguments = ["-c", "icns", iconset.path, "-o", output.path]
try p.run()
p.waitUntilExit()
try? FileManager.default.removeItem(at: iconset)
guard p.terminationStatus == 0 else { FileHandle.standardError.write(Data("iconutil failed\n".utf8)); exit(1) }
print("wrote \(output.path)")
