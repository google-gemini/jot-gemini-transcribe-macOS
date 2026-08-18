import AppKit
import ApplicationServices
import AVFoundation
import SwiftUI
import TranscribeCore

/// First-launch onboarding: welcome → key → mic → accessibility → Globe key →
/// try it → done. Warm, plain-spoken, one screen at a time (experience spec §5).
@MainActor
final class OnboardingWindowController: NSWindowController, NSWindowDelegate {
    private var onClosed: (() -> Void)?

    convenience init(onFinished: @escaping () -> Void, onClosed: @escaping () -> Void) {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 640, height: 560),
            styleMask: [.titled, .closable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = ""
        window.titlebarAppearsTransparent = true
        // Pin the SwiftUI content to the design size — assigning an NSHostingView
        // whose fitting size is unbounded (Spacer + maxHeight: .infinity) resizes
        // the window to near screen height.
        window.contentView = NSHostingView(
            rootView: OnboardingFlow(onFinished: onFinished).frame(width: 640, height: 560)
        )
        window.setContentSize(NSSize(width: 640, height: 560))
        window.center()
        self.init(window: window)
        self.onClosed = onClosed
        window.delegate = self
    }

    /// Red-button close mid-flow must stop any live resources — the mic-test
    /// engine kept the mic (and the orange dot) alive forever (audit #6).
    func windowWillClose(_ notification: Notification) {
        NotificationCenter.default.post(name: .onboardingWindowClosed, object: nil)
        onClosed?()
    }
}

extension Notification.Name {
    static let onboardingWindowClosed = Notification.Name("com.google.transcribe.onboarding.closed")
    static let onboardingJumpToScreen = Notification.Name("com.google.transcribe.onboarding.jump")
}

private struct OnboardingFlow: View {
    let onFinished: () -> Void

    enum Screen: Int, CaseIterable {
        case welcome, apiKey, microphone, accessibility, globeKey, tryIt, done
    }

    @State private var screen: Screen = .welcome
    @Environment(\.colorScheme) private var scheme
    private var grad: CGFloat { scheme == .dark ? 25 : 0 }

    var body: some View {
        VStack(spacing: 0) {
            Spacer(minLength: GT.Spacing.l)
            currentScreen
                .frame(maxWidth: 480)
                .transition(.asymmetric(
                    insertion: .move(edge: .trailing).combined(with: .opacity),
                    removal: .move(edge: .leading).combined(with: .opacity)
                ))
                .id(screen)
            Spacer()
            progressDots
                .padding(.bottom, GT.Spacing.l)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(GT.Colors.windowBackground)
        .animation(GTMotion.expressiveDefaultSpatial, value: screen)
        // transcribe://onboarding/<n> — deep-link to a screen (automation + UI checks).
        .onReceive(NotificationCenter.default.publisher(for: .onboardingJumpToScreen)) { note in
            if let index = note.object as? Int, let target = Screen(rawValue: index) {
                screen = target
            }
        }
    }

    @ViewBuilder
    private var currentScreen: some View {
        switch screen {
        case .welcome: WelcomeScreen(onNext: { advance() })
        case .apiKey: APIKeyScreen(onNext: { advance() })
        case .microphone: MicScreen(onNext: { advance() })
        case .accessibility: AccessibilityScreen(onNext: { advance() })
        case .globeKey: GlobeKeyScreen(onNext: { advance() })
        case .tryIt: TryItScreen(onNext: { advance() })
        case .done: DoneScreen(onFinish: onFinished)
        }
    }

    private func advance() {
        var next = Screen(rawValue: screen.rawValue + 1) ?? .done
        // Skip the Globe screen when the system action is already Do Nothing.
        if next == .globeKey, !FnUsageAdvisor.currentGlobeKeyAction().conflictsWithFnHotkey {
            next = .tryIt
        }
        screen = next
    }

    private var progressDots: some View {
        HStack(spacing: GT.Spacing.xs) {
            ForEach(Screen.allCases, id: \.rawValue) { s in
                Circle()
                    .fill(s == screen ? GT.Colors.primary : GT.Colors.outlineVariant)
                    .frame(width: 6, height: 6)
            }
        }
    }
}

// MARK: - Shared pieces

private struct ScreenScaffold<Content: View>: View {
    let headline: String
    let body_: String
    let content: Content
    @Environment(\.colorScheme) private var scheme

    init(_ headline: String, _ body: String, @ViewBuilder content: () -> Content) {
        self.headline = headline
        self.body_ = body
        self.content = content()
    }

    var body: some View {
        VStack(spacing: GT.Spacing.l) {
            Text(headline)
                .font(GT.TypeScale.display(grad: scheme == .dark ? 25 : 0))
                .foregroundStyle(GT.Colors.onSurface)
                .multilineTextAlignment(.center)
            Text(body_)
                .font(GT.TypeScale.body(grad: scheme == .dark ? 25 : 0))
                .foregroundStyle(GT.Colors.onSurfaceVariant)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            content
        }
    }
}

private struct PrimaryButton: View {
    let title: String
    var disabled = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(GT.TypeScale.title())
                .foregroundStyle(GT.Colors.onPrimary)
                .padding(.horizontal, GT.Spacing.xl)
                .padding(.vertical, GT.Spacing.s)
                .background(Capsule().fill(disabled ? GT.Colors.outlineVariant : GT.Colors.primary))
        }
        .buttonStyle(.plain)
        .disabled(disabled)
    }
}

private struct PermissionCard: View {
    let icon: String
    let title: String
    let granted: Bool
    let action: () -> Void

    var body: some View {
        HStack(spacing: GT.Spacing.s) {
            Image(systemName: icon)
                .font(.system(size: 18))
                .foregroundStyle(granted ? GT.Colors.success : GT.Colors.primary)
                .frame(width: 28)
            Text(title)
                .font(GT.TypeScale.body())
                .foregroundStyle(GT.Colors.onSurface)
            Spacer()
            if granted {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(GT.Colors.success)
                    .transition(.scale.combined(with: .opacity))
            } else {
                Button("Grant", action: action)
                    .buttonStyle(.bordered)
            }
        }
        .padding(GT.Spacing.m)
        .background(RoundedRectangle(cornerRadius: GT.Radius.large).fill(GT.Colors.surface))
        .overlay(RoundedRectangle(cornerRadius: GT.Radius.large).strokeBorder(GT.Colors.outlineVariant.opacity(0.3), lineWidth: 1))
        .animation(GTMotion.expressiveFastSpatial, value: granted)
    }
}

// MARK: - Screens

private struct WelcomeScreen: View {
    let onNext: () -> Void
    @State private var demoLevel: Float = 0
    @State private var demoTimer: Timer?

    var body: some View {
        ScreenScaffold("Speak. It types.", "Hold a key, say the thing, and polished text lands wherever your cursor is.") {
            // The actual waveform component, breathing on a demo loop.
            WaveformView(level: demoLevel, processing: false)
                .frame(width: 200, height: 48)
                .background(Capsule().fill(GT.Colors.surface).shadow(color: .black.opacity(0.15), radius: 10, y: 2))
                .onAppear {
                    demoTimer = Timer.scheduledTimer(withTimeInterval: 0.6, repeats: true) { _ in
                        Task { @MainActor in
                            demoLevel = Float.random(in: 0.15...0.7)
                        }
                    }
                }
                .onDisappear {
                    demoTimer?.invalidate() // process-lifetime leak otherwise (audit L32)
                    demoTimer = nil
                }
            PrimaryButton(title: "Get started", action: onNext)
        }
    }
}

private struct APIKeyScreen: View {
    let onNext: () -> Void
    @State private var key = ""
    @State private var validating = false
    @State private var failed = false
    @State private var saveFailed = false
    private var hasStoredKey: Bool { KeychainStore.loadAPIKey() != nil }

    var body: some View {
        ScreenScaffold("Bring your own key.", "Google Transcribe uses your Gemini API key. It's stored in your Mac's Keychain and only ever sent to Google.") {
            VStack(spacing: GT.Spacing.s) {
                if hasStoredKey {
                    Label("Key already in your Keychain", systemImage: "checkmark.circle.fill")
                        .font(GT.TypeScale.body())
                        .foregroundStyle(GT.Colors.success)
                } else {
                    SecureField("Paste your key", text: $key)
                        .textFieldStyle(.roundedBorder)
                        .font(GT.TypeScale.code)
                        .frame(width: 320)
                    if failed {
                        Text("That key didn't work — check it in AI Studio.")
                            .font(GT.TypeScale.labelSmall())
                            .foregroundStyle(GT.Colors.error)
                    }
                    if saveFailed {
                        Text("Couldn't save to your Mac's Keychain — try again.")
                            .font(GT.TypeScale.labelSmall())
                            .foregroundStyle(GT.Colors.error)
                    }
                    Link("Get a key in Google AI Studio", destination: URL(string: "https://aistudio.google.com/apikey")!)
                        .font(GT.TypeScale.labelSmall())
                }
                if validating {
                    ProgressView().controlSize(.small)
                } else {
                    PrimaryButton(title: hasStoredKey ? "Continue" : "Save & continue",
                                  disabled: !hasStoredKey && key.trimmingCharacters(in: .whitespaces).isEmpty) {
                        hasStoredKey ? onNext() : validate()
                    }
                    if !hasStoredKey {
                        // Don't wall off mic/accessibility setup behind the key —
                        // the menu bar nudges toward Settings → Advanced until one exists.
                        Button("I'll add it later", action: onNext)
                            .buttonStyle(.plain)
                            .font(GT.TypeScale.labelSmall())
                            .foregroundStyle(GT.Colors.onSurfaceVariant)
                    }
                }
            }
        }
    }

    private func validate() {
        let candidate = key.trimmingCharacters(in: .whitespacesAndNewlines)
        validating = true
        failed = false
        Task {
            let client = GeminiClient(apiKey: { candidate })
            let ok = await client.validateKey(endpoint: SettingsStore().geminiConfig.endpoint)
            validating = false
            if ok || !NetworkReachability.probablyOnline() {
                // Offline ≠ bad key: save it and keep going — the first dictation
                // will validate it for real. Either way, advancing without the
                // key actually IN the Keychain would be a silent lie.
                if KeychainStore.saveAPIKey(candidate) {
                    onNext()
                } else {
                    saveFailed = true
                }
            } else {
                failed = true
            }
        }
    }
}

private struct MicScreen: View {
    let onNext: () -> Void
    @State private var granted = AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
    @State private var level: Float = 0
    @State private var meter: AudioCaptureEngine?

    var body: some View {
        ScreenScaffold("Can we listen?", granted ? "Say hello — we're listening." : "Google Transcribe records audio only while you hold the dictation key.") {
            VStack(spacing: GT.Spacing.m) {
                if granted {
                    WaveformView(level: level, processing: false)
                        .frame(width: 200, height: 48)
                        .background(Capsule().fill(GT.Colors.surface).shadow(color: .black.opacity(0.15), radius: 10, y: 2))
                        .onAppear(perform: startMeter)
                        .onDisappear(perform: stopMeter)
                        .onReceive(NotificationCenter.default.publisher(for: .onboardingWindowClosed)) { _ in
                            stopMeter() // window close bypasses onDisappear (audit #6)
                        }
                } else {
                    PermissionCard(icon: "mic.fill", title: "Microphone", granted: granted) {
                        AVCaptureDevice.requestAccess(for: .audio) { ok in
                            Task { @MainActor in granted = ok }
                        }
                    }
                }
                PrimaryButton(title: "Continue", disabled: !granted) {
                    stopMeter()
                    onNext()
                }
            }
        }
    }

    private func startMeter() {
        let engine = AudioCaptureEngine()
        engine.onLevel = { value in
            Task { @MainActor in level = value }
        }
        let scratch = FileManager.default.temporaryDirectory.appendingPathComponent("onboarding-mic-test.caf")
        try? engine.start(writingTo: scratch)
        meter = engine
    }

    private func stopMeter() {
        _ = meter?.stop()
        meter = nil
        try? FileManager.default.removeItem(at: FileManager.default.temporaryDirectory.appendingPathComponent("onboarding-mic-test.caf"))
    }
}

private struct AccessibilityScreen: View {
    let onNext: () -> Void
    @State private var granted = AXIsProcessTrusted()
    @State private var pollTimer: Timer?
    @State private var slowGrant = false

    var body: some View {
        ScreenScaffold("Let it type for you.", "macOS needs your OK before Google Transcribe can place text at your cursor.") {
            VStack(spacing: GT.Spacing.m) {
                PermissionCard(icon: "keyboard", title: "Accessibility", granted: granted) {
                    let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
                    _ = AXIsProcessTrustedWithOptions(options)
                    NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
                }
                if slowGrant && !granted {
                    Text("Granted but not detected? A relaunch may be needed.")
                        .font(GT.TypeScale.labelSmall())
                        .foregroundStyle(GT.Colors.onSurfaceVariant)
                }
                PrimaryButton(title: "Continue", disabled: !granted, action: onNext)
            }
        }
        .onAppear {
            pollTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { _ in
                Task { @MainActor in
                    let trusted = AXIsProcessTrusted()
                    if trusted, !granted {
                        // Wake the engine NOW — otherwise the Try-It screen two
                        // steps later is dead until relaunch (production pass 2).
                        NotificationCenter.default.post(name: .gtSettingDidChange, object: "accessibility")
                    }
                    granted = trusted
                }
            }
            Timer.scheduledTimer(withTimeInterval: 10, repeats: false) { _ in
                Task { @MainActor in slowGrant = true }
            }
        }
        .onDisappear {
            pollTimer?.invalidate()
        }
    }
}

private struct GlobeKeyScreen: View {
    let onNext: () -> Void
    @State private var fixed = !FnUsageAdvisor.currentGlobeKeyAction().conflictsWithFnHotkey
    @State private var pollTimer: Timer?

    var body: some View {
        ScreenScaffold("Make the 🌐 key yours.", "macOS currently uses the Globe key for its own shortcut. One switch and it's your dictation key.") {
            VStack(spacing: GT.Spacing.m) {
                VStack(alignment: .leading, spacing: GT.Spacing.xs) {
                    Text("In Keyboard settings, set:")
                        .font(GT.TypeScale.labelSmall())
                        .foregroundStyle(GT.Colors.onSurfaceVariant)
                    Text("Press 🌐 key to  →  Do Nothing")
                        .font(GT.TypeScale.title())
                        .foregroundStyle(GT.Colors.onSurface)
                }
                .padding(GT.Spacing.m)
                .background(RoundedRectangle(cornerRadius: GT.Radius.large).fill(GT.Colors.surface))

                if fixed {
                    Label("Done — the Globe key is yours", systemImage: "checkmark.circle.fill")
                        .font(GT.TypeScale.body())
                        .foregroundStyle(GT.Colors.success)
                } else {
                    Button("Open Keyboard Settings") {
                        NSWorkspace.shared.open(FnUsageAdvisor.keyboardSettingsURL)
                    }
                    .buttonStyle(.bordered)
                }

                if FnUsageAdvisor.karabinerIsPresent() {
                    Text("Karabiner-Elements is running — if fn doesn't respond, add Google Transcribe to its exclusions.")
                        .font(GT.TypeScale.labelSmall())
                        .foregroundStyle(GT.Colors.onSurfaceVariant)
                        .multilineTextAlignment(.center)
                }

                PrimaryButton(title: fixed ? "Continue" : "Skip for now", action: onNext)
            }
        }
        .onAppear {
            pollTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { _ in
                Task { @MainActor in
                    fixed = !FnUsageAdvisor.currentGlobeKeyAction().conflictsWithFnHotkey
                }
            }
        }
        .onDisappear {
            pollTimer?.invalidate()
        }
    }
}

private struct TryItScreen: View {
    let onNext: () -> Void
    @State private var text = ""
    @State private var celebrated = false

    var body: some View {
        ScreenScaffold("Try it.", "Click into the field below, hold your key, and tell us the best thing you ate this week.") {
            VStack(spacing: GT.Spacing.m) {
                ZStack(alignment: .topLeading) {
                    TextEditor(text: $text)
                        .font(GT.TypeScale.bodyLarge())
                        .scrollContentBackground(.hidden)
                        .padding(GT.Spacing.s)
                        .frame(width: 400, height: 110)
                        .background(RoundedRectangle(cornerRadius: GT.Radius.large).fill(GT.Colors.surface))
                        .overlay(RoundedRectangle(cornerRadius: GT.Radius.large).strokeBorder(GT.Colors.outlineVariant.opacity(0.4), lineWidth: 1))
                    if text.isEmpty {
                        Text("Your words will land here.")
                            .font(GT.TypeScale.bodyLarge())
                            .foregroundStyle(GT.Colors.onSurfaceVariant.opacity(0.6))
                            .padding(GT.Spacing.m)
                            .allowsHitTesting(false)
                    }
                }
                if celebrated {
                    ConfettiBurst()
                        .frame(height: 40)
                    Text("You just dictated \(text.split(separator: " ").count) words. That's the whole trick.")
                        .font(GT.TypeScale.body())
                        .foregroundStyle(GT.Colors.onSurfaceVariant)
                }
                // The primary path is dictating into the field — until that happens,
                // skipping stays a quiet option, not the big blue button.
                if celebrated {
                    PrimaryButton(title: "Continue", action: onNext)
                } else {
                    Button("Skip for now", action: onNext)
                        .buttonStyle(.plain)
                        .font(GT.TypeScale.body())
                        .foregroundStyle(GT.Colors.onSurfaceVariant)
                        .padding(.vertical, GT.Spacing.s)
                }
            }
        }
        .onChange(of: text) { _, newValue in
            if !celebrated, newValue.split(separator: " ").count >= 2 {
                celebrated = true
            }
        }
    }
}

private struct DoneScreen: View {
    let onFinish: () -> Void
    // Default ON — consent by visibility; the finish handler reconciles against
    // the real SMAppService state, so unchecking on a re-run actually disables.
    @State private var launchAtLogin = true

    var body: some View {
        ScreenScaffold("You're set.", "Google Transcribe lives in your menu bar now. Hold fn anywhere and start talking.") {
            VStack(spacing: GT.Spacing.m) {
                Toggle("Start Google Transcribe at login", isOn: $launchAtLogin)
                    .toggleStyle(.checkbox)
                PrimaryButton(title: "Start dictating") {
                    let enabled = SMAppService.mainApp.status == .enabled
                    do {
                        if launchAtLogin, !enabled {
                            try SMAppService.mainApp.register()
                        } else if !launchAtLogin, enabled {
                            // Re-run onboarding + uncheck must actually disable it.
                            try SMAppService.mainApp.unregister()
                        }
                    } catch {
                        // Dev/translocated builds throw routinely — never block
                        // finishing onboarding on the login item.
                        Log.ui.error("onboarding launch-at-login failed: \(error)")
                    }
                    onFinish()
                }
            }
        }
    }
}

/// Four-color confetti — onboarding only (Reduce Motion gets a static card).
private struct ConfettiBurst: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var animate = false

    var body: some View {
        if reduceMotion {
            HStack(spacing: 4) {
                ForEach(0..<4, id: \.self) { i in
                    Circle().fill(GT.Colors.brandQuad[i]).frame(width: 8, height: 8)
                }
            }
        } else {
            GeometryReader { geo in
                ZStack {
                    ForEach(0..<24, id: \.self) { i in
                        Circle()
                            .fill(GT.Colors.brandQuad[i % 4])
                            .frame(width: 6, height: 6)
                            .offset(
                                x: animate ? CGFloat((i * 37) % 200) - 100 : 0,
                                y: animate ? CGFloat((i * 23) % 60) - 40 : 0
                            )
                            .opacity(animate ? 0 : 1)
                    }
                }
                .frame(maxWidth: .infinity)
                .position(x: geo.size.width / 2, y: geo.size.height / 2)
            }
            .onAppear {
                withAnimation(.easeOut(duration: 1.2)) {
                    animate = true
                }
            }
        }
    }
}

import ServiceManagement
