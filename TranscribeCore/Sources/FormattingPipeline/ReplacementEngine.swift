import Foundation

/// Deterministic post-model replacement layer (§3.7): the dictionary's guarantee.
/// The cleanup prompt *suggests* spellings to the model; this layer *enforces* the
/// explicit wrong→right rules afterward. Longest-match-first, word-boundary,
/// case-preserving (ALL-CAPS / Title / lower propagation).
public enum ReplacementEngine {
    public struct Rule: Codable, Equatable, Sendable {
        public var wrong: String
        public var right: String

        public init(wrong: String, right: String) {
            self.wrong = wrong
            self.right = right
        }
    }

    public static func apply(_ rules: [Rule], to text: String) -> String {
        guard !rules.isEmpty else { return text }
        var result = text
        // Longest wrong-form first so "google transcribe" wins over "google".
        for rule in rules.sorted(by: { $0.wrong.count > $1.wrong.count }) {
            guard !rule.wrong.isEmpty else { continue }
            // Lookarounds instead of \b: word boundaries silently never match when
            // the wrong form starts/ends with punctuation ("e.g.", "c++") (audit L21).
            let pattern = "(?<![\\w])\(NSRegularExpression.escapedPattern(for: rule.wrong))(?![\\w])"
            guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { continue }
            let matches = regex.matches(in: result, range: NSRange(result.startIndex..., in: result)).reversed()
            for match in matches {
                guard let range = Range(match.range, in: result) else { continue }
                let original = String(result[range])
                result.replaceSubrange(range, with: propagateCase(from: original, to: rule.right, wrong: rule.wrong))
            }
        }
        return result
    }

    /// "KUBERNETES"→"GRPC" stays caps; "Kubernetes"→"GRPC"… follows the rule's
    /// canonical casing unless the match was ALL-CAPS or the rule carries
    /// EXPLICIT casing. A rule is explicitly cased when its right side contains
    /// uppercase (gRPC, iPhone) — or when its WRONG side does ("NPM"→"npm" is a
    /// deliberate lowercase rule; ALL-CAPS propagation would silently undo it).
    static func propagateCase(from original: String, to replacement: String, wrong: String = "") -> String {
        let hasExplicitCasing = replacement.dropFirst().contains(where: { $0.isUppercase })
            || replacement.first?.isUppercase == true
            || wrong.contains(where: { $0.isUppercase })
            || (!wrong.isEmpty && wrong.lowercased() == replacement.lowercased())
        if hasExplicitCasing {
            return replacement // dictionary term carries its own casing (gRPC, iPhone)
        }
        if original == original.uppercased(), original.count > 1 {
            return replacement.uppercased()
        }
        if original.first?.isUppercase == true {
            return replacement.prefix(1).uppercased() + replacement.dropFirst()
        }
        return replacement
    }
}
