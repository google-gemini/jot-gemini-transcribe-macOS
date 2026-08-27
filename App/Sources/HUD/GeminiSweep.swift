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

import SwiftUI

/// The Gemini gradient sweeping once across text, then settling into ink.
///
/// This is the moment the live transcript stops being a guess: the interim text
/// the model was revising is replaced by its finished, formatted answer, and the
/// sweep is what says "that just changed, and something did it on purpose"
/// without a spinner or a label.
///
/// Ported from the landing page, deliberately to the same numbers so the site and
/// the app describe the same product: a 100° four-stop gradient at 260% width,
/// swept from 140% to -20% over 1.5s on cubic-bezier(.3,.5,.2,1), then cleared.
///
/// **This is the only place the Gemini gradient appears** — in the app as on the
/// site. It reads as a signal precisely because nothing else uses it; spend it
/// twice and it becomes decoration.
struct GeminiSweep: ViewModifier {

    /// Changing this value runs the sweep once.
    let trigger: String

    /// The four stops from the site, in order, with blue repeated so the sweep
    /// enters and leaves on the same colour and has no visible seam.
    private static let stops: [Color] = [
        Color(red: 0x42 / 255, green: 0x85 / 255, blue: 0xF4 / 255),  // #4285F4
        Color(red: 0x9B / 255, green: 0x72 / 255, blue: 0xCB / 255),  // #9B72CB
        Color(red: 0xD9 / 255, green: 0x65 / 255, blue: 0x70 / 255),  // #D96570
        Color(red: 0x42 / 255, green: 0x85 / 255, blue: 0xF4 / 255),  // #4285F4
    ]

    private static let duration: TimeInterval = 1.5

    @State private var phase: CGFloat = 1.4      // background-position: 140%
    @State private var sweeping = false

    func body(content: Content) -> some View {
        content
            .overlay {
                if sweeping {
                    GeometryReader { proxy in
                        LinearGradient(
                            colors: Self.stops,
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                        // 260% of the text's width, so only part of the gradient
                        // is over the glyphs at any instant — that is what makes
                        // it read as a sweep rather than a colour change.
                        .frame(width: proxy.size.width * 2.6)
                        .offset(x: phase * proxy.size.width)
                        .mask(content)
                    }
                    .allowsHitTesting(false)
                }
            }
            .onChange(of: trigger) { _, newValue in
                guard !newValue.isEmpty else { return }
                run()
            }
            .onAppear {
                if !trigger.isEmpty { run() }
            }
    }

    private func run() {
        // Respect the system setting, exactly as the site respects
        // prefers-reduced-motion: the correction still lands, it just does not
        // travel.
        guard !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else {
            sweeping = false
            return
        }
        phase = 1.4
        sweeping = true
        withAnimation(.timingCurve(0.3, 0.5, 0.2, 1.0, duration: Self.duration)) {
            phase = -0.2                          // background-position: -20%
        }
        // Then it settles into ink — the site removes the class rather than
        // leaving the gradient parked over the text.
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.duration) {
            sweeping = false
        }
    }
}

extension View {
    /// Sweeps the Gemini gradient across this view once whenever `trigger`
    /// changes to a non-empty value.
    func geminiSweep(trigger: String) -> some View {
        modifier(GeminiSweep(trigger: trigger))
    }
}
