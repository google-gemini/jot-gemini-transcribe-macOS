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

import AppKit
import SwiftUI
import JotCore

/// The dictionary manager: teach it your words once, they're spelled right forever.
/// Terms ride in the cleanup prompt; explicit misspelling rules are enforced
/// deterministically after every dictation. An entry can also carry an EXPANSION,
/// which turns its term into a spoken shortcut — say "my email address", get the
/// address. Expansions are substituted locally and never sent to the API.
struct DictionaryView: View {
    private let store = DictionaryStore()

    @State private var entries: [DictionaryEntry] = []
    @State private var newTerm = ""
    @State private var newMisspelling = ""
    @State private var newExpansion = ""
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
        VStack(spacing: JotUI.Spacing.xs) {
            HStack(spacing: JotUI.Spacing.xs) {
                TextField("Add a word or phrase…", text: $newTerm)
                    .textFieldStyle(.plain)
                    .font(JotUI.TypeScale.body(grad: grad))
                    .onSubmit(add)
                Button(action: add) {
                    Image(systemName: "plus.circle.fill")
                        .foregroundStyle(newTerm.isEmpty ? JotUI.Colors.onSurfaceVariant : JotUI.Colors.primary)
                }
                .buttonStyle(.plain)
                .disabled(newTerm.isEmpty)
            }
            HStack(spacing: JotUI.Spacing.xs) {
                TextField("Gemini hears it as… (optional)", text: $newMisspelling)
                    .textFieldStyle(.plain)
                    .font(JotUI.TypeScale.body(grad: grad))
                    .foregroundStyle(JotUI.Colors.onSurfaceVariant)
                    .onSubmit(add)
                TextField("Expands to… (optional)", text: $newExpansion)
                    .textFieldStyle(.plain)
                    .font(JotUI.TypeScale.body(grad: grad))
                    .foregroundStyle(JotUI.Colors.onSurfaceVariant)
                    .onSubmit(add)
            }
        }
        .padding(JotUI.Spacing.s)
        .background(RoundedRectangle(cornerRadius: JotUI.Radius.medium).fill(JotUI.Colors.surfaceContainer))
        .padding(JotUI.Spacing.m)
    }

    private var filtered: [FilteredEntry] {
        let base = entries.sorted {
            if $0.starred != $1.starred { return $0.starred }
            return $0.createdAt > $1.createdAt
        }
        let matching = search.isEmpty ? base : base.filter {
            $0.term.localizedCaseInsensitiveContains(search)
                || ($0.misspelling?.localizedCaseInsensitiveContains(search) ?? false)
                || ($0.expansion?.localizedCaseInsensitiveContains(search) ?? false)
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
            HStack(spacing: JotUI.Spacing.s) {
                Button {
                    store.toggleStar(id: entry.id)
                    reload()
                } label: {
                    Image(systemName: entry.starred ? "star.fill" : "star")
                        .foregroundStyle(entry.starred ? JotUI.Colors.gYellow : JotUI.Colors.onSurfaceVariant.opacity(0.5))
                }
                .buttonStyle(.plain)
                .help("Starred words are prioritized")

                VStack(alignment: .leading, spacing: 2) {
                    Text(entry.term)
                        .font(JotUI.TypeScale.body(grad: grad))
                        .foregroundStyle(JotUI.Colors.onSurface)
                    if let misspelling = entry.misspelling, !misspelling.isEmpty {
                        Text("\"\(misspelling)\" → \(entry.term)")
                            .font(JotUI.TypeScale.labelSmall(grad: grad))
                            .foregroundStyle(JotUI.Colors.onSurfaceVariant)
                    }
                    if let expansion = entry.expansion, !expansion.isEmpty {
                        // Flattened, not just line-limited: a multi-line signature
                        // would otherwise preview as its first line alone.
                        Text("say it → \(expansion.replacingOccurrences(of: "\n", with: " "))")
                            .font(JotUI.TypeScale.labelSmall(grad: grad))
                            .foregroundStyle(JotUI.Colors.primary)
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }
                }
                Spacer()
                Button {
                    store.remove(id: entry.id)
                    reload()
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 10))
                        .foregroundStyle(JotUI.Colors.onSurfaceVariant)
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
        VStack(spacing: JotUI.Spacing.s) {
            Spacer()
            Image(systemName: "character.book.closed")
                .font(.system(size: 28))
                .foregroundStyle(JotUI.Colors.onSurfaceVariant)
            Text("Teach it your words")
                .font(JotUI.TypeScale.title(grad: grad))
                .foregroundStyle(JotUI.Colors.onSurface)
            Text("Names, jargon, product terms — add them once,\nthey're spelled right in every dictation.\nGive one an expansion and saying it writes the whole thing.")
                .font(JotUI.TypeScale.body(grad: grad))
                .foregroundStyle(JotUI.Colors.onSurfaceVariant)
                .multilineTextAlignment(.center)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var footer: some View {
        HStack {
            Text(feedback ?? "\(entries.count) \(entries.count == 1 ? "word" : "words")")
                .font(JotUI.TypeScale.labelSmall(grad: grad))
                .foregroundStyle(feedback == nil ? JotUI.Colors.onSurfaceVariant : JotUI.Colors.primary)
            Spacer()
            Button("Import CSV…", action: importCSV)
                .font(JotUI.TypeScale.labelSmall(grad: grad))
            Button("Export CSV…", action: exportCSV)
                .font(JotUI.TypeScale.labelSmall(grad: grad))
                .disabled(entries.isEmpty)
        }
        .buttonStyle(.link)
        .padding(JotUI.Spacing.m)
    }

    // MARK: - Actions

    private func add() {
        let expansion = newExpansion.trimmingCharacters(in: .whitespacesAndNewlines)
        guard store.add(
            term: newTerm,
            misspelling: newMisspelling.isEmpty ? nil : newMisspelling,
            expansion: expansion.isEmpty ? nil : expansion
        ) else {
            let trimmed = newTerm.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.count > 60 {
                showFeedback("Keep terms under 60 characters")
            } else if expansion.count > DictionaryEntry.maxExpansionLength {
                showFeedback("Keep expansions under \(DictionaryEntry.maxExpansionLength) characters")
            } else {
                showFeedback("Already in your dictionary")
            }
            return
        }
        newTerm = ""
        newMisspelling = ""
        newExpansion = ""
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
        panel.nameFieldStringValue = "jot-dictionary.csv"
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
