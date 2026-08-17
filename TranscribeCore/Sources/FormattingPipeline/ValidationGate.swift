import Foundation

/// The "never insert garbage" gate (<1ms, runs between cleanup and insertion).
///
/// Defends against the documented failure modes of prompted cleanup models
/// (OpenWhispr #833, brainwave #17): answering the dictation instead of cleaning
/// it, paraphrase drift, hallucinated expansion, and content-dropping. Because the
/// transcribe model gives us a true raw reference, this is the strong two-call
/// gate from the product spec. On rejection the caller inserts the raw transcript
/// (which already has punctuation — high-quality fallback).
public enum ValidationGate {
    public struct Verdict: Equatable, Sendable {
        public let accepted: Bool
        public let reason: String?
        static let ok = Verdict(accepted: true, reason: nil)
        static func fail(_ reason: String) -> Verdict { Verdict(accepted: false, reason: reason) }
    }

    // Tuned against the live probe fixtures (see ValidationGateTests). Constants
    // deliberately generous: self-correction collapse legitimately halves a
    // transcript; answer-mode diverges in *content*, which containment catches.
    static let minLengthRatio = 0.20
    static let maxLengthRatio = 1.60
    static let minContainment = 0.50
    static let minTrigramSimilarity = 0.55

    /// Strips model artifacts that are not failures: code fences, "CLEAN:"/"Transcript:"
    /// labels, wrapping quotes.
    public static func stripArtifacts(_ text: String) -> String {
        var s = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.hasPrefix("```") {
            s = s.replacingOccurrences(of: "```[a-z]*\n?", with: "", options: .regularExpression)
            s = s.replacingOccurrences(of: "```", with: "")
            s = s.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        for label in ["CLEAN:", "Clean:", "Transcript:", "TRANSCRIPT:"] where s.hasPrefix(label) {
            s = String(s.dropFirst(label.count)).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if s.count > 1, s.hasPrefix("\""), s.hasSuffix("\"") {
            s = String(s.dropFirst().dropLast())
        }
        return s
    }

    public static func validate(raw: String, cleaned: String) -> Verdict {
        let rawWords = contentWords(of: raw)
        let cleanWords = contentWords(of: cleaned)

        if cleanWords.isEmpty {
            return rawWords.isEmpty ? .ok : .fail("empty_output")
        }
        if answerPattern.firstMatch(in: cleaned, range: NSRange(cleaned.startIndex..., in: cleaned)) != nil {
            return .fail("answer_pattern")
        }
        guard !rawWords.isEmpty else { return .ok }

        let ratio = Double(cleanWords.count) / Double(rawWords.count)
        // Expansion is most dangerous on short raws (hallucinated content), so the
        // upper bound kicks in early; shrink is legitimate (filler/self-correction
        // collapse), so the lower bound only applies to longer raws.
        if rawWords.count >= 3, ratio > maxLengthRatio {
            return .fail("expansion_ratio_\(String(format: "%.2f", ratio))")
        }
        if rawWords.count >= 6, ratio < minLengthRatio {
            return .fail("shrink_ratio_\(String(format: "%.2f", ratio))")
        }

        let rawSet = Set(rawWords)
        let contained = cleanWords.filter { rawSet.contains($0) }.count
        let containment = Double(contained) / Double(cleanWords.count)
        let trigram = trigramSimilarity(normalize(raw), normalize(cleaned))
        // Reject only when BOTH content signals diverge — cleanup legitimately
        // rewrites number words and punctuation words, hurting each individually.
        if containment < minContainment && trigram < minTrigramSimilarity {
            return .fail("content_divergence_c\(String(format: "%.2f", containment))_t\(String(format: "%.2f", trigram))")
        }
        return .ok
    }

    // MARK: - Text plumbing

    private static let answerPattern = try! NSRegularExpression(
        pattern: #"^(sure|okay|certainly|of course|great question|here('s| is)|i can('|no)t|as an ai|i'm (sorry|an ai))\b"#,
        options: [.caseInsensitive]
    )

    /// Lowercased alphanumeric words with spoken numbers normalized to digits so
    /// "three" (raw) matches "3" (cleaned ITN output).
    static func contentWords(of text: String) -> [String] {
        normalize(text)
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
    }

    static func normalize(_ text: String) -> String {
        var s = text.lowercased()
        for (word, digit) in numberWords {
            s = s.replacingOccurrences(of: "\\b\(word)\\b", with: digit, options: .regularExpression)
        }
        return s
    }

    private static let numberWords: [(String, String)] = [
        ("zero", "0"), ("one", "1"), ("two", "2"), ("three", "3"), ("four", "4"),
        ("five", "5"), ("six", "6"), ("seven", "7"), ("eight", "8"), ("nine", "9"),
        ("ten", "10"), ("eleven", "11"), ("twelve", "12"), ("twenty", "20"),
        ("thirty", "30"), ("forty", "40"), ("fifty", "50"), ("hundred", "100"),
    ]

    static func trigramSimilarity(_ a: String, _ b: String) -> Double {
        let ta = trigrams(a), tb = trigrams(b)
        guard !ta.isEmpty, !tb.isEmpty else { return a == b ? 1 : 0 }
        let intersection = ta.intersection(tb).count
        return Double(intersection) / Double(min(ta.count, tb.count))
    }

    private static func trigrams(_ s: String) -> Set<String> {
        let chars = Array(s.filter { !$0.isWhitespace })
        guard chars.count >= 3 else { return chars.isEmpty ? [] : [String(chars)] }
        var set = Set<String>()
        for i in 0...(chars.count - 3) {
            set.insert(String(chars[i...(i + 2)]))
        }
        return set
    }
}
