import AppKit
import AVFoundation
import SwiftUI
import TranscribeCore

/// The History pane of the main window: proof that nothing is ever lost.
/// Stats up top, day-grouped searchable list, row → detail sheet with
/// Cleaned/Raw, audio playback, retry, delete.
struct HistoryPane: View {
    let store: HistoryStore
    let onRetry: (DictationRecord) -> Void

    @State private var query = ""
    @State private var records: [DictationRecord] = []
    @State private var stats = HistoryStore.Stats(totalWords: 0, totalDictations: 0, averageWPM: 0)
    @State private var detailRecord: DictationRecord?
    @State private var showAllAttention = false
    @State private var confirmingDiscardAll = false
    @Environment(\.colorScheme) private var scheme
    private var grad: CGFloat { scheme == .dark ? 25 : 0 }

    var body: some View {
        VStack(spacing: 0) {
            header
            if records.isEmpty {
                emptyState
            } else {
                recordList
            }
        }
        .onAppear(perform: reload)
        // Live pane: dictations landing, retries draining, and deletions all
        // announce themselves — no polling, no guessed delays.
        .onReceive(
            NotificationCenter.default.publisher(for: .gtHistoryDidChange)
                .debounce(for: .milliseconds(250), scheduler: RunLoop.main)
        ) { _ in
            reload()
        }
        .sheet(item: $detailRecord) { record in
            RecordDetailSheet(
                record: record,
                onRetry: { onRetry(record) },
                onDelete: {
                    store.delete(id: record.id, removeFolder: true)
                    detailRecord = nil
                    reload()
                }
            )
        }
    }

    // MARK: - Header (stats + search)

    private var header: some View {
        VStack(spacing: GT.Spacing.s) {
            HStack(spacing: GT.Spacing.xl) {
                stat(value: "\(stats.totalWords)", label: "words dictated")
                stat(value: "\(stats.totalDictations)", label: "dictations")
                stat(value: stats.averageWPM > 0 ? "\(stats.averageWPM)" : "—", label: "avg WPM")
                Spacer()
                HStack(spacing: 3) {
                    ForEach(0..<4, id: \.self) { index in
                        Capsule().fill(GT.Colors.brandQuad[index])
                            .frame(width: 12, height: 4)
                    }
                }
            }
            HStack(spacing: GT.Spacing.xs) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                TextField("Search your dictations", text: $query)
                    .textFieldStyle(.plain)
                    .font(GT.TypeScale.body(grad: grad))
                    .onChange(of: query) { _, _ in reload() }
            }
            .padding(.horizontal, GT.Spacing.s)
            .padding(.vertical, 7)
            .background(RoundedRectangle(cornerRadius: GT.Radius.small).fill(.quaternary.opacity(0.5)))
        }
        .padding(.horizontal, GT.Spacing.l)
        .padding(.top, GT.Spacing.l)
        .padding(.bottom, GT.Spacing.s)
    }

    private func stat(value: String, label: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(value)
                .font(GT.TypeScale.title(grad: grad))
                .monospacedDigit()
            Text(label)
                .font(GT.TypeScale.labelSmall(grad: grad))
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - List

    private var groupedTimeline: [(day: String, items: [DictationRecord])] {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.doesRelativeDateFormatting = true
        var groups: [(String, [DictationRecord])] = []
        for record in timeline {
            let day = formatter.string(from: record.startedAt)
            if groups.last?.0 == day {
                groups[groups.count - 1].1.append(record)
            } else {
                groups.append((day, [record]))
            }
        }
        return groups.map { (day: $0.0, items: $0.1) }
    }

    /// Rows needing action (retryable) — pinned above the timeline of words.
    private var attention: [DictationRecord] {
        records.filter { record in
            record.displayText.isEmpty || SessionMeta.Status(rawValue: record.status) == .queuedForRetry
                || SessionMeta.Status(rawValue: record.status) == .failed
        }
    }

    private var timeline: [DictationRecord] {
        records.filter { record in
            !record.displayText.isEmpty && SessionMeta.Status(rawValue: record.status) != .queuedForRetry
                && SessionMeta.Status(rawValue: record.status) != .failed
        }
    }

    private var recordList: some View {
        List {
            if !attention.isEmpty {
                Section {
                    // Capped shelf: attention must never bury the timeline of words.
                    ForEach(showAllAttention ? attention : Array(attention.prefix(3)), id: \.id) { record in
                        attentionRow(record)
                    }
                    if attention.count > 3 {
                        Button(showAllAttention ? "Show less" : "Show \(attention.count - 3) more") {
                            showAllAttention.toggle()
                        }
                        .buttonStyle(.link)
                        .font(GT.TypeScale.labelSmall(grad: grad))
                    }
                } header: {
                    HStack(spacing: GT.Spacing.xxs) {
                        Circle().fill(GT.Colors.gYellow).frame(width: 6, height: 6)
                        Text("Needs attention (\(attention.count))")
                            .font(GT.TypeScale.labelSmall(grad: grad))
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button("Discard All") {
                            confirmingDiscardAll = true
                        }
                        .buttonStyle(.link)
                        .font(GT.TypeScale.labelSmall(grad: grad))
                        .confirmationDialog(
                            "Discard all \(attention.count) recordings that need attention? Their audio will be deleted.",
                            isPresented: $confirmingDiscardAll
                        ) {
                            Button("Discard \(attention.count) Recordings", role: .destructive) {
                                for record in attention {
                                    store.delete(id: record.id, removeFolder: true)
                                }
                                reload()
                            }
                        }
                    }
                }
            }
            ForEach(groupedTimeline, id: \.day) { group in
                Section {
                    ForEach(group.items, id: \.id) { record in
                        row(record)
                    }
                } header: {
                    Text(group.day)
                        .font(GT.TypeScale.labelSmall(grad: grad))
                        .foregroundStyle(.secondary)
                }
            }
        }
        .listStyle(.inset)
        .scrollContentBackground(.hidden)
    }

    private func attentionRow(_ record: DictationRecord) -> some View {
        HStack(spacing: GT.Spacing.s) {
            VStack(alignment: .leading, spacing: 3) {
                Text(attentionTitle(record))
                    .font(GT.TypeScale.body(grad: grad))
                    .foregroundStyle(.primary)
                HStack(spacing: GT.Spacing.xs) {
                    if let app = record.targetAppName { Text(app) }
                    if let duration = record.durationSeconds {
                        Text(String(format: "%.0fs of audio", duration))
                    }
                    Text(record.startedAt.formatted(date: .abbreviated, time: .shortened))
                }
                .font(GT.TypeScale.labelSmall(grad: grad))
                .foregroundStyle(.secondary)
            }
            Spacer()
            Button("Retry") {
                onRetry(record)
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            Button {
                store.delete(id: record.id, removeFolder: true)
                reload()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help("Discard this recording")
        }
        .padding(.vertical, 3)
    }

    private func attentionTitle(_ record: DictationRecord) -> String {
        switch SessionMeta.Status(rawValue: record.status) {
        case .queuedForRetry: return "Waiting for network"
        case .cancelled: return "Cancelled recording — audio kept"
        case .failed where record.errorCode == "bad_request": return "Couldn't process this one"
        case .failed: return "Transcription failed"
        default: return "Recovered recording"
        }
    }

    private func row(_ record: DictationRecord) -> some View {
        Button {
            detailRecord = record
        } label: {
            HStack(spacing: GT.Spacing.s) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(record.displayText.isEmpty ? "—" : String(record.displayText.prefix(110)))
                        .font(GT.TypeScale.body(grad: grad))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    HStack(spacing: GT.Spacing.xs) {
                        if let app = record.targetAppName {
                            Text(app)
                        }
                        if let duration = record.durationSeconds {
                            Text(String(format: "%.0fs", duration))
                        }
                        Text(record.startedAt.formatted(date: .omitted, time: .shortened))
                    }
                    .font(GT.TypeScale.labelSmall(grad: grad))
                    .foregroundStyle(.secondary)
                }
                Spacer()
                statusChip(record)
                Image(systemName: "chevron.right")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.tertiary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button("Copy") { copy(record) }
            Button("Retry Transcription") { onRetry(record) }
            Divider()
            Button("Delete", role: .destructive) {
                store.delete(id: record.id, removeFolder: true)
                reload()
            }
        }
    }

    @ViewBuilder
    private func statusChip(_ record: DictationRecord) -> some View {
        // Timeline rows all carry words; only paste-state chips remain relevant
        // (failures live in the Needs-attention shelf above).
        switch SessionMeta.Status(rawValue: record.status) {
        case .awaitingChip:
            chip("Ready to paste", color: GT.Colors.primary)
        case .heldSecure:
            chip("Held", color: Color.secondary)
        case .cancelled:
            chip("Cancelled", color: Color.secondary)
        default:
            EmptyView()
        }
    }

    private func chip(_ text: String, color: Color) -> some View {
        Text(text)
            .font(GT.TypeScale.labelSmall(grad: grad))
            .foregroundStyle(color)
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
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
            Text("Hold fn and say hello.")
                .font(GT.TypeScale.body(grad: grad))
                .foregroundStyle(.secondary)
            Spacer()
        }
        .frame(maxWidth: .infinity)
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
    }

}

// MARK: - Detail sheet

private struct RecordDetailSheet: View {
    let record: DictationRecord
    let onRetry: () -> Void
    let onDelete: () -> Void

    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var scheme
    @State private var showRaw = false
    @State private var player: AVAudioPlayer?
    private var grad: CGFloat { scheme == .dark ? 25 : 0 }

    var body: some View {
        VStack(alignment: .leading, spacing: GT.Spacing.m) {
            HStack {
                Picker("", selection: $showRaw) {
                    Text("Cleaned").tag(false)
                    Text("Raw").tag(true)
                }
                .pickerStyle(.segmented)
                .frame(width: 170)
                Spacer()
                Button {
                    let pasteboard = NSPasteboard.general
                    pasteboard.clearContents()
                    pasteboard.setString(shownText, forType: .string)
                } label: {
                    Label("Copy", systemImage: "doc.on.doc")
                }
            }

            ScrollView {
                Text(shownText)
                    .font(GT.TypeScale.bodyLarge(grad: grad))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(minHeight: 120, maxHeight: 260)

            HStack(spacing: GT.Spacing.s) {
                audioButton
                Button("Retry Transcription") { onRetry() }
                Spacer()
                Button(role: .destructive) { onDelete() } label: {
                    Image(systemName: "trash")
                }
                .help("Delete this dictation")
            }

            Divider()

            Grid(alignment: .leading, horizontalSpacing: GT.Spacing.l, verticalSpacing: 4) {
                if let app = record.targetAppName {
                    GridRow {
                        metaLabel("Dictated into"); metaValue(app)
                    }
                }
                if let duration = record.durationSeconds {
                    GridRow {
                        metaLabel("Duration"); metaValue(String(format: "%.1fs", duration))
                    }
                }
                if let pipeline = record.pipelineSeconds {
                    GridRow {
                        metaLabel("Pipeline"); metaValue(String(format: "%.2fs", pipeline))
                    }
                }
                GridRow {
                    metaLabel("Status"); metaValue(record.status)
                }
            }

            HStack {
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(GT.Spacing.l)
        .frame(width: 520)
        .onDisappear { player?.stop() }
    }

    private var shownText: String {
        showRaw ? (record.rawTranscript ?? "—")
                : (record.cleanedTranscript ?? record.rawTranscript ?? "—")
    }

    @ViewBuilder
    private var audioButton: some View {
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
                Label(player?.isPlaying == true ? "Stop" : "Play Audio",
                      systemImage: player?.isPlaying == true ? "stop.fill" : "play.fill")
            }
        } else {
            Text("Audio removed by retention policy")
                .font(GT.TypeScale.labelSmall(grad: grad))
                .foregroundStyle(.secondary)
        }
    }

    private func metaLabel(_ text: String) -> some View {
        Text(text).font(GT.TypeScale.labelSmall(grad: grad)).foregroundStyle(.secondary)
    }

    private func metaValue(_ text: String) -> some View {
        Text(text).font(GT.TypeScale.labelSmall(grad: grad))
    }
}
