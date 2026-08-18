import AppKit
import Combine
import ServiceManagement
import SwiftUI
import JotCore

/// The one app window — System Settings idiom: icon-tile sidebar, grouped detail.
/// Your data (History, Dictionary) on top; app configuration below.
@MainActor
final class MainWindowController: NSWindowController {
    private var hosting: NSHostingView<MainView>?
    private let model: MainWindowModel
    private var titleObserver: AnyCancellable?

    init(
        store: HistoryStore?,
        onRetry: @escaping (DictationRecord) -> Void,
        onDeleteAllHistory: @escaping () -> Void
    ) {
        model = MainWindowModel()
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 880, height: 580),
            styleMask: [.titled, .closable, .miniaturizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = model.selection.title
        window.titlebarAppearsTransparent = true
        window.center()
        super.init(window: window)
        // System Settings idiom: the titlebar names the selected pane (the app
        // name already anchors the sidebar header).
        titleObserver = model.$selection.sink { [weak window] section in
            window?.title = section.title
        }
        window.contentView = NSHostingView(rootView: MainView(
            model: model,
            store: store,
            onRetry: onRetry,
            onDeleteAllHistory: onDeleteAllHistory
        ))
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func show(section: MainSection) {
        model.selection = section
        showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}

enum MainSection: String, CaseIterable, Identifiable {
    case history, dictionary
    case general, dictation, privacy, advanced
    var id: String { rawValue }

    var title: String {
        switch self {
        case .history: return "History"
        case .dictionary: return "Dictionary"
        case .general: return "General"
        case .dictation: return "Dictation"
        case .privacy: return "Privacy & Storage"
        case .advanced: return "Advanced"
        }
    }

    var icon: String {
        switch self {
        case .history: return "clock.arrow.circlepath"
        case .dictionary: return "character.book.closed.fill"
        case .general: return "gearshape.fill"
        case .dictation: return "waveform"
        case .privacy: return "hand.raised.fill"
        case .advanced: return "wrench.and.screwdriver.fill"
        }
    }

    var tileColor: Color {
        switch self {
        case .history: return JotUI.Colors.gBlue
        case .dictionary: return Color(nsColor: .systemOrange)
        case .general: return Color(nsColor: .systemGray)
        case .dictation: return Color(nsColor: .systemTeal)
        case .privacy: return Color(nsColor: .systemGreen)
        case .advanced: return Color(nsColor: .systemIndigo)
        }
    }

    static let dataSections: [MainSection] = [.history, .dictionary]
    static let settingsSections: [MainSection] = [.general, .dictation, .privacy, .advanced]
}

@MainActor
final class MainWindowModel: ObservableObject {
    @Published var selection: MainSection = .history
}

private struct MainView: View {
    @ObservedObject var model: MainWindowModel
    let store: HistoryStore?
    let onRetry: (DictationRecord) -> Void
    let onDeleteAllHistory: () -> Void

    var body: some View {
        HStack(spacing: 0) {
            sidebar
            Divider()
            detail
        }
        .frame(minWidth: 880, minHeight: 580)
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("Jot")
                .font(JotUI.TypeScale.title())
                .padding(.horizontal, 14)
                .padding(.top, 20)
                .padding(.bottom, 12)
            ForEach(MainSection.dataSections) { section in
                SidebarRow(section: section, selected: model.selection == section) {
                    model.selection = section
                }
            }
            Text("Settings")
                .font(JotUI.TypeScale.labelSmall())
                .foregroundStyle(.secondary)
                .padding(.horizontal, 14)
                .padding(.top, 16)
                .padding(.bottom, 4)
            ForEach(MainSection.settingsSections) { section in
                SidebarRow(section: section, selected: model.selection == section) {
                    model.selection = section
                }
            }
            Spacer()
        }
        .padding(.horizontal, 8)
        .frame(width: 210)
        .background(.thickMaterial)
    }

    @ViewBuilder
    private var detail: some View {
        Group {
            switch model.selection {
            case .history:
                if let store {
                    HistoryPane(store: store, onRetry: onRetry)
                } else {
                    ContentUnavailableView("History unavailable", systemImage: "clock.badge.exclamationmark")
                }
            case .dictionary:
                DictionaryView()
            case .general:
                GeneralPane().formStyle(.grouped)
            case .dictation:
                DictationPane().formStyle(.grouped)
            case .privacy:
                PrivacyPane(onDeleteAllHistory: onDeleteAllHistory).formStyle(.grouped)
            case .advanced:
                AdvancedPane().formStyle(.grouped)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .windowBackgroundColor))
    }
}

private struct SidebarRow: View {
    let section: MainSection
    let selected: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: section.icon)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 22, height: 22)
                    .background(RoundedRectangle(cornerRadius: 6).fill(section.tileColor))
                Text(section.title)
                    .font(JotUI.TypeScale.body())
                    .foregroundStyle(selected ? Color.white : .primary)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(
                RoundedRectangle(cornerRadius: JotUI.Radius.small)
                    .fill(selected ? JotUI.Colors.primary
                          : hovering ? Color.primary.opacity(JotUI.StateLayer.hover)
                          : .clear)
            )
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

// MARK: - General

struct GeneralPane: View {
    private let settings = SettingsStore()

    @State private var hotkey = SettingsStore().hotkeyKey
    @State private var doubleTapLock = SettingsStore().doubleTapLockEnabled
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled

    var body: some View {
        Form {
            Section {
                Picker("Dictation key", selection: $hotkey) {
                    ForEach(HotkeyKey.allCases, id: \.self) { key in
                        Text(key.displayName).tag(key)
                    }
                }
                .onChange(of: hotkey) { _, newKey in
                    settings.setHotkeyKey(newKey)
                }
                Toggle("Double-tap to lock hands-free", isOn: $doubleTapLock)
                    .onChange(of: doubleTapLock) { _, enabled in
                        settings.setDoubleTapLock(enabled)
                    }
            } footer: {
                Text("Hold to talk. Tap Space while holding to go hands-free. Esc cancels.")
            }

            Section {
                Toggle("Start Jot at login", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { _, enabled in
                        // The failure-path revert below re-enters onChange with the
                        // inverted value — this guard stops the bounce from calling
                        // into SMAppService a second time.
                        guard enabled != (SMAppService.mainApp.status == .enabled) else { return }
                        do {
                            if enabled {
                                try SMAppService.mainApp.register()
                            } else {
                                try SMAppService.mainApp.unregister()
                            }
                        } catch {
                            Log.ui.error("launch-at-login toggle failed: \(error)")
                            launchAtLogin = SMAppService.mainApp.status == .enabled
                        }
                    }
            }
        }
    }
}

// MARK: - Dictation

struct DictationPane: View {
    private let settings = SettingsStore()
    @State private var sounds = SettingsStore().soundsEnabled
    @State private var smartFormatting = SettingsStore().smartFormattingEnabled
    @State private var showIdleDot = SettingsStore().showIdleIndicator

    var body: some View {
        Form {
            Section {
                Toggle("Sounds", isOn: $sounds)
                    .onChange(of: sounds) { _, enabled in settings.setSoundsEnabled(enabled) }
                Toggle("Show resting indicator", isOn: $showIdleDot)
                    .onChange(of: showIdleDot) { _, show in settings.setShowIdleIndicator(show) }
            } footer: {
                Text("The resting dot grows into a Dictate button on hover; click it for hands-free. Off = the pill appears only while dictating.")
            }

            Section {
                Toggle("Smart formatting", isOn: $smartFormatting)
                    .onChange(of: smartFormatting) { _, enabled in
                        guard enabled != settings.smartFormattingEnabled else { return }
                        settings.setSmartFormatting(enabled)
                    }
            } footer: {
                Text("Removes filler words, applies self-corrections (\"at 2 — actually 3\"), and adapts tone to the app you're writing in. Off = exact transcription.")
            }
        }
        // Auto-degrade can flip this off while the pane is visible — a stale ON
        // toggle would make the user's next tap a silent no-op.
        .onReceive(NotificationCenter.default.publisher(for: .gtSettingDidChange).receive(on: RunLoop.main)) { note in
            if note.object as? String == "smartFormatting" {
                smartFormatting = settings.smartFormattingEnabled
            }
        }
    }
}

// MARK: - Privacy & Storage

struct PrivacyPane: View {
    let onDeleteAllHistory: () -> Void
    private let settings = SettingsStore()
    @State private var retentionDays = SettingsStore().audioRetentionDays
    @State private var confirmingDelete = false

    var body: some View {
        Form {
            Section {
                Picker("Keep audio recordings", selection: $retentionDays) {
                    Text("Never (disables Retry)").tag(-1)
                    Text("24 hours").tag(1)
                    Text("7 days").tag(7)
                    Text("30 days").tag(30)
                    Text("Forever").tag(0)
                }
                .onChange(of: retentionDays) { _, days in
                    settings.setAudioRetentionDays(days)
                    // Off the main thread — the purge walks every recording folder
                    // and would hitch the pane with a large history (the 6h timer
                    // path already detaches).
                    Task.detached(priority: .utility) {
                        RetentionPolicy(audioRetentionDays: days).purgeExpiredAudio()
                    }
                }
            } footer: {
                Text("Transcripts stay in History until you delete them.")
            }

            Section {
                LabeledContent("Audio") { Text("Sent to the Gemini API with your key") }
                LabeledContent("Transcript text") { Text("Sent once for formatting — never when Smart formatting is off") }
                LabeledContent("Dictionary terms") { Text("Sent with each formatting request") }
                LabeledContent("Everything else") { Text("Never leaves this Mac") }
            } header: {
                Text("What leaves your Mac")
            } footer: {
                Text("No middleman server, no account, no analytics, no screenshots, no keystroke logging. One network host.")
            }

            Section {
                Button("Delete All History…", role: .destructive) {
                    confirmingDelete = true
                }
                .confirmationDialog(
                    "Delete all dictation history? Audio and transcripts will be removed from this Mac.",
                    isPresented: $confirmingDelete
                ) {
                    Button("Delete Everything", role: .destructive) { onDeleteAllHistory() }
                }
            }
        }
    }
}

// MARK: - Advanced

struct AdvancedPane: View {
    private let settings = SettingsStore()
    @State private var apiKey = ""
    @State private var keyStatus: KeyStatus = KeychainStore.loadAPIKey() == nil ? .missing : .stored
    @State private var endpoint = SettingsStore().endpointOverride ?? ""
    @State private var transcribeModel = SettingsStore().transcribeModelOverride ?? ""
    @State private var cleanupModel = SettingsStore().cleanupModelOverride ?? ""

    enum KeyStatus { case missing, stored, validating, valid, invalid, saveFailed, savedOffline }

    private var hasStoredKey: Bool { keyStatus == .stored || keyStatus == .valid || keyStatus == .savedOffline }

    private var endpointLooksBroken: Bool {
        // Same predicate the effective config uses — the warning and reality
        // can never drift apart (SettingsStore.usableEndpointURL).
        let trimmed = endpoint.trimmingCharacters(in: .whitespacesAndNewlines)
        return !trimmed.isEmpty && SettingsStore.usableEndpointURL(trimmed) == nil
    }

    var body: some View {
        Form {
            Section {
                HStack {
                    SecureField("API key", text: $apiKey,
                                prompt: Text(hasStoredKey ? "••••••••  (stored in Keychain)" : "Paste your key"))
                        .font(JotUI.TypeScale.code)
                    keyStatusBadge
                }
                if keyStatus == .invalid, KeychainStore.loadAPIKey() != nil {
                    Text("That key didn't work — your saved key is unchanged.")
                        .font(JotUI.TypeScale.labelSmall())
                        .foregroundStyle(JotUI.Colors.error)
                }
                if keyStatus == .saveFailed {
                    Text("The key validated but couldn't be saved to your Keychain — try again.")
                        .font(JotUI.TypeScale.labelSmall())
                        .foregroundStyle(JotUI.Colors.error)
                }
                if keyStatus == .savedOffline {
                    Text("You look offline — key saved; it'll be checked on your first dictation.")
                        .font(JotUI.TypeScale.labelSmall())
                        .foregroundStyle(.secondary)
                }
                HStack {
                    Button("Save & Validate") { saveAndValidate() }
                        .disabled(apiKey.trimmingCharacters(in: .whitespaces).isEmpty)
                    if hasStoredKey {
                        Button("Remove Key…", role: .destructive) { removeKey() }
                    }
                    Spacer()
                    Link("Get a key in Google AI Studio", destination: URL(string: "https://aistudio.google.com/apikey")!)
                        .font(JotUI.TypeScale.labelSmall())
                }
            } header: {
                Text("Gemini API key")
            } footer: {
                Text("Stored in your Mac's Keychain and only ever sent to Google.")
            }

            Section {
                TextField("Endpoint", text: $endpoint,
                          prompt: Text("https://generativelanguage.googleapis.com"))
                    .font(JotUI.TypeScale.code)
                    .onChange(of: endpoint) { _, value in
                        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
                        settings.setEndpointOverride(trimmed.isEmpty ? nil : trimmed)
                    }
                if endpointLooksBroken {
                    Text("Not a valid http(s) URL — the default endpoint is being used.")
                        .font(JotUI.TypeScale.labelSmall())
                        .foregroundStyle(JotUI.Colors.error)
                }
                TextField("Transcription model", text: $transcribeModel,
                          prompt: Text("gemini-3.5-transcribe-preview"))
                    .font(JotUI.TypeScale.code)
                    .onChange(of: transcribeModel) { _, value in
                        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
                        settings.setTranscribeModelOverride(trimmed.isEmpty ? nil : trimmed)
                    }
                TextField("Formatting model", text: $cleanupModel,
                          prompt: Text("gemini-3.5-flash-lite"))
                    .font(JotUI.TypeScale.code)
                    .onChange(of: cleanupModel) { _, value in
                        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
                        settings.setCleanupModelOverride(trimmed.isEmpty ? nil : trimmed)
                    }
            } header: {
                Text("Model overrides")
            } footer: {
                Text("Preview models get renamed — override here if a model 404s. Leave blank for defaults — every edit saves as you type.")
            }
        }
        // Key saved elsewhere (onboarding, dev-file migration) while this pane is
        // open: refresh the badge — but never clobber in-flight feedback.
        .onReceive(NotificationCenter.default.publisher(for: .gtSettingDidChange).receive(on: RunLoop.main)) { note in
            if note.object as? String == "apiKey", keyStatus == .missing || keyStatus == .stored {
                keyStatus = KeychainStore.loadAPIKey() == nil ? .missing : .stored
            }
        }
    }

    @ViewBuilder
    private var keyStatusBadge: some View {
        switch keyStatus {
        case .missing:
            Image(systemName: "key.slash").foregroundStyle(.secondary)
        case .stored, .savedOffline:
            Image(systemName: "checkmark.circle").foregroundStyle(.secondary)
        case .validating:
            ProgressView().controlSize(.small)
        case .valid:
            Image(systemName: "checkmark.circle.fill").foregroundStyle(JotUI.Colors.success)
        case .invalid, .saveFailed:
            Image(systemName: "xmark.circle.fill").foregroundStyle(JotUI.Colors.error)
        }
    }

    private func saveAndValidate() {
        let key = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { return }
        keyStatus = .validating
        Task {
            let client = GeminiClient(apiKey: { key })
            let valid = await client.validateKey(endpoint: settings.geminiConfig.endpoint)
            if valid || !NetworkReachability.probablyOnline() {
                // Offline ≠ bad key (same rule as onboarding): save it and let
                // the first real dictation validate it.
                if KeychainStore.saveAPIKey(key) {
                    apiKey = ""
                    keyStatus = valid ? .valid : .savedOffline
                } else {
                    // A green check over a lost key is the worst possible lie.
                    keyStatus = .saveFailed
                }
            } else {
                keyStatus = .invalid
            }
        }
    }

    private func removeKey() {
        KeychainStore.deleteAPIKey(notify: true)
        apiKey = ""
        keyStatus = .missing
    }
}
