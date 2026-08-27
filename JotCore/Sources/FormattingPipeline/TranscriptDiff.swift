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

import Foundation

/// Works out which words smart transcription removed, so the HUD can show the
/// edit rather than just the result.
///
/// Live mode gives us both halves for free: the interim hypothesis is close to
/// what was literally said, and the final is the cleaned version. The difference
/// between them is the fillers, stutters and self-corrections the model took out
/// — "umm, so let's meet at 1pm, actually no, make it 2pm" becoming "Let's meet
/// at 2pm". Showing that edit is far more convincing than showing only the tidy
/// answer, because the tidy answer alone looks like the user simply spoke well.
public enum TranscriptDiff {

    public struct Segment: Equatable, Sendable {
        public let text: String
        /// True when this word exists in what was said but not in what was kept.
        public let isCut: Bool

        public init(text: String, isCut: Bool) {
            self.text = text
            self.isCut = isCut
        }
    }

    /// Splits `verbatim` into kept and cut runs, aligned against `cleaned`.
    ///
    /// Returns a single kept segment when there is nothing useful to show —
    /// no overlap at all, or an empty side. A diff that marks the entire sentence
    /// as removed is not an insight, it is a bug rendered at full size, so it
    /// fails to "no edit" rather than to something dramatic.
    public static func segments(verbatim: String, cleaned: String) -> [Segment] {
        let saidTokens = tokenize(verbatim)
        let keptTokens = tokenize(cleaned)
        guard !saidTokens.isEmpty, !keptTokens.isEmpty else {
            return verbatim.isEmpty ? [] : [Segment(text: verbatim, isCut: false)]
        }

        let keptFlags = matchFlags(said: saidTokens, kept: keptTokens)

        // If nothing survived, the two texts are unrelated — most likely the
        // model rewrote wholesale rather than trimmed. Show it as unedited.
        guard keptFlags.contains(true) else {
            return [Segment(text: verbatim, isCut: false)]
        }

        // Coalesce adjacent tokens of the same kind so the UI animates a handful
        // of runs rather than one span per word.
        var segments: [Segment] = []
        var current = ""
        var currentIsCut = !keptFlags[0]
        for (index, token) in saidTokens.enumerated() {
            let isCut = !keptFlags[index]
            if isCut == currentIsCut {
                current += token.raw
            } else {
                if !current.isEmpty { segments.append(Segment(text: current, isCut: currentIsCut)) }
                current = token.raw
                currentIsCut = isCut
            }
        }
        if !current.isEmpty { segments.append(Segment(text: current, isCut: currentIsCut)) }
        return segments
    }

    // MARK: - Internals

    struct Token {
        /// The word plus whatever whitespace followed it, so joining the raws
        /// reproduces the original string exactly.
        let raw: String
        /// Lowercased and stripped of punctuation, for comparison only. Smart
        /// mode adds punctuation and capitalisation, so comparing raw text would
        /// mark every word as cut.
        let key: String
    }

    static func tokenize(_ text: String) -> [Token] {
        var tokens: [Token] = []
        var word = ""
        var trailing = ""
        for character in text {
            if character.isWhitespace {
                if word.isEmpty { trailing.append(character) }
                else { trailing.append(character) }
            } else {
                if !trailing.isEmpty {
                    if !word.isEmpty {
                        tokens.append(Token(raw: word + trailing, key: normalize(word)))
                        word = ""
                    } else if var last = tokens.popLast() {
                        last = Token(raw: last.raw + trailing, key: last.key)
                        tokens.append(last)
                    }
                    trailing = ""
                }
                word.append(character)
            }
        }
        if !word.isEmpty || !trailing.isEmpty {
            tokens.append(Token(raw: word + trailing, key: normalize(word)))
        }
        return tokens.filter { !$0.raw.isEmpty }
    }

    static func normalize(_ word: String) -> String {
        word.lowercased().filter { $0.isLetter || $0.isNumber }
    }

    /// Longest common subsequence over the normalized keys. Every `said` token on
    /// the LCS is kept; everything else was removed.
    ///
    /// LCS rather than a set membership test because order carries meaning here:
    /// in "meet at 1pm, actually no, make it 2pm" the word "meet" appears once
    /// and must stay put, and a naive contains-check would also wrongly keep the
    /// first "1pm" if the final happened to mention 1pm elsewhere.
    static func matchFlags(said: [Token], kept: [Token]) -> [Bool] {
        let n = said.count, m = kept.count
        var table = [[Int]](repeating: [Int](repeating: 0, count: m + 1), count: n + 1)
        for i in stride(from: n - 1, through: 0, by: -1) {
            for j in stride(from: m - 1, through: 0, by: -1) {
                table[i][j] = said[i].key == kept[j].key && !said[i].key.isEmpty
                    ? table[i + 1][j + 1] + 1
                    : max(table[i + 1][j], table[i][j + 1])
            }
        }
        var flags = [Bool](repeating: false, count: n)
        var i = 0, j = 0
        while i < n, j < m {
            if said[i].key == kept[j].key && !said[i].key.isEmpty {
                flags[i] = true
                i += 1; j += 1
            } else if table[i + 1][j] >= table[i][j + 1] {
                i += 1
            } else {
                j += 1
            }
        }
        return flags
    }
}
