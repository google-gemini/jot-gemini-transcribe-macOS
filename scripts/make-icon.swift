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

// Generates App/Resources/Jot.icns from code — the icon is drawn, not stored, so
// it can be tweaked in one place and regenerated. Run: swift scripts/make-icon.swift
//
// Design: the menu-bar mark (a speech pill holding a waveform) blown up onto a
// deep-blue squircle. Deliberately NOT the four Google colors: this is a personal
// project by a Googler, and the icon must not imply Google endorsement.

let canvas: CGFloat = 1024
// macOS Big Sur+ grid: the rounded square occupies ~824pt of a 1024pt canvas.
let plateSize: CGFloat = 824
let plateOrigin = (canvas - plateSize) / 2

/// Apple-style squircle (superellipse) rather than a plain rounded rect.
func squircle(in rect: CGRect, n: CGFloat = 5) -> NSBezierPath {
    let path = NSBezierPath()
    let a = rect.width / 2, b = rect.height / 2
    let cx = rect.midX, cy = rect.midY
    let steps = 720
    for i in 0...steps {
        let t = CGFloat(i) / CGFloat(steps) * 2 * .pi
        let ct = cos(t), st = sin(t)
        let x = cx + a * CGFloat(sign(ct)) * pow(abs(ct), 2 / n)
        let y = cy + b * CGFloat(sign(st)) * pow(abs(st), 2 / n)
        if i == 0 { path.move(to: CGPoint(x: x, y: y)) } else { path.line(to: CGPoint(x: x, y: y)) }
    }
    path.close()
    return path
}

func sign(_ v: CGFloat) -> CGFloat { v < 0 ? -1 : 1 }

let image = NSImage(size: NSSize(width: canvas, height: canvas), flipped: false) { _ in
    guard let ctx = NSGraphicsContext.current?.cgContext else { return false }
    let plate = CGRect(x: plateOrigin, y: plateOrigin, width: plateSize, height: plateSize)
    let shape = squircle(in: plate)

    // NO baked drop shadow: macOS composites its own, and a shadow painted into
    // the artwork shows up as a grey halo on light backgrounds (it did — in the
    // About pane).

    // Body: blue → indigo, light from the top.
    ctx.saveGState()
    shape.addClip()
    let gradient = NSGradient(colors: [
        NSColor(srgbRed: 0.35, green: 0.60, blue: 0.99, alpha: 1),
        NSColor(srgbRed: 0.16, green: 0.36, blue: 0.90, alpha: 1),
        NSColor(srgbRed: 0.11, green: 0.22, blue: 0.72, alpha: 1),
    ], atLocations: [0, 0.55, 1], colorSpace: .sRGB)!
    gradient.draw(in: plate, angle: -90)

    // Soft top highlight so the plate reads as a physical surface.
    let highlight = NSGradient(colors: [
        NSColor.white.withAlphaComponent(0.30),
        NSColor.white.withAlphaComponent(0.0),
    ])!
    highlight.draw(in: CGRect(x: plate.minX, y: plate.midY, width: plate.width, height: plate.height / 2), angle: -90)
    ctx.restoreGState()

    // The mark: a speech pill with a waveform inside, centred on the plate.
    let pillWidth = plateSize * 0.66
    let pillHeight = plateSize * 0.44
    let pillRect = CGRect(
        x: plate.midX - pillWidth / 2,
        y: plate.midY - pillHeight / 2,
        width: pillWidth, height: pillHeight
    )
    let pill = NSBezierPath(roundedRect: pillRect,
                            xRadius: pillHeight / 2, yRadius: pillHeight / 2)
    pill.lineWidth = plateSize * 0.055
    pill.lineJoinStyle = .round
    NSColor.white.setStroke()
    pill.stroke()
    // No speech tail: the bare pill IS the product's mark — the same shape the
    // HUD shows at the bottom of the screen while you talk.

    // Waveform: five bars, the same rhythm as the menu-bar glyph's listening frame.
    let barHeights: [CGFloat] = [0.34, 0.62, 0.88, 0.58, 0.30]
    let barWidth = plateSize * 0.045
    let gap = plateSize * 0.033
    let totalWidth = CGFloat(barHeights.count) * barWidth + CGFloat(barHeights.count - 1) * gap
    var x = pillRect.midX - totalWidth / 2
    for fraction in barHeights {
        let height = pillHeight * 0.52 * fraction + barWidth
        let bar = NSBezierPath(
            roundedRect: CGRect(x: x, y: pillRect.midY - height / 2, width: barWidth, height: height),
            xRadius: barWidth / 2, yRadius: barWidth / 2
        )
        NSColor.white.setFill()
        bar.fill()
        x += barWidth + gap
    }
    return true
}

// Write the iconset and convert.
let fm = FileManager.default
let root = URL(fileURLWithPath: fm.currentDirectoryPath)
let iconset = root.appendingPathComponent("build/Jot.iconset")
try? fm.removeItem(at: iconset)
try! fm.createDirectory(at: iconset, withIntermediateDirectories: true)

let variants: [(Int, Int)] = [(16, 1), (16, 2), (32, 1), (32, 2), (128, 1), (128, 2),
                              (256, 1), (256, 2), (512, 1), (512, 2)]
for (point, scale) in variants {
    let pixels = point * scale
    let target = NSImage(size: NSSize(width: pixels, height: pixels))
    target.lockFocus()
    NSGraphicsContext.current?.imageInterpolation = .high
    image.draw(in: CGRect(x: 0, y: 0, width: pixels, height: pixels))
    target.unlockFocus()
    guard let tiff = target.tiffRepresentation,
          let bitmap = NSBitmapImageRep(data: tiff),
          let png = bitmap.representation(using: .png, properties: [:]) else { continue }
    let name = scale == 1 ? "icon_\(point)x\(point).png" : "icon_\(point)x\(point)@2x.png"
    try! png.write(to: iconset.appendingPathComponent(name))
}

let out = root.appendingPathComponent("App/Resources/Jot.icns")
let convert = Process()
convert.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
convert.arguments = ["-c", "icns", iconset.path, "-o", out.path]
try! convert.run()
convert.waitUntilExit()
print(convert.terminationStatus == 0 ? "wrote \(out.path)" : "iconutil failed")
