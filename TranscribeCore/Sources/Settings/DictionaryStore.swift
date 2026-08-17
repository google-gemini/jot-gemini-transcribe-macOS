import Foundation

/// The personal dictionary: terms (spelling hints fed to the cleanup prompt) and
/// explicit wrong→right rules (enforced deterministically post-model).
/// UserDefaults-backed — entries are small and this keeps v1 dependency-free.
public struct DictionaryEntry: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    /// The correct term ("Kubernetes", "Ammaar", "gRPC"). 1–60 chars.
    public var term: String
    /// Optional misspelling the model tends to produce ("cooper netties").
    public var misspelling: String?
    public var starred: Bool
    public var createdAt: Date

    public init(term: String, misspelling: String? = nil, starred: Bool = false) {
        self.id = UUID()
        self.term = term
        self.misspelling = misspelling
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
    public func add(term: String, misspelling: String? = nil) -> Bool {
        let trimmed = term.trimmingCharacters(in: .whitespacesAndNewlines)
        guard (1...60).contains(trimmed.count) else { return false }
        var current = entries()
        guard !current.contains(where: { $0.term.lowercased() == trimmed.lowercased() }) else { return false }
        current.append(DictionaryEntry(term: trimmed, misspelling: misspelling?.trimmingCharacters(in: .whitespacesAndNewlines)))
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

    /// Spelling hints for the prompt (top 10 with misspellings).
    public func spellings() -> [(wrong: String, right: String)] {
        entries().compactMap { entry in
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

    // MARK: - CSV (data portability)

    public func exportCSV() -> String {
        var lines = ["term,misspelling"]
        for entry in entries() {
            let term = entry.term.replacingOccurrences(of: "\"", with: "\"\"")
            let misspelling = (entry.misspelling ?? "").replacingOccurrences(of: "\"", with: "\"\"")
            lines.append("\"\(term)\",\"\(misspelling)\"")
        }
        return lines.joined(separator: "\n")
    }

    @discardableResult
    public func importCSV(_ csv: String) -> Int {
        var imported = 0
        for line in csv.split(separator: "\n").dropFirst() where imported < 1000 {
            let columns = parseCSVLine(String(line))
            guard let term = columns.first, !term.isEmpty else { continue }
            let misspelling = columns.count > 1 && !columns[1].isEmpty ? columns[1] : nil
            if add(term: term, misspelling: misspelling) {
                imported += 1
            }
        }
        return imported
    }

    private func parseCSVLine(_ line: String) -> [String] {
        var columns: [String] = []
        var current = ""
        var inQuotes = false
        var iterator = line.makeIterator()
        while let char = iterator.next() {
            switch (char, inQuotes) {
            case ("\"", _): inQuotes.toggle()
            case (",", false): columns.append(current); current = ""
            default: current.append(char)
            }
        }
        columns.append(current)
        return columns.map { $0.trimmingCharacters(in: .whitespaces) }
    }
}
