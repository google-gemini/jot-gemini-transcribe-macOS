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

import JotCore
import SwiftUI

/// Shows the edit, not just the result.
///
/// Ported from the landing page's "You said" chip, and for the same reason: the
/// cleaned sentence on its own looks like the user simply spoke well. Watching
/// "umm, so" and "1pm — actually, no, make it" get struck out and then close up
/// is what makes it obvious the model did something.
///
/// Two beats, in the site's order and on its curves:
///
///  1. **Mark.** The removed runs turn red and gain a strikethrough, held long
///     enough to actually read what is going.
///  2. **Collapse.** They shrink to zero width and fade, so the sentence closes
///     up around them and settles as the clean version.
///
/// Beat 1 exists solely to be legible; going straight to the collapse would look
/// like a glitch rather than an edit.
struct CorrectionView: View {

    let segments: [TranscriptDiff.Segment]

    @State private var marked = false
    @State private var collapsed = false

    /// `.q .cut.is-marked { color: var(--chip-cut) }` — the site's cut red.
    private static let cutInk = Color(red: 0xC5 / 255, green: 0x22 / 255, blue: 0x1F / 255)

    /// Long enough to read a few words before they go. The site holds 780ms
    /// between marking and collapsing.
    static let markHold: TimeInterval = 0.78
    /// `max-width .5s cubic-bezier(.3,0,.2,1)`
    static let collapse: TimeInterval = 0.5
    /// What the whole thing costs, for callers that must hold the pill open.
    static var total: TimeInterval { markHold + collapse }

    var body: some View {
        // The row keeps its natural width so the cut runs have a real width to
        // collapse FROM — .fixedSize is what makes the close-up animate at all.
        // But natural width on a long sentence is wider than the pill, and
        // without a clip it draws straight out over the surface and past it.
        // So: let the row size itself, then clip it to the pill and anchor it
        // trailing, which keeps the newest words visible exactly like
        // .truncationMode(.head) does for the plain text.
        row
            .fixedSize(horizontal: true, vertical: false)
            .frame(maxWidth: .infinity, alignment: .trailing)
            .clipped()
            // Softens the left edge so the sentence looks like it continues
            // rather than being chopped mid-letter.
            .mask(
                LinearGradient(
                    stops: [
                        .init(color: .clear, location: 0),
                        .init(color: .black, location: 0.06),
                        .init(color: .black, location: 1),
                    ],
                    startPoint: .leading, endPoint: .trailing
                )
            )
    }

    private var row: some View {
        HStack(spacing: 0) {
            ForEach(Array(segments.enumerated()), id: \.offset) { _, segment in
                if segment.isCut {
                    Text(segment.text)
                        .foregroundStyle(marked ? Self.cutInk : JotUI.Colors.onSurfaceVariant)
                        .strikethrough(marked, color: Self.cutInk)
                        // Collapsing horizontally is what makes the sentence
                        // close up. Fading alone would leave a hole where the
                        // words were.
                        .fixedSize()
                        .frame(maxWidth: collapsed ? 0 : nil)
                        .opacity(collapsed ? 0 : 1)
                        .clipped()
                } else {
                    Text(segment.text)
                        .foregroundStyle(JotUI.Colors.onSurfaceVariant)
                        .fixedSize()
                }
            }
        }
        .font(JotUI.TypeScale.labelSmall())
        .lineLimit(1)
        .onAppear { run() }
        // VoiceOver gets the finished sentence once, not a sequence of edits.
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(segments.filter { !$0.isCut }.map(\.text).joined())
    }

    private func run() {
        guard !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else {
            // The edit still reads — it simply does not animate.
            marked = true
            collapsed = true
            return
        }
        withAnimation(.easeOut(duration: 0.25)) { marked = true }
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.markHold) {
            withAnimation(.timingCurve(0.3, 0, 0.2, 1, duration: Self.collapse)) {
                collapsed = true
            }
        }
    }
}
