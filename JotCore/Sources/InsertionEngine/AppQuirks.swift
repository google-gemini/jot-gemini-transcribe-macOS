import Foundation

/// Per-app insertion behavior. Seeded from research; grows via the Insertion Lab.
public enum AppQuirks {
    /// Terminals and terminal-like apps: no editable AX text element — go straight
    /// to paste (Terminal/iTerm2 handle bracketed paste well).
    public static let forcePaste: Set<String> = [
        "com.apple.Terminal",
        "com.googlecode.iterm2",
        "dev.warp.Warp-Stable",
        "com.github.wez.wezterm",
        "com.mitchellh.ghostty",
        "net.kovidgoyal.kitty",
        "io.alacritty",
    ]

    /// Chromium/Electron apps: the accessibility tree must be woken with
    /// AXManualAccessibility before AX insertion has any chance
    /// (AXEnhancedUserInterface is VoiceOver-reserved and causes window moves).
    public static let needsManualAccessibility: Set<String> = [
        "com.tinyspeck.slackmacgap",
        "com.microsoft.VSCode",
        "com.todesktop.230313mzl4w4u92", // Cursor
        "com.exafunction.windsurf",
        "com.hnc.Discord",
        "com.anthropic.claudefordesktop",
        "com.google.Chrome",
        "com.microsoft.edgemac",
        "com.brave.Browser",
        "com.vivaldi.Vivaldi",
        "company.thebrowser.Browser", // Arc
        "com.microsoft.teams2",
        "org.whispersystems.signal-desktop",
        "com.spotify.client",
        "notion.id",
        "md.obsidian",
        "com.linear",
        "com.figma.Desktop",
    ]
}
