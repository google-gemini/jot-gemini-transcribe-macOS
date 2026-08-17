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
            let pattern = "\\b\(NSRegularExpression.escapedPattern(for: rule.wrong))\\b"
            guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { continue }
            let matches = regex.matches(in: result, range: NSRange(result.startIndex..., in: result)).reversed()
            for match in matches {
                guard let range = Range(match.range, in: result) else { continue }
                let original = String(result[range])
                result.replaceSubrange(range, with: propagateCase(from: original, to: rule.right))
            }
        }
        return result
    }

    /// "KUBERNETES"→"GRPC" stays caps; "Kubernetes"→"GRPC"… follows the rule's
    /// canonical casing unless the match was ALL-CAPS or the rule's right side is
    /// explicitly cased (contains uppercase beyond position 0 — e.g. "gRPC").
    static func propagateCase(from original: String, to replacement: String) -> String {
        let hasExplicitCasing = replacement.dropFirst().contains(where: { $0.isUppercase })
            || replacement.first?.isUppercase == true
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
