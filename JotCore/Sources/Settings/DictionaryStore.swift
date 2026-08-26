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

/// The personal dictionary: terms (spelling hints fed to the cleanup prompt),
/// explicit wrong→right rules (enforced deterministically post-model), and
/// snippets (a spoken trigger that expands to text you never said in full).
/// UserDefaults-backed — entries are small and this keeps v1 dependency-free.
public struct DictionaryEntry: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    /// The correct term ("Kubernetes", "Ammaar", "gRPC"), or — when `expansion`
    /// is set — the spoken trigger ("my email address"). 1–60 chars.
    public var term: String
    /// Optional misspelling the model tends to produce ("cooper netties").
    public var misspelling: String?
    /// Present ⇒ this entry is a snippet and `term` is the phrase the user
    /// speaks. Optional so entries written by older builds still decode
    /// (synthesised Codable uses decodeIfPresent for optionals).
    public var expansion: String?
    public var starred: Bool
    public var createdAt: Date

    /// Long enough for a dictated instruction paragraph; bounded so a runaway
    /// paste can't wedge the store or the editor.
    public static let maxExpansionLength = 2_000

    public var isSnippet: Bool { !(expansion ?? "").isEmpty }

    public init(term: String, misspelling: String? = nil, expansion: String? = nil, starred: Bool = false) {
        self.id = UUID()
        self.term = term
        self.misspelling = misspelling
        self.expansion = expansion
        self.starred = starred
        self.createdAt = Date()
    }
}

public struct DictionaryStore: Sendable {
    private static let key = "dictionaryEntries"
    private static let defaults = UserDefaults.standard

    public init() {}

    public func entries() -> [DictionaryEntry] {
        guard let data = Self.defaults.data(forKey: Self.key),
              let entries = try? JSONDecoder().decode([DictionaryEntry].self, from: data) else {
            return []
        }
        return entries
    }

    public func save(_ entries: [DictionaryEntry]) {
        if let data = try? JSONEncoder().encode(entries) {
            Self.defaults.set(data, forKey: Self.key)
        }
    }

    @discardableResult
    public func add(term: String, misspelling: String? = nil, expansion: String? = nil) -> Bool {
        let trimmed = term.trimmingCharacters(in: .whitespacesAndNewlines)
        guard (1...60).contains(trimmed.count) else { return false }
        // Only the OUTER whitespace goes: an expansion is inserted verbatim, and
        // a multi-line signature's interior newlines are the point.
        let cleanedExpansion = expansion?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let cleanedExpansion, cleanedExpansion.count > DictionaryEntry.maxExpansionLength { return false }
        var current = entries()
        guard !current.contains(where: { $0.term.lowercased() == trimmed.lowercased() }) else { return false }
        current.append(DictionaryEntry(
            term: trimmed,
            misspelling: misspelling?.trimmingCharacters(in: .whitespacesAndNewlines),
            expansion: (cleanedExpansion?.isEmpty ?? true) ? nil : cleanedExpansion
        ))
        save(current)
        return true
    }

    public func remove(id: UUID) {
        save(entries().filter { $0.id != id })
    }

    public func toggleStar(id: UUID) {
        var current = entries()
        if let index = current.firstIndex(where: { $0.id == id }) {
            current[index].starred.toggle()
            save(current)
        }
    }

    // MARK: - Pipeline inputs

    /// Vocabulary for the cleanup prompt: starred first, then newest. Cap 100.
    public func vocabulary() -> [String] {
        let sorted = entries().sorted {
            if $0.starred != $1.starred { return $0.starred }
            return $0.createdAt > $1.createdAt
        }
        return sorted.prefix(100).map(\.term)
    }

    /// Vocabulary as it goes over the wire — the SHARED sanitizer for both the
    /// cleanup prompt and the transcription request's `custom_vocabulary`.
    ///
    /// Dictionary entries are user/CSV data, so newlines are stripped and each
    /// term capped (audit L31: a crafted entry must not be able to smuggle its
    /// own instruction line into the prompt). Both consumers call this so they
    /// cannot drift apart, and a total-byte ceiling bounds the request whatever
    /// the per-term caps allow. Only CORRECT terms — never misspellings; biasing
    /// a recogniser toward "cooper netties" is actively harmful, and spellings()
    /// sits close enough to be wired up by accident.
    ///
    /// Snippet TRIGGERS ride along — the recogniser hearing "my email address"
    /// cleanly is what makes expansion fire. EXPANSIONS never leave the machine;
    /// they are substituted locally, after the response.
    public func sanitizedVocabulary(maxBytes: Int = 2_048) -> [String] {
        var used = 0
        var out: [String] = []
        for term in vocabulary() {
            let clean = String(
                term.replacingOccurrences(of: "\n", with: " ")
                    .replacingOccurrences(of: "\r", with: " ")
                    .prefix(60)
            ).trimmingCharacters(in: .whitespaces)
            guard !clean.isEmpty else { continue }
            let cost = clean.utf8.count + 1
            guard used + cost <= maxBytes else { break } // truncate from the END: starred survive
            used += cost
            out.append(clean)
        }
        return out
    }

    /// Spelling hints for the prompt (top 10 with misspellings) — starred first,
    /// matching vocabulary(): "Starred words are prioritized" must be true for
    /// both prompt inputs, not just one.
    public func spellings() -> [(wrong: String, right: String)] {
        entries()
            .sorted {
                if $0.starred != $1.starred { return $0.starred }
                return $0.createdAt > $1.createdAt
            }
            .compactMap { entry in
                entry.misspelling.flatMap { $0.isEmpty ? nil : (wrong: $0, right: entry.term) }
            }
            .prefix(10)
            .map { $0 }
    }

    /// Deterministic rules for the ReplacementEngine (ALL entries with misspellings).
    public func replacementRules() -> [ReplacementEngine.Rule] {
        entries().compactMap { entry in
            entry.misspelling.flatMap { $0.isEmpty ? nil : ReplacementEngine.Rule(wrong: $0, right: entry.term) }
        }
    }

    /// Every entry carrying an expansion. Unordered on purpose — expand() sorts
    /// by trigger length itself, and add() already rejects duplicate terms.
    public func snippets() -> [ReplacementEngine.Snippet] {
        entries().compactMap { entry in
            guard let expansion = entry.expansion, !expansion.isEmpty else { return nil }
            return ReplacementEngine.Snippet(trigger: entry.term, expansion: expansion)
        }
    }

    // MARK: - CSV (data portability)

    /// Third column is the snippet expansion. It may legally contain commas,
    /// quotes and NEWLINES — all three survive because every cell is quoted on
    /// the way out and splitRecords() below is quote-aware on the way back in.
    public func exportCSV() -> String {
        var lines = ["term,misspelling,expansion"]
        for entry in entries() {
            let term = entry.term.replacingOccurrences(of: "\"", with: "\"\"")
            let misspelling = (entry.misspelling ?? "").replacingOccurrences(of: "\"", with: "\"\"")
            let expansion = (entry.expansion ?? "").replacingOccurrences(of: "\"", with: "\"\"")
            lines.append("\"\(term)\",\"\(misspelling)\",\"\(expansion)\"")
        }
        return lines.joined(separator: "\n")
    }

    /// Quote-aware record splitter: CRLF endings and RFC-4180 quoted newlines
    /// both broke the naive \n split (dropped/mangled rows while reporting
    /// success — production pass 2).
    private func splitRecords(_ csv: String) -> [String] {
        var records: [String] = []
        var current = ""
        var inQuotes = false
        for char in csv {
            if char == "\"" {
                inQuotes.toggle()
                current.append(char)
            } else if !inQuotes, char == "\n" || char == "\r" || char == "\r\n" {
                if !current.isEmpty { records.append(current) }
                current = ""
            } else {
                current.append(char)
            }
        }
        if !current.isEmpty { records.append(current) }
        return records
    }

    @discardableResult
    public func importCSV(_ csv: String) -> Int {
        var lines = splitRecords(csv)
        // Only drop the first line when its first CELL is exactly a header word —
        // hasPrefix("term") would eat a real first entry like "terminal" from a
        // headerless file (audit L30 + settings live-audit).
        if let first = lines.first {
            let firstCell = parseCSVLine(first).first?.lowercased() ?? ""
            if ["term", "word", "phrase"].contains(firstCell) {
                lines.removeFirst()
            }
        }
        // Batch: one load + one save. Per-row add() re-decodes the whole store
        // from UserDefaults every time — O(n²) and a visible hitch at the cap.
        var current = entries()
        var seen = Set(current.map { $0.term.lowercased() })
        var imported = 0
        for line in lines where imported < 1000 {
            let columns = parseCSVLine(line)
            guard let rawTerm = columns.first else { continue }
            let term = rawTerm.trimmingCharacters(in: .whitespacesAndNewlines)
            guard (1...60).contains(term.count), !seen.contains(term.lowercased()) else { continue }
            let misspelling = columns.count > 1 && !columns[1].isEmpty ? columns[1] : nil
            // Drop an over-long expansion rather than the whole row: the term is
            // still a useful hint, and a truncated address that LOOKS right is
            // worse than none.
            var expansion = columns.count > 2 && !columns[2].isEmpty ? columns[2] : nil
            if let candidate = expansion, candidate.count > DictionaryEntry.maxExpansionLength {
                Log.ui.warning("dictionary import: expansion exceeded the cap — imported the term without it")
                expansion = nil
            }
            current.append(DictionaryEntry(term: term, misspelling: misspelling, expansion: expansion))
            seen.insert(term.lowercased())
            imported += 1
        }
        if imported > 0 {
            save(current)
        }
        return imported
    }

    private func parseCSVLine(_ line: String) -> [String] {
        var columns: [String] = []
        var current = ""
        var inQuotes = false
        let chars = Array(line)
        var index = 0
        while index < chars.count {
            let char = chars[index]
            switch (char, inQuotes) {
            case ("\"", true) where index + 1 < chars.count && chars[index + 1] == "\"":
                current.append("\"") // RFC 4180 escaped quote (audit L30)
                index += 1
            case ("\"", _):
                inQuotes.toggle()
            case (",", false):
                columns.append(current)
                current = ""
            default:
                current.append(char)
            }
            index += 1
        }
        columns.append(current)
        return columns.map { $0.trimmingCharacters(in: .whitespaces) }
    }
}
