#!/usr/bin/env swift
//
// Draws Perch's icon, at every size macOS asks for.
//
//   swift apps/mac/Scripts/make-icon.swift        # writes Resources/AppIcon.icns
//
// Drawn rather than exported from a design tool, for the same reason the agent glyphs are:
// the mark is four shapes and a rule, and a rule scales. Every size is rendered from the
// same geometry in normalised units, so the 16pt icon is the 1024pt icon and not a
// downsampled photograph of it — the notch keeps its hairline, the bird keeps its pixels.
//
// The mark is the site's: the cutout hanging off the top edge of a display, with something
// perched to the left of it. Perched, because that is the name.

import AppKit
import Foundation

// MARK: - Palette
//
// Theme.swift and the site's tokens, restated: black surface, white ink, and Claude's own
// orange for the bird — the colour the app already uses for anything permission-related.

let surfaceTop = NSColor(srgbRed: 0.10, green: 0.10, blue: 0.11, alpha: 1)
let surfaceBottom = NSColor(srgbRed: 0.02, green: 0.02, blue: 0.02, alpha: 1)
let ink = NSColor.white
let edge = NSColor(white: 1, alpha: 0.30)
let bird = NSColor(srgbRed: 0.851, green: 0.467, blue: 0.341, alpha: 1)  // 0xD97757

/// The bird, as blocks — the same idea as `AgentGlyph`, which draws its creatures from
/// literal pixels so they stay crisp at any backing scale. Facing right, tail to the left,
/// standing on its two feet. Rows top to bottom; `#` is a pixel, `o` is the eye, punched
/// back out to the surface colour so the head reads as a head.
let birdPixels: [String] = [
    "...##...",
    "..####..",
    "..#o###>",
    ".######.",
    "#######.",
    "..####..",
    "..#..#..",
]

/// The same bird with everything that cannot survive a 1-pixel block taken out.
///
/// Below 48pt a block *is* one pixel, and the detailed grid is then 8 pixels wide next to a
/// 7-pixel notch — wider than the canvas, which is how the 16pt icon ended up with a bird
/// sliced off by its own left corner. A separate small grid is the ordinary answer: the
/// mark stays a bird on a ledge, it just stops claiming to have toes.
let birdPixelsSmall: [String] = [
    ".##..",
    ".####",
    "####.",
    ".#.#.",
]

// MARK: - Drawing

/// One icon, at `size` points. Everything is expressed as a fraction of the canvas, so this
/// is the only place a proportion is decided.
func draw(size: CGFloat, into context: CGContext) {
    let rect = CGRect(x: 0, y: 0, width: size, height: size)
    context.saveGState()

    // macOS rounds its own icons, but only for the ones it composites — a bundle icon
    // carries its own corners, and a square one looks like a mistake in the Dock.
    let radius = size * 0.2237
    let shape = CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius,
                       transform: nil)
    context.addPath(shape)
    context.clip()

    // A vertical gradient rather than a flat fill: at 1024pt a perfectly flat black reads
    // as a hole in the Dock rather than as a surface.
    let gradient = CGGradient(
        colorsSpace: CGColorSpaceCreateDeviceRGB(),
        colors: [surfaceTop.cgColor, surfaceBottom.cgColor] as CFArray,
        locations: [0, 1])!
    context.drawLinearGradient(
        gradient, start: CGPoint(x: 0, y: size), end: CGPoint(x: 0, y: 0), options: [])

    // The top edge of a display. It stops short of the sides so it reads as an edge rather
    // than as a border, and the notch interrupts it — which is the whole picture.
    //
    // Placed so the *group* — bird above the line, cutout below it — is optically centred.
    // Centring the line itself left the icon top-heavy with a third of it empty.
    let edgeY = size * 0.485
    let notchWidth = (size * 0.42).rounded()
    let notchHeight = size * 0.150
    let notchRadius = notchHeight * 0.46

    // The bird's geometry has to be settled before the notch is placed, because what gets
    // centred is the *pair*. Centring the notch and hanging the bird off its left is what
    // pushed the bird past the edge at 16pt — at that size a pixel block cannot shrink any
    // further, so the layout has to give instead.
    let pixels = size < 48 ? birdPixelsSmall : birdPixels
    let columns = CGFloat(pixels[0].count)
    let rows = CGFloat(pixels.count)
    let block = max(1, (size * 0.150 / columns).rounded())
    let birdWidth = block * columns
    let gap = max(1, (size * 0.03).rounded())

    let groupWidth = birdWidth + gap + notchWidth
    let birdX = ((size - groupWidth) / 2).rounded()
    let notchX = birdX + birdWidth + gap

    // The ledge overhangs the pair by the same amount at both ends. Fixed margins looked
    // accidental once the pair stopped being centred on the notch.
    let overhang = max(1, (size * 0.075).rounded())
    context.setStrokeColor(edge.cgColor)
    context.setLineWidth(max(1, size * 0.014))
    context.setLineCap(.round)
    context.move(to: CGPoint(x: birdX - overhang, y: edgeY))
    context.addLine(to: CGPoint(x: notchX, y: edgeY))
    context.strokePath()
    context.move(to: CGPoint(x: notchX + notchWidth, y: edgeY))
    context.addLine(to: CGPoint(x: notchX + notchWidth + overhang, y: edgeY))
    context.strokePath()

    // The cutout itself: square where it meets the edge, rounded where it hangs free.
    let notch = CGMutablePath()
    let bottom = edgeY - notchHeight
    notch.move(to: CGPoint(x: notchX, y: edgeY))
    notch.addLine(to: CGPoint(x: notchX, y: bottom + notchRadius))
    notch.addArc(tangent1End: CGPoint(x: notchX, y: bottom),
                 tangent2End: CGPoint(x: notchX + notchRadius, y: bottom), radius: notchRadius)
    notch.addLine(to: CGPoint(x: notchX + notchWidth - notchRadius, y: bottom))
    notch.addArc(tangent1End: CGPoint(x: notchX + notchWidth, y: bottom),
                 tangent2End: CGPoint(x: notchX + notchWidth, y: bottom + notchRadius),
                 radius: notchRadius)
    notch.addLine(to: CGPoint(x: notchX + notchWidth, y: edgeY))
    notch.closeSubpath()

    context.setFillColor(ink.cgColor)
    context.addPath(notch)
    context.fillPath()

    // The bird, perched on the edge to the left of the cutout. Pixel-aligned: a block is a
    // whole number of points, so nothing lands on a half pixel and blurs.
    let birdY = edgeY.rounded()  // its feet stand on the edge

    for (row, line) in pixels.enumerated() {
        for (column, character) in line.enumerated() where character != "." {
            // The eye is the surface showing through, which is why it is drawn after the
            // body rather than left out of it.
            context.setFillColor(character == "o" ? surfaceTop.cgColor : bird.cgColor)
            context.fill(
                CGRect(
                    x: birdX + CGFloat(column) * block,
                    // Rows read top to bottom; the context's y grows upward.
                    y: birdY + (rows - CGFloat(row) - 1) * block,
                    width: block, height: block))
        }
    }

    context.restoreGState()
}

func png(size: Int) -> Data {
    let representation = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    representation.size = NSSize(width: size, height: size)

    NSGraphicsContext.saveGraphicsState()
    let graphics = NSGraphicsContext(bitmapImageRep: representation)!
    NSGraphicsContext.current = graphics
    draw(size: CGFloat(size), into: graphics.cgContext)
    NSGraphicsContext.restoreGraphicsState()

    return representation.representation(using: .png, properties: [:])!
}

// MARK: - Output

let scriptDirectory = URL(fileURLWithPath: CommandLine.arguments[0])
    .deletingLastPathComponent()
let resources = scriptDirectory.deletingLastPathComponent()
    .appendingPathComponent("Resources")
let iconset = resources.appendingPathComponent("AppIcon.iconset")

try? FileManager.default.removeItem(at: iconset)
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)

// The names `iconutil` expects. Both scales of each size, because a Retina Mac asked for
// the @2x file and an external display asked for the other one.
for (size, name) in [
    (16, "icon_16x16"), (32, "icon_16x16@2x"),
    (32, "icon_32x32"), (64, "icon_32x32@2x"),
    (128, "icon_128x128"), (256, "icon_128x128@2x"),
    (256, "icon_256x256"), (512, "icon_256x256@2x"),
    (512, "icon_512x512"), (1024, "icon_512x512@2x"),
] {
    try png(size: size).write(to: iconset.appendingPathComponent("\(name).png"))
}

let convert = Process()
convert.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
convert.arguments = [
    "-c", "icns", iconset.path,
    "-o", resources.appendingPathComponent("AppIcon.icns").path,
]
try convert.run()
convert.waitUntilExit()
guard convert.terminationStatus == 0 else { exit(convert.terminationStatus) }

// The iconset is scaffolding; the .icns is the artifact.
try FileManager.default.removeItem(at: iconset)
print("wrote \(resources.appendingPathComponent("AppIcon.icns").path)")
