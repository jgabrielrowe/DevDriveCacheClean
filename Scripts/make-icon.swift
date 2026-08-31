#!/usr/bin/env swift
//
// Builds Resources/AppIcon.icns from Resources/AppIcon.png.
//
// The source art is a full-bleed square. macOS expects an app icon to be a
// rounded rect inset inside a transparent canvas — the Dock, Finder and the
// app switcher all lay out against that grid, so a full-bleed square renders
// visibly larger and harder-edged than every neighbouring app. This script
// applies Apple's proportions: an 824pt body on a 1024pt canvas with a 185.4pt
// corner radius, scaled to each icon size.
//
// The generated .icns is committed, so a fresh clone builds an icon without a
// toolchain step. Re-run this only when the source art changes.
//
// Usage: Scripts/make-icon.swift [source.png] [output.icns]

import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

// Apple's macOS icon grid, expressed against a 1024pt canvas.
private let canvasReference: CGFloat = 1024
private let bodyReference: CGFloat = 824
private let cornerReference: CGFloat = 185.4

/// Every representation `iconutil` expects, as (filename, pixel size). Sizes
/// repeat because a 32pt icon is both `icon_32x32` and `icon_16x16@2x`; the
/// bitmaps are identical but both names must be present or `iconutil` fails.
private let representations: [(name: String, pixels: Int)] = [
    ("icon_16x16", 16), ("icon_16x16@2x", 32),
    ("icon_32x32", 32), ("icon_32x32@2x", 64),
    ("icon_128x128", 128), ("icon_128x128@2x", 256),
    ("icon_256x256", 256), ("icon_256x256@2x", 512),
    ("icon_512x512", 512), ("icon_512x512@2x", 1024),
]

private func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("error: \(message)\n".utf8))
    exit(1)
}

private func loadImage(at path: String) -> CGImage {
    let url = URL(fileURLWithPath: path)
    guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
          let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
        fail("could not read an image from \(path)")
    }
    guard image.width == image.height else {
        fail("source art must be square, got \(image.width)x\(image.height)")
    }
    return image
}

/// Draws `source` scaled into the rounded-rect body, centred on a transparent
/// canvas of `pixels` square. Clipping happens before the draw so the art is
/// scaled once, at full resolution, rather than masked after resampling.
private func render(_ source: CGImage, at pixels: Int) -> CGImage {
    let canvas = CGFloat(pixels)
    let scale = canvas / canvasReference
    let body = bodyReference * scale
    let radius = cornerReference * scale
    let inset = (canvas - body) / 2

    guard let space = CGColorSpace(name: CGColorSpace.sRGB),
          let context = CGContext(
            data: nil,
            width: pixels,
            height: pixels,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: space,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
          ) else {
        fail("could not create a \(pixels)x\(pixels) bitmap context")
    }

    context.interpolationQuality = .high
    let rect = CGRect(x: inset, y: inset, width: body, height: body)
    context.addPath(
        CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil)
    )
    context.clip()
    context.draw(source, in: rect)

    guard let image = context.makeImage() else {
        fail("could not render the \(pixels)x\(pixels) representation")
    }
    return image
}

private func writePNG(_ image: CGImage, to url: URL) {
    guard let destination = CGImageDestinationCreateWithURL(
        url as CFURL, UTType.png.identifier as CFString, 1, nil
    ) else {
        fail("could not open \(url.path) for writing")
    }
    CGImageDestinationAddImage(destination, image, nil)
    guard CGImageDestinationFinalize(destination) else {
        fail("could not write \(url.path)")
    }
}

// MARK: - Main

let arguments = CommandLine.arguments
let sourcePath = arguments.count > 1 ? arguments[1] : "Resources/AppIcon.png"
let outputPath = arguments.count > 2 ? arguments[2] : "Resources/AppIcon.icns"

let source = loadImage(at: sourcePath)

let iconset = URL(fileURLWithPath: NSTemporaryDirectory())
    .appending(path: "DDCCAppIcon.iconset", directoryHint: .isDirectory)
try? FileManager.default.removeItem(at: iconset)
do {
    try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
} catch {
    fail("could not create \(iconset.path): \(error.localizedDescription)")
}
defer { try? FileManager.default.removeItem(at: iconset) }

// Render each distinct pixel size once and reuse it for both names.
var rendered: [Int: CGImage] = [:]
for (name, pixels) in representations {
    let image = rendered[pixels] ?? render(source, at: pixels)
    rendered[pixels] = image
    writePNG(image, to: iconset.appending(path: "\(name).png", directoryHint: .notDirectory))
}

let iconutil = Process()
iconutil.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
iconutil.arguments = ["--convert", "icns", "--output", outputPath, iconset.path]
do {
    try iconutil.run()
} catch {
    fail("could not run iconutil: \(error.localizedDescription)")
}
iconutil.waitUntilExit()
guard iconutil.terminationStatus == 0 else {
    fail("iconutil exited with status \(iconutil.terminationStatus)")
}

print("wrote \(outputPath) from \(sourcePath)")
