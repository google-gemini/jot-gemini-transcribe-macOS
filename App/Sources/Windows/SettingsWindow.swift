import AppKit
import ServiceManagement
import SwiftUI
import TranscribeCore

/// Settings — 4 tabs, that's the cap (minimal-Googley, anti-Superwhisper).
@MainActor
final class SettingsWindowController: NSWindowController {
    convenience init(onHotkeyConfigChanged: @escaping () -> Void, onDeleteAllHistory: @escaping () -> Void) {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 560, height: 440),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "Settings"
        window.center()
        window.contentView = NSHostingView(rootView: SettingsView(
            onHotkeyConfigChanged: onHotkeyConfigChanged,
            onDeleteAllHistory: onDeleteAllHistory
        ))
        self.init(window: window)
    }
}

private struct SettingsView: View {
    let onHotkeyConfigChanged: () -> Void
    let onDeleteAllHistory: () -> Void

    var body: some View {
        TabView {
            GeneralTab(onHotkeyConfigChanged: onHotkeyConfigChanged)
                .tabItem { Label("General", systemImage: "gearshape") }
            DictationTab()
                .tabItem { Label("Dictation", systemImage: "waveform") }
            PrivacyTab(onDeleteAllHistory: onDeleteAllHistory)
                .tabItem { Label("Privacy & Storage", systemImage: "lock.shield") }
            AdvancedTab()
                .tabItem { Label("Advanced", systemImage: "wrench.and.screwdriver") }
        }
        .frame(width: 560, height: 420)
        .background(GT.Colors.windowBackground)
    }
}

// MARK: - General

private struct GeneralTab: View {
    let onHotkeyConfigChanged: () -> Void
    private let settings = SettingsStore()

    @State private var hotkey = SettingsStore().hotkeyKey
    @State private var doubleTapLock = SettingsStore().doubleTapLockEnabled
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled

    var body: some View {
        Form {
            Picker("Dictation key (hold to talk)", selection: $hotkey) {
                ForEach(HotkeyKey.allCases, id: \.self) { key in
                    Text(key.displayName).tag(key)
                }
            }
            .onChange(of: hotkey) { _, newKey in
                settings.setHotkeyKey(newKey)
                onHotkeyConfigChanged()
            }

            Toggle("Also allow double-tap to lock hands-free", isOn: $doubleTapLock)
                .onChange(of: doubleTapLock) { _, enabled in
                    settings.setDoubleTapLock(enabled)
                    onHotkeyConfigChanged()
                }
            Text("Hold to talk. Tap Space while holding to go hands-free. Esc cancels.")
                .font(GT.TypeScale.labelSmall())
                .foregroundStyle(GT.Colors.onSurfaceVariant)

            Divider()

            Toggle("Start Google Transcribe at login", isOn: $launchAtLogin)
                .onChange(of: launchAtLogin) { _, enabled in
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
        .formStyle(.grouped)
    }
}

// MARK: - Dictation

private struct DictationTab: View {
    private let settings = SettingsStore()
    @State private var sounds = SettingsStore().soundsEnabled
    @State private var smartFormatting = SettingsStore().smartFormattingEnabled

    var body: some View {
        Form {
            Toggle("Sounds", isOn: $sounds)
                .onChange(of: sounds) { _, enabled in settings.setSoundsEnabled(enabled) }
            Text("Soft chimes when dictation starts, stops, and lands.")
                .font(GT.TypeScale.labelSmall())
                .foregroundStyle(GT.Colors.onSurfaceVariant)

            Divider()

            Toggle("Smart formatting", isOn: $smartFormatting)
                .onChange(of: smartFormatting) { _, enabled in settings.setSmartFormatting(enabled) }
            Text("Removes filler words, applies self-corrections (\"at 2 — actually 3\"), and adapts tone to the app you're writing in. Off = exact transcription.")
                .font(GT.TypeScale.labelSmall())
                .foregroundStyle(GT.Colors.onSurfaceVariant)
        }
        .formStyle(.grouped)
    }
}

// MARK: - Privacy & Storage

private struct PrivacyTab: View {
    let onDeleteAllHistory: () -> Void
    private let settings = SettingsStore()
    @State private var retentionDays = SettingsStore().audioRetentionDays
    @State private var confirmingDelete = false

    var body: some View {
        Form {
            Picker("Keep audio recordings", selection: $retentionDays) {
                Text("Never (disables Retry)").tag(-1)
                Text("24 hours").tag(1)
                Text("7 days").tag(7)
                Text("30 days").tag(30)
                Text("Forever").tag(0)
            }
            .onChange(of: retentionDays) { _, days in
                settings.setAudioRetentionDays(days)
                RetentionPolicy(audioRetentionDays: max(days, 0)).purgeExpiredAudio()
            }
            Text("Transcripts stay in History until you delete them.")
                .font(GT.TypeScale.labelSmall())
                .foregroundStyle(GT.Colors.onSurfaceVariant)

            Divider()

            VStack(alignment: .leading, spacing: GT.Spacing.xs) {
                Text("What leaves your Mac").font(GT.TypeScale.title())
                Text("""
                Only the audio of each dictation and your dictionary terms, sent \
                directly to the Gemini API with your own key. No middleman server, \
                no account, no analytics, no screenshots, no keystroke logging. \
                Everything else — recordings, history, dictionary — stays on this Mac.
                """)
                .font(GT.TypeScale.labelSmall())
                .foregroundStyle(GT.Colors.onSurfaceVariant)
            }

            Divider()

            Button("Delete all history…", role: .destructive) {
                confirmingDelete = true
            }
            .confirmationDialog(
                "Delete all dictation history? Audio and transcripts will be removed from this Mac.",
                isPresented: $confirmingDelete
            ) {
                Button("Delete Everything", role: .destructive) { onDeleteAllHistory() }
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - Advanced

private struct AdvancedTab: View {
    private let settings = SettingsStore()
    @State private var apiKey = ""
    @State private var keyStatus: KeyStatus = KeychainStore.loadAPIKey() == nil ? .missing : .stored
    @State private var endpoint = UserDefaults.standard.string(forKey: "endpointOverride") ?? ""
    @State private var transcribeModel = UserDefaults.standard.string(forKey: "transcribeModelOverride") ?? ""
    @State private var cleanupModel = UserDefaults.standard.string(forKey: "cleanupModelOverride") ?? ""

    enum KeyStatus { case missing, stored, validating, valid, invalid }

    var body: some View {
        Form {
            VStack(alignment: .leading, spacing: GT.Spacing.xs) {
                HStack {
                    SecureField("Gemini API key", text: $apiKey, prompt: Text(keyStatus == .stored ? "•••••••• (stored in Keychain)" : "Paste your key"))
                        .font(GT.TypeScale.code)
                    keyStatusBadge
                }
                HStack {
                    Button("Save & validate") { saveAndValidate() }
                        .disabled(apiKey.trimmingCharacters(in: .whitespaces).isEmpty)
                    Link("Get a key in Google AI Studio", destination: URL(string: "https://aistudio.google.com/apikey")!)
                        .font(GT.TypeScale.labelSmall())
                }
            }

            Divider()

            TextField("Endpoint override", text: $endpoint, prompt: Text("https://generativelanguage.googleapis.com"))
                .font(GT.TypeScale.code)
                .onSubmit { settings.setEndpointOverride(endpoint.isEmpty ? nil : endpoint) }
            TextField("Transcription model", text: $transcribeModel, prompt: Text("gemini-3.5-transcribe-preview"))
                .font(GT.TypeScale.code)
                .onSubmit { settings.setTranscribeModelOverride(transcribeModel.isEmpty ? nil : transcribeModel) }
            TextField("Formatting model", text: $cleanupModel, prompt: Text("gemini-3.5-flash-lite"))
                .font(GT.TypeScale.code)
                .onSubmit { settings.setCleanupModelOverride(cleanupModel.isEmpty ? nil : cleanupModel) }
            Text("Preview models get renamed — override here if a model 404s.")
                .font(GT.TypeScale.labelSmall())
                .foregroundStyle(GT.Colors.onSurfaceVariant)
        }
        .formStyle(.grouped)
    }

    @ViewBuilder
    private var keyStatusBadge: some View {
        switch keyStatus {
        case .missing:
            Image(systemName: "key.slash").foregroundStyle(GT.Colors.onSurfaceVariant)
        case .stored:
            Image(systemName: "checkmark.circle").foregroundStyle(GT.Colors.onSurfaceVariant)
        case .validating:
            ProgressView().controlSize(.small)
        case .valid:
            Image(systemName: "checkmark.circle.fill").foregroundStyle(GT.Colors.success)
        case .invalid:
            Image(systemName: "xmark.circle.fill").foregroundStyle(GT.Colors.error)
        }
    }

    private func saveAndValidate() {
        let key = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { return }
        keyStatus = .validating
        Task {
            let client = GeminiClient(apiKey: { key })
            let valid = await client.validateKey(endpoint: settings.geminiConfig.endpoint)
            if valid {
                KeychainStore.saveAPIKey(key)
                apiKey = ""
                keyStatus = .valid
            } else {
                keyStatus = .invalid
            }
        }
    }
}
