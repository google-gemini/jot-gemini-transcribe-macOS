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
import CoreText
import JotCore

enum FontLoader {
    /// Registers the bundled variable fonts for this process. Call before any UI.
    static func registerBundledFonts() {
        let fontURLs = (Bundle.main.urls(forResourcesWithExtension: "ttf", subdirectory: "Fonts/GoogleSansFlex") ?? [])
            + (Bundle.main.urls(forResourcesWithExtension: "ttf", subdirectory: "Fonts/GoogleSansCode") ?? [])

        guard !fontURLs.isEmpty else {
            Log.ui.error("FontLoader: no bundled .ttf files found — falling back to system fonts")
            return
        }

        for url in fontURLs {
            var cfError: Unmanaged<CFError>?
            if !CTFontManagerRegisterFontsForURL(url as CFURL, .process, &cfError) {
                let description = (cfError?.takeRetainedValue()).map(String.init(describing:)) ?? "unknown error"
                // kCTFontManagerErrorAlreadyRegistered is benign on relaunch-in-place.
                Log.ui.warning("FontLoader: could not register \(url.lastPathComponent, privacy: .public): \(description, privacy: .public)")
            } else {
                Log.ui.info("FontLoader: registered \(url.lastPathComponent, privacy: .public)")
            }
        }
    }
}
