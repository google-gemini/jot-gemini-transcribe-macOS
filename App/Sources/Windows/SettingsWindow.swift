import AppKit
import ServiceManagement
import SwiftUI
import TranscribeCore

/// Settings in the macOS System Settings idiom: icon-tile sidebar on the left,
/// grouped inset sections with footers on the right. Four sections, that's the cap.
@MainActor
final class SettingsWindowController: NSWindowController {
    convenience init(onHotkeyConfigChanged: @escaping () -> Void, onDeleteAllHistory: @escaping () -> Void) {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 720, height: 520),
            styleMask: [.titled, .closable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = "Settings"
        window.titlebarAppearsTransparent = true
        window.center()
        window.contentView = NSHostingView(rootView: SettingsView(
            onHotkeyConfigChanged: onHotkeyConfigChanged,
            onDeleteAllHistory: onDeleteAllHistory
        ))
        self.init(window: window)
    }
}

private enum SettingsSection: String, CaseIterable, Identifiable {
    case general, dictation, privacy, advanced
    var id: String { rawValue }

    var title: String {
        switch self {
        case .general: return "General"
        case .dictation: return "Dictation"
        case .privacy: return "Privacy & Storage"
        case .advanced: return "Advanced"
        }
    }

    var icon: String {
        switch self {
        case .general: return "gearshape.fill"
        case .dictation: return "waveform"
        case .privacy: return "hand.raised.fill"
        case .advanced: return "wrench.and.screwdriver.fill"
        }
    }

    /// System-Settings-style icon tile colors.
    var tileColor: Color {
        switch self {
        case .general: return Color(nsColor: .systemGray)
        case .dictation: return GT.Colors.gBlue
        case .privacy: return Color(nsColor: .systemGreen)
        case .advanced: return Color(nsColor: .systemIndigo)
        }
    }
}

private struct SettingsView: View {
    let onHotkeyConfigChanged: () -> Void
    let onDeleteAllHistory: () -> Void
    @State private var selection: SettingsSection = .general

    var body: some View {
        HStack(spacing: 0) {
            sidebar
            Divider()
            detail
        }
        .frame(width: 720, height: 520)
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("Google Transcribe")
                .font(GT.TypeScale.title())
                .foregroundStyle(.primary)
                .padding(.horizontal, 14)
                .padding(.top, 18)
                .padding(.bottom, 10)
            ForEach(SettingsSection.allCases) { section in
                SidebarRow(
                    section: section,
                    selected: selection == section,
                    action: { selection = section }
                )
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
            switch selection {
            case .general: GeneralPane(onHotkeyConfigChanged: onHotkeyConfigChanged)
            case .dictation: DictationPane()
            case .privacy: PrivacyPane(onDeleteAllHistory: onDeleteAllHistory)
            case .advanced: AdvancedPane()
            }
        }
        .formStyle(.grouped)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct SidebarRow: View {
    let section: SettingsSection
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
                    .font(GT.TypeScale.body())
                    .foregroundStyle(selected ? Color.white : .primary)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(
                RoundedRectangle(cornerRadius: GT.Radius.small)
                    .fill(selected ? GT.Colors.primary
                          : hovering ? Color.primary.opacity(GT.StateLayer.hover)
                          : .clear)
            )
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

// MARK: - General

private struct GeneralPane: View {
    let onHotkeyConfigChanged: () -> Void
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
                    onHotkeyConfigChanged()
                }
                Toggle("Double-tap to lock hands-free", isOn: $doubleTapLock)
                    .onChange(of: doubleTapLock) { _, enabled in
                        settings.setDoubleTapLock(enabled)
                        onHotkeyConfigChanged()
                    }
            } footer: {
                Text("Hold to talk. Tap Space while holding to go hands-free. Esc cancels.")
            }

            Section {
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
        }
    }
}

// MARK: - Dictation

private struct DictationPane: View {
    private let settings = SettingsStore()
    @State private var sounds = SettingsStore().soundsEnabled
    @State private var smartFormatting = SettingsStore().smartFormattingEnabled

    var body: some View {
        Form {
            Section {
                Toggle("Sounds", isOn: $sounds)
                    .onChange(of: sounds) { _, enabled in settings.setSoundsEnabled(enabled) }
            } footer: {
                Text("Soft chimes when dictation starts, stops, and lands.")
            }

            Section {
                Toggle("Smart formatting", isOn: $smartFormatting)
                    .onChange(of: smartFormatting) { _, enabled in settings.setSmartFormatting(enabled) }
            } footer: {
                Text("Removes filler words, applies self-corrections (\"at 2 — actually 3\"), and adapts tone to the app you're writing in. Off = exact transcription.")
            }
        }
    }
}

// MARK: - Privacy & Storage

private struct PrivacyPane: View {
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
                    RetentionPolicy(audioRetentionDays: max(days, 0)).purgeExpiredAudio()
                }
            } footer: {
                Text("Transcripts stay in History until you delete them.")
            }

            Section {
                LabeledContent("Audio") { Text("Sent to the Gemini API with your key") }
                LabeledContent("Dictionary terms") { Text("Sent with each formatting request") }
                LabeledContent("Everything else") { Text("Never leaves this Mac") }
            } header: {
                Text("What leaves your Mac")
            } footer: {
                Text("No middleman server, no account, no analytics, no screenshots, no keystroke logging. One network host. See docs/PRIVACY.md in the repo for the full story.")
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

private struct AdvancedPane: View {
    private let settings = SettingsStore()
    @State private var apiKey = ""
    @State private var keyStatus: KeyStatus = KeychainStore.loadAPIKey() == nil ? .missing : .stored
    @State private var endpoint = UserDefaults.standard.string(forKey: "endpointOverride") ?? ""
    @State private var transcribeModel = UserDefaults.standard.string(forKey: "transcribeModelOverride") ?? ""
    @State private var cleanupModel = UserDefaults.standard.string(forKey: "cleanupModelOverride") ?? ""

    enum KeyStatus { case missing, stored, validating, valid, invalid }

    var body: some View {
        Form {
            Section {
                HStack {
                    SecureField("API key", text: $apiKey,
                                prompt: Text(keyStatus == .stored ? "••••••••  (stored in Keychain)" : "Paste your key"))
                        .font(GT.TypeScale.code)
                    keyStatusBadge
                }
                HStack {
                    Button("Save & Validate") { saveAndValidate() }
                        .disabled(apiKey.trimmingCharacters(in: .whitespaces).isEmpty)
                    Spacer()
                    Link("Get a key in Google AI Studio", destination: URL(string: "https://aistudio.google.com/apikey")!)
                        .font(GT.TypeScale.labelSmall())
                }
            } header: {
                Text("Gemini API key")
            } footer: {
                Text("Stored in your Mac's Keychain and only ever sent to Google.")
            }

            Section {
                TextField("Endpoint", text: $endpoint,
                          prompt: Text("https://generativelanguage.googleapis.com"))
                    .font(GT.TypeScale.code)
                    .onSubmit { settings.setEndpointOverride(endpoint.isEmpty ? nil : endpoint) }
                TextField("Transcription model", text: $transcribeModel,
                          prompt: Text("gemini-3.5-transcribe-preview"))
                    .font(GT.TypeScale.code)
                    .onSubmit { settings.setTranscribeModelOverride(transcribeModel.isEmpty ? nil : transcribeModel) }
                TextField("Formatting model", text: $cleanupModel,
                          prompt: Text("gemini-3.5-flash-lite"))
                    .font(GT.TypeScale.code)
                    .onSubmit { settings.setCleanupModelOverride(cleanupModel.isEmpty ? nil : cleanupModel) }
            } header: {
                Text("Model overrides")
            } footer: {
                Text("Preview models get renamed — override here if a model 404s. Leave blank for defaults.")
            }
        }
    }

    @ViewBuilder
    private var keyStatusBadge: some View {
        switch keyStatus {
        case .missing:
            Image(systemName: "key.slash").foregroundStyle(.secondary)
        case .stored:
            Image(systemName: "checkmark.circle").foregroundStyle(.secondary)
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
