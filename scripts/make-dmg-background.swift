#!/usr/bin/env swift
// Copyright 2026 Google LLC
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//     https://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.

import AppKit
import Foundation

// Draws the installer window's backdrop: build/dmg-background.png (+ @2x).
// Finder places the app and the Applications alias ON TOP of this, at the
// coordinates scripts/make-dmg.sh sets — so this art deliberately leaves the
// two icon spots EMPTY. Nothing decorative goes behind an icon; plinths and
// glows only muddy them.

let width: CGFloat = 700
let height: CGFloat = 460
// Icon centres, in drawing coordinates (origin bottom-left).
let appSpot = CGPoint(x: 190, y: 215)
let folderSpot = CGPoint(x: 510, y: 215)

func render(scale: CGFloat) -> Data? {
    guard let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: Int(width * scale), pixelsHigh: Int(height * scale),
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
    ) else { return nil }
    rep.size = NSSize(width: width, height: height)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    defer { NSGraphicsContext.restoreGraphicsState() }

    // One quiet wash. The app icon is the only saturated thing in the window.
    NSGradient(colors: [
        NSColor(srgbRed: 0.988, green: 0.991, blue: 1.0, alpha: 1),
        NSColor(srgbRed: 0.918, green: 0.937, blue: 0.980, alpha: 1),
    ])!.draw(in: CGRect(x: 0, y: 0, width: width, height: height), angle: -90)

    let centered = NSMutableParagraphStyle()
    centered.alignment = .center

    // Wordmark + promise.
    NSAttributedString(string: "Jot", attributes: [
        .font: NSFont.systemFont(ofSize: 40, weight: .semibold),
        .foregroundColor: NSColor(srgbRed: 0.07, green: 0.11, blue: 0.24, alpha: 1),
        .paragraphStyle: centered,
    ]).draw(in: CGRect(x: 0, y: height - 96, width: width, height: 52))

    NSAttributedString(string: "Hold a key. Speak. It types.", attributes: [
        .font: NSFont.systemFont(ofSize: 15, weight: .regular),
        .foregroundColor: NSColor(srgbRed: 0.35, green: 0.40, blue: 0.50, alpha: 1),
        .paragraphStyle: centered,
    ]).draw(in: CGRect(x: 0, y: height - 124, width: width, height: 24))

    // A single chevron between the two icons: the whole instruction, no clutter.
    let midX = (appSpot.x + folderSpot.x) / 2
    let chevron = NSBezierPath()
    chevron.move(to: CGPoint(x: midX - 9, y: appSpot.y + 13))
    chevron.line(to: CGPoint(x: midX + 8, y: appSpot.y))
    chevron.line(to: CGPoint(x: midX - 9, y: appSpot.y - 13))
    chevron.lineWidth = 4
    chevron.lineCapStyle = .round
    chevron.lineJoinStyle = .round
    NSColor(srgbRed: 0.55, green: 0.61, blue: 0.75, alpha: 1).setStroke()
    chevron.stroke()

    NSAttributedString(string: "Drag Jot into your Applications folder", attributes: [
        .font: NSFont.systemFont(ofSize: 13, weight: .medium),
        .foregroundColor: NSColor(srgbRed: 0.30, green: 0.36, blue: 0.48, alpha: 1),
        .paragraphStyle: centered,
    ]).draw(in: CGRect(x: 0, y: 96, width: width, height: 20))

    // The disclaimer belongs where every installer sees it.
    NSAttributedString(
        string: "Open source (Apache 2.0) · Not an officially supported Google product · Brings your own Gemini API key",
        attributes: [
            .font: NSFont.systemFont(ofSize: 10.5, weight: .regular),
            .foregroundColor: NSColor(srgbRed: 0.52, green: 0.56, blue: 0.65, alpha: 1),
            .paragraphStyle: centered,
        ]
    ).draw(in: CGRect(x: 0, y: 34, width: width, height: 16))

    return rep.representation(using: .png, properties: [:])
}

let out = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("build")
try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
if let one = render(scale: 1) { try! one.write(to: out.appendingPathComponent("dmg-background.png")) }
if let two = render(scale: 2) { try! two.write(to: out.appendingPathComponent("dmg-background@2x.png")) }
print("wrote build/dmg-background.png (+@2x)")
