import AppKit
import SwiftUI
import TranscribeCore

/// The dictionary manager: teach it your words once, they're spelled right forever.
/// Terms ride in the cleanup prompt; explicit misspelling rules are enforced
/// deterministically after every dictation.
struct DictionaryView: View {
    private let store = DictionaryStore()

    @State private var entries: [DictionaryEntry] = []
    @State private var newTerm = ""
    @State private var newMisspelling = ""
    @State private var search = ""
    /// Transient feedback under the add row / in the footer ("Already in your
    /// dictionary", "Imported 12 words") — silence on a failed action reads as
    /// a broken button.
    @State private var feedback: String?
    @Environment(\.colorScheme) private var scheme
    private var grad: CGFloat { scheme == .dark ? 25 : 0 }

    var body: some View {
        VStack(spacing: 0) {
            addRow
            if entries.isEmpty {
                emptyState
            } else {
                entryList
            }
            footer
        }
        .onAppear(perform: reload)
    }

    private var addRow: some View {
        HStack(spacing: GT.Spacing.xs) {
            TextField("Add a word or phrase…", text: $newTerm)
                .textFieldStyle(.plain)
                .font(GT.TypeScale.body(grad: grad))
                .onSubmit(add)
            TextField("Gemini hears it as… (optional)", text: $newMisspelling)
                .textFieldStyle(.plain)
                .font(GT.TypeScale.body(grad: grad))
                .foregroundStyle(GT.Colors.onSurfaceVariant)
                .onSubmit(add)
            Button(action: add) {
                Image(systemName: "plus.circle.fill")
                    .foregroundStyle(newTerm.isEmpty ? GT.Colors.onSurfaceVariant : GT.Colors.primary)
            }
            .buttonStyle(.plain)
            .disabled(newTerm.isEmpty)
        }
        .padding(GT.Spacing.s)
        .background(RoundedRectangle(cornerRadius: GT.Radius.medium).fill(GT.Colors.surfaceContainer))
        .padding(GT.Spacing.m)
    }

    private var filtered: [FilteredEntry] {
        let base = entries.sorted {
            if $0.starred != $1.starred { return $0.starred }
            return $0.createdAt > $1.createdAt
        }
        let matching = search.isEmpty ? base : base.filter {
            $0.term.localizedCaseInsensitiveContains(search)
                || ($0.misspelling?.localizedCaseInsensitiveContains(search) ?? false)
        }
        return matching.map { FilteredEntry(entry: $0) }
    }

    private struct FilteredEntry: Identifiable {
        let entry: DictionaryEntry
        var id: UUID { entry.id }
    }

    private var entryList: some View {
        List(filtered) { item in
            let entry = item.entry
            HStack(spacing: GT.Spacing.s) {
                Button {
                    store.toggleStar(id: entry.id)
                    reload()
                } label: {
                    Image(systemName: entry.starred ? "star.fill" : "star")
                        .foregroundStyle(entry.starred ? GT.Colors.gYellow : GT.Colors.onSurfaceVariant.opacity(0.5))
                }
                .buttonStyle(.plain)
                .help("Starred words are prioritized")

                VStack(alignment: .leading, spacing: 2) {
                    Text(entry.term)
                        .font(GT.TypeScale.body(grad: grad))
                        .foregroundStyle(GT.Colors.onSurface)
                    if let misspelling = entry.misspelling, !misspelling.isEmpty {
                        Text("\"\(misspelling)\" → \(entry.term)")
                            .font(GT.TypeScale.labelSmall(grad: grad))
                            .foregroundStyle(GT.Colors.onSurfaceVariant)
                    }
                }
                Spacer()
                Button {
                    store.remove(id: entry.id)
                    reload()
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 10))
                        .foregroundStyle(GT.Colors.onSurfaceVariant)
                }
                .buttonStyle(.plain)
            }
            .padding(.vertical, 2)
        }
        .listStyle(.inset)
        .scrollContentBackground(.hidden)
        .searchable(text: $search, placement: .automatic, prompt: "Search")
    }

    private var emptyState: some View {
        VStack(spacing: GT.Spacing.s) {
            Spacer()
            Image(systemName: "character.book.closed")
                .font(.system(size: 28))
                .foregroundStyle(GT.Colors.onSurfaceVariant)
            Text("Teach it your words")
                .font(GT.TypeScale.title(grad: grad))
                .foregroundStyle(GT.Colors.onSurface)
            Text("Names, jargon, product terms — add them once,\nthey're spelled right in every dictation.")
                .font(GT.TypeScale.body(grad: grad))
                .foregroundStyle(GT.Colors.onSurfaceVariant)
                .multilineTextAlignment(.center)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var footer: some View {
        HStack {
            Text(feedback ?? "\(entries.count) \(entries.count == 1 ? "word" : "words")")
                .font(GT.TypeScale.labelSmall(grad: grad))
                .foregroundStyle(feedback == nil ? GT.Colors.onSurfaceVariant : GT.Colors.primary)
            Spacer()
            Button("Import CSV…", action: importCSV)
                .font(GT.TypeScale.labelSmall(grad: grad))
            Button("Export CSV…", action: exportCSV)
                .font(GT.TypeScale.labelSmall(grad: grad))
                .disabled(entries.isEmpty)
        }
        .buttonStyle(.link)
        .padding(GT.Spacing.m)
    }

    // MARK: - Actions

    private func add() {
        guard store.add(term: newTerm, misspelling: newMisspelling.isEmpty ? nil : newMisspelling) else {
            let trimmed = newTerm.trimmingCharacters(in: .whitespacesAndNewlines)
            showFeedback(trimmed.count > 60 ? "Keep terms under 60 characters" : "Already in your dictionary")
            return
        }
        newTerm = ""
        newMisspelling = ""
        reload()
    }

    private func reload() {
        entries = store.entries()
    }

    private func showFeedback(_ message: String) {
        feedback = message
        Task {
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            feedback = nil
        }
    }

    private func importCSV() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.commaSeparatedText, .plainText]
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url,
              let csv = try? String(contentsOf: url, encoding: .utf8) else { return }
        let count = store.importCSV(csv)
        Log.ui.info("Dictionary: imported \(count) entries")
        reload()
        showFeedback(count == 0 ? "Nothing new to import" : "Imported \(count) \(count == 1 ? "word" : "words")")
    }

    private func exportCSV() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "google-transcribe-dictionary.csv"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try store.exportCSV().write(to: url, atomically: true, encoding: .utf8)
            showFeedback("Exported \(entries.count) \(entries.count == 1 ? "word" : "words")")
        } catch {
            Log.ui.error("Dictionary export failed: \(error)")
            showFeedback("Export failed — couldn't write the file")
        }
    }
}
