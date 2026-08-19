import Foundation

/// Every outbound link in one place, so the About panel, the Settings pane and
/// the docs can never drift apart.
enum JotLinks {
    static let author = URL(string: "https://x.com/ammaar")!
    static let repository = URL(string: "https://github.com/ammaarreshi/jot")!
    static let issues = URL(string: "https://github.com/ammaarreshi/jot/issues")!
    static let privacy = URL(string: "https://github.com/ammaarreshi/jot/blob/main/docs/PRIVACY.md")!
}
