import AppKit
import CoreText
import TranscribeCore

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
