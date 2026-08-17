import AppKit
import AVFoundation
import SwiftUI
import TranscribeCore

/// The History window: proof that nothing is ever lost. Day-grouped, searchable,
/// every row retryable, Cleaned/Raw always available. Minimal-Googley: one list,
/// one detail pane, no mode editors.
@MainActor
final class HistoryWindowController: NSWindowController {
    convenience init(store: HistoryStore, onRetry: @escaping (DictationRecord) -> Void) {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 760, height: 560),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Google Transcribe"
        window.center()
        window.contentView = NSHostingView(rootView: MainWindowView(store: store, onRetry: onRetry))
        self.init(window: window)
    }
}

private struct MainWindowView: View {
    let store: HistoryStore
    let onRetry: (DictationRecord) -> Void
    @State private var tab = 0

    var body: some View {
        VStack(spacing: 0) {
            Picker("", selection: $tab) {
                Text("History").tag(0)
                Text("Dictionary").tag(1)
            }
            .pickerStyle(.segmented)
            .frame(width: 220)
            .padding(.top, GT.Spacing.s)

            if tab == 0 {
                HistoryView(store: store, onRetry: onRetry)
            } else {
                DictionaryView()
            }
        }
        .background(GT.Colors.windowBackground)
    }
}

private struct HistoryView: View {
    let store: HistoryStore
    let onRetry: (DictationRecord) -> Void

    @State private var query = ""
    @State private var records: [DictationRecord] = []
    @State private var stats = HistoryStore.Stats(totalWords: 0, totalDictations: 0, averageWPM: 0)
    @State private var selected: DictationRecord?
    @Environment(\.colorScheme) private var scheme
    private var grad: CGFloat { scheme == .dark ? 25 : 0 }

    var body: some View {
        HSplitView {
            VStack(spacing: 0) {
                statsHeader
                searchField
                recordList
            }
            .frame(minWidth: 380)

            detailPane
                .frame(minWidth: 300)
        }
        .background(GT.Colors.windowBackground)
        .onAppear(perform: reload)
    }

    // MARK: - Header

    private var statsHeader: some View {
        HStack(spacing: GT.Spacing.xl) {
            stat(value: "\(stats.totalWords)", label: "words")
            stat(value: "\(stats.totalDictations)", label: "dictations")
            stat(value: stats.averageWPM > 0 ? "\(stats.averageWPM)" : "—", label: "avg WPM")
            Spacer()
            // Four-color mini accent — subtle, never loud.
            HStack(spacing: 3) {
                ForEach(0..<4, id: \.self) { index in
                    Capsule().fill(GT.Colors.brandQuad[index])
                        .frame(width: 12, height: 4)
                }
            }
        }
        .padding(GT.Spacing.m)
    }

    private func stat(value: String, label: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value)
                .font(GT.TypeScale.title(grad: grad))
                .monospacedDigit()
                .foregroundStyle(GT.Colors.onSurface)
            Text(label)
                .font(GT.TypeScale.labelSmall(grad: grad))
                .foregroundStyle(GT.Colors.onSurfaceVariant)
        }
    }

    private var searchField: some View {
        HStack(spacing: GT.Spacing.xs) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(GT.Colors.onSurfaceVariant)
            TextField("Search your dictations", text: $query)
                .textFieldStyle(.plain)
                .font(GT.TypeScale.body(grad: grad))
                .onChange(of: query) { _, _ in reload() }
        }
        .padding(.horizontal, GT.Spacing.s)
        .padding(.vertical, GT.Spacing.xs)
        .background(Capsule().fill(GT.Colors.surfaceContainer))
        .padding(.horizontal, GT.Spacing.m)
        .padding(.bottom, GT.Spacing.xs)
    }

    // MARK: - List

    private var grouped: [(day: String, items: [DictationRecord])] {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.doesRelativeDateFormatting = true
        var groups: [(String, [DictationRecord])] = []
        for record in records {
            let day = formatter.string(from: record.startedAt)
            if groups.last?.0 == day {
                groups[groups.count - 1].1.append(record)
            } else {
                groups.append((day, [record]))
            }
        }
        return groups.map { (day: $0.0, items: $0.1) }
    }

    private var recordList: some View {
        Group {
            if records.isEmpty {
                emptyState
            } else {
                List(selection: Binding(
                    get: { selected?.id },
                    set: { id in selected = records.first { $0.id == id } }
                )) {
                    ForEach(grouped, id: \.day) { group in
                        Section {
                            ForEach(group.items, id: \.id) { record in
                                row(record).tag(record.id)
                            }
                        } header: {
                            Text(group.day)
                                .font(GT.TypeScale.labelSmall(grad: grad))
                                .foregroundStyle(GT.Colors.onSurfaceVariant)
                        }
                    }
                }
                .listStyle(.inset)
                .scrollContentBackground(.hidden)
            }
        }
    }

    private func row(_ record: DictationRecord) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(record.displayText.isEmpty ? "—" : String(record.displayText.prefix(90)))
                .font(GT.TypeScale.body(grad: grad))
                .foregroundStyle(GT.Colors.onSurface)
                .lineLimit(1)
            HStack(spacing: GT.Spacing.xs) {
                if let app = record.targetAppName {
                    Text(app)
                }
                if let duration = record.durationSeconds {
                    Text(String(format: "%.0fs", duration))
                }
                Text(record.startedAt.formatted(date: .omitted, time: .shortened))
                statusChip(record)
            }
            .font(GT.TypeScale.labelSmall(grad: grad))
            .foregroundStyle(GT.Colors.onSurfaceVariant)
        }
        .padding(.vertical, 3)
        .contextMenu {
            Button("Copy") { copy(record) }
            Button("Retry transcription") { onRetry(record); reloadSoon() }
            Divider()
            Button("Delete", role: .destructive) {
                store.delete(id: record.id, removeFolder: true)
                reload()
            }
        }
    }

    @ViewBuilder
    private func statusChip(_ record: DictationRecord) -> some View {
        switch SessionMeta.Status(rawValue: record.status) {
        case .queuedForRetry:
            chip("Waiting — Retry available", color: GT.Colors.gYellow)
        case .failed:
            chip("Failed — Retry", color: GT.Colors.error)
        case .awaitingChip:
            chip("Ready to paste", color: GT.Colors.primary)
        case .silent:
            chip("Silent", color: GT.Colors.onSurfaceVariant)
        case .heldSecure:
            chip("Held (secure field)", color: GT.Colors.onSurfaceVariant)
        default:
            EmptyView()
        }
    }

    private func chip(_ text: String, color: Color) -> some View {
        Text(text)
            .font(GT.TypeScale.labelSmall(grad: grad))
            .foregroundStyle(color)
            .padding(.horizontal, 6)
            .padding(.vertical, 1)
            .background(Capsule().fill(color.opacity(0.12)))
    }

    private var emptyState: some View {
        VStack(spacing: GT.Spacing.m) {
            Spacer()
            HStack(spacing: 5) {
                ForEach(0..<4, id: \.self) { index in
                    RoundedRectangle(cornerRadius: 3)
                        .fill(GT.Colors.brandQuad[index])
                        .frame(width: 6, height: [18, 30, 24, 14][index])
                }
            }
            Text("Nothing here yet")
                .font(GT.TypeScale.title(grad: grad))
                .foregroundStyle(GT.Colors.onSurface)
            Text("Hold fn and say hello.")
                .font(GT.TypeScale.body(grad: grad))
                .foregroundStyle(GT.Colors.onSurfaceVariant)
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: - Detail

    @State private var showRaw = false
    @State private var player: AVAudioPlayer?

    @ViewBuilder
    private var detailPane: some View {
        if let record = selected {
            ScrollView {
                VStack(alignment: .leading, spacing: GT.Spacing.m) {
                    HStack {
                        Picker("", selection: $showRaw) {
                            Text("Cleaned").tag(false)
                            Text("Raw").tag(true)
                        }
                        .pickerStyle(.segmented)
                        .frame(width: 160)
                        Spacer()
                        Button {
                            copy(record)
                        } label: {
                            Image(systemName: "doc.on.doc")
                        }
                        .buttonStyle(.borderless)
                        .help("Copy")
                    }

                    Text(showRaw ? (record.rawTranscript ?? "—") : (record.cleanedTranscript ?? record.rawTranscript ?? "—"))
                        .font(GT.TypeScale.bodyLarge(grad: grad))
                        .foregroundStyle(GT.Colors.onSurface)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)

                    audioControls(record)

                    VStack(alignment: .leading, spacing: 4) {
                        if let app = record.targetAppName {
                            metaLine("Dictated into", app)
                        }
                        if let pipeline = record.pipelineSeconds {
                            metaLine("Pipeline", String(format: "%.2fs", pipeline))
                        }
                        metaLine("Status", record.status)
                    }
                    .padding(.top, GT.Spacing.m)
                }
                .padding(GT.Spacing.l)
            }
        } else {
            VStack {
                Spacer()
                Text("Select a dictation")
                    .font(GT.TypeScale.body(grad: grad))
                    .foregroundStyle(GT.Colors.onSurfaceVariant)
                Spacer()
            }
            .frame(maxWidth: .infinity)
        }
    }

    @ViewBuilder
    private func audioControls(_ record: DictationRecord) -> some View {
        let cafURL = FileLayout.audioCAF(in: record.folderURL)
        if FileManager.default.fileExists(atPath: cafURL.path) {
            Button {
                if player?.isPlaying == true {
                    player?.stop()
                    player = nil
                } else {
                    player = try? AVAudioPlayer(contentsOf: cafURL)
                    player?.play()
                }
            } label: {
                Label(player?.isPlaying == true ? "Stop" : "Play audio", systemImage: player?.isPlaying == true ? "stop.fill" : "play.fill")
                    .font(GT.TypeScale.label(grad: grad))
            }
            .buttonStyle(.bordered)
        } else {
            Text("Audio removed by retention policy")
                .font(GT.TypeScale.labelSmall(grad: grad))
                .foregroundStyle(GT.Colors.onSurfaceVariant)
        }
    }

    private func metaLine(_ label: String, _ value: String) -> some View {
        HStack(spacing: GT.Spacing.xs) {
            Text(label).foregroundStyle(GT.Colors.onSurfaceVariant)
            Text(value).foregroundStyle(GT.Colors.onSurface)
        }
        .font(GT.TypeScale.labelSmall(grad: grad))
    }

    // MARK: - Actions

    private func copy(_ record: DictationRecord) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(record.displayText, forType: .string)
    }

    private func reload() {
        records = store.records(matching: query.isEmpty ? nil : query)
        stats = store.stats()
        if let selected, !records.contains(where: { $0.id == selected.id }) {
            self.selected = nil
        }
    }

    private func reloadSoon() {
        Task {
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            reload()
        }
    }
}
