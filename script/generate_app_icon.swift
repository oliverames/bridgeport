#!/usr/bin/env swift

import AppKit
import Foundation

let rootURL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let resourcesURL = rootURL.appendingPathComponent("Resources", isDirectory: true)
let iconsetURL = resourcesURL.appendingPathComponent("AppIcon.iconset", isDirectory: true)
let icnsURL = resourcesURL.appendingPathComponent("AppIcon.icns")

try FileManager.default.createDirectory(at: resourcesURL, withIntermediateDirectories: true)
if FileManager.default.fileExists(atPath: iconsetURL.path) {
    try FileManager.default.removeItem(at: iconsetURL)
}
try FileManager.default.createDirectory(at: iconsetURL, withIntermediateDirectories: true)

func point(_ x: CGFloat, _ y: CGFloat, size: CGFloat) -> NSPoint {
    NSPoint(x: x * size, y: y * size)
}

func drawIcon(size: Int) throws -> NSBitmapImageRep {
    guard let bitmap = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: size,
        pixelsHigh: size,
        bitsPerSample: 8,
        samplesPerPixel: 4,
        hasAlpha: true,
        isPlanar: false,
        colorSpaceName: .deviceRGB,
        bytesPerRow: 0,
        bitsPerPixel: 0
    ) else {
        throw NSError(domain: "BridgeportIcon", code: 1, userInfo: [NSLocalizedDescriptionKey: "Could not create \(size)x\(size) bitmap"])
    }

    bitmap.size = NSSize(width: size, height: size)
    let context = NSGraphicsContext(bitmapImageRep: bitmap)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = context
    defer {
        NSGraphicsContext.restoreGraphicsState()
    }

    let iconSize = CGFloat(size)
    let bounds = NSRect(x: 0, y: 0, width: iconSize, height: iconSize)
    let inset = iconSize * 0.045
    let tile = bounds.insetBy(dx: inset, dy: inset)
    let radius = iconSize * 0.20
    let tilePath = NSBezierPath(roundedRect: tile, xRadius: radius, yRadius: radius)

    NSColor.clear.setFill()
    bounds.fill()

    let background = NSGradient(colors: [
        NSColor(calibratedRed: 0.035, green: 0.125, blue: 0.265, alpha: 1.0),
        NSColor(calibratedRed: 0.00, green: 0.43, blue: 0.63, alpha: 1.0),
        NSColor(calibratedRed: 0.14, green: 0.77, blue: 0.67, alpha: 1.0)
    ])!
    background.draw(in: tilePath, angle: 310)

    NSColor(calibratedWhite: 1, alpha: 0.18).setStroke()
    tilePath.lineWidth = max(1, iconSize * 0.018)
    tilePath.stroke()

    let glassPath = NSBezierPath(roundedRect: tile.insetBy(dx: iconSize * 0.035, dy: iconSize * 0.035), xRadius: radius * 0.74, yRadius: radius * 0.74)
    NSColor(calibratedWhite: 1, alpha: 0.10).setFill()
    glassPath.fill()

    let lineColor = NSColor(calibratedWhite: 1, alpha: 0.88)
    let mutedLineColor = NSColor(calibratedWhite: 1, alpha: 0.42)
    let nodeFill = NSColor(calibratedWhite: 1, alpha: 0.96)

    func stroke(_ path: NSBezierPath, color: NSColor, width: CGFloat) {
        color.setStroke()
        path.lineWidth = width
        path.lineCapStyle = .round
        path.lineJoinStyle = .round
        path.stroke()
    }

    let arch = NSBezierPath()
    arch.move(to: point(0.20, 0.42, size: iconSize))
    arch.curve(
        to: point(0.80, 0.42, size: iconSize),
        controlPoint1: point(0.35, 0.75, size: iconSize),
        controlPoint2: point(0.65, 0.75, size: iconSize)
    )
    stroke(arch, color: lineColor, width: iconSize * 0.046)

    let deck = NSBezierPath()
    deck.move(to: point(0.18, 0.40, size: iconSize))
    deck.line(to: point(0.82, 0.40, size: iconSize))
    stroke(deck, color: lineColor, width: iconSize * 0.052)

    for x in [0.30, 0.39, 0.50, 0.61, 0.70] as [CGFloat] {
        let y = 0.42 + 0.30 * sin((x - 0.20) / 0.60 * .pi)
        let hanger = NSBezierPath()
        hanger.move(to: point(x, y, size: iconSize))
        hanger.line(to: point(x, 0.40, size: iconSize))
        stroke(hanger, color: mutedLineColor, width: iconSize * 0.018)
    }

    for x in [0.30, 0.70] as [CGFloat] {
        let tower = NSBezierPath()
        tower.move(to: point(x, 0.35, size: iconSize))
        tower.line(to: point(x, 0.71, size: iconSize))
        stroke(tower, color: lineColor, width: iconSize * 0.038)
    }

    let route = NSBezierPath()
    route.move(to: point(0.28, 0.30, size: iconSize))
    route.line(to: point(0.50, 0.21, size: iconSize))
    route.line(to: point(0.72, 0.30, size: iconSize))
    stroke(route, color: mutedLineColor, width: iconSize * 0.025)

    for (x, y, radiusScale) in [
        (0.18, 0.40, 0.030),
        (0.50, 0.21, 0.034),
        (0.82, 0.40, 0.030),
        (0.30, 0.71, 0.026),
        (0.70, 0.71, 0.026)
    ] as [(CGFloat, CGFloat, CGFloat)] {
        let radius = iconSize * radiusScale
        let rect = NSRect(x: x * iconSize - radius, y: y * iconSize - radius, width: radius * 2, height: radius * 2)
        let node = NSBezierPath(ovalIn: rect)
        nodeFill.setFill()
        node.fill()
    }

    return bitmap
}

func writePNG(size: Int, name: String) throws {
    let bitmap = try drawIcon(size: size)
    guard let pngData = bitmap.representation(using: .png, properties: [:]) else {
        throw NSError(domain: "BridgeportIcon", code: 1, userInfo: [NSLocalizedDescriptionKey: "Could not encode \(name)"])
    }
    try pngData.write(to: iconsetURL.appendingPathComponent(name), options: .atomic)
}

let iconFiles: [(Int, String)] = [
    (16, "icon_16x16.png"),
    (32, "icon_16x16@2x.png"),
    (32, "icon_32x32.png"),
    (64, "icon_32x32@2x.png"),
    (128, "icon_128x128.png"),
    (256, "icon_128x128@2x.png"),
    (256, "icon_256x256.png"),
    (512, "icon_256x256@2x.png"),
    (512, "icon_512x512.png"),
    (1024, "icon_512x512@2x.png")
]

for file in iconFiles {
    try writePNG(size: file.0, name: file.1)
}

let process = Process()
process.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
process.arguments = ["-c", "icns", iconsetURL.path, "-o", icnsURL.path]
try process.run()
process.waitUntilExit()

guard process.terminationStatus == 0 else {
    throw NSError(domain: "BridgeportIcon", code: Int(process.terminationStatus), userInfo: [NSLocalizedDescriptionKey: "iconutil failed"])
}

print(icnsURL.path)
