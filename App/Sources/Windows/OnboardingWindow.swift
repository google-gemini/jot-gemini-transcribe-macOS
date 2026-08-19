import AppKit
import ApplicationServices
import AVFoundation
import SwiftUI
import JotCore

/// First-launch onboarding: welcome → key → mic → accessibility → Globe key →
/// try it → done. Warm, plain-spoken, one screen at a time (experience spec §5).
@MainActor
final class OnboardingWindowController: NSWindowController, NSWindowDelegate {
    private var onClosed: (() -> Void)?

    convenience init(
        onFinished: @escaping () -> Void,
        onClosed: @escaping () -> Void,
        latestRecord: @escaping () -> DictationRecord? = { nil }
    ) {
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
            rootView: OnboardingFlow(onFinished: onFinished, latestRecord: latestRecord)
                .frame(width: 640, height: 560)
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
    static let onboardingWindowClosed = Notification.Name("com.ammaar.jot.onboarding.closed")
    static let onboardingJumpToScreen = Notification.Name("com.ammaar.jot.onboarding.jump")
}

private struct OnboardingFlow: View {
    let onFinished: () -> Void
    var latestRecord: () -> DictationRecord? = { nil }

    enum Screen: Int, CaseIterable {
        case welcome, apiKey, microphone, accessibility, globeKey, howTo, tryIt, done
    }

    @State private var screen: Screen = .welcome
    @Environment(\.colorScheme) private var scheme
    private var grad: CGFloat { scheme == .dark ? 25 : 0 }

    var body: some View {
        VStack(spacing: 0) {
            Spacer(minLength: JotUI.Spacing.l)
            currentScreen
                .frame(maxWidth: 480)
                .transition(.asymmetric(
                    insertion: .move(edge: .trailing).combined(with: .opacity),
                    removal: .move(edge: .leading).combined(with: .opacity)
                ))
                .id(screen)
            Spacer()
            progressDots
                .padding(.bottom, JotUI.Spacing.l)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(JotUI.Colors.windowBackground)
        .animation(JotMotion.expressiveDefaultSpatial, value: screen)
        // jot://onboarding/<n> — deep-link to a screen (automation + UI checks).
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
        case .howTo: HowToScreen(onNext: { advance() })
        case .tryIt: TryItScreen(onNext: { advance() }, latestRecord: latestRecord)
        case .done: DoneScreen(onFinish: onFinished)
        }
    }

    private func advance() {
        var next = Screen(rawValue: screen.rawValue + 1) ?? .done
        // Skip the Globe screen when the system action is already Do Nothing.
        if next == .globeKey, !FnUsageAdvisor.currentGlobeKeyAction().conflictsWithFnHotkey {
            next = .howTo
        }
        screen = next
    }

    private var progressDots: some View {
        HStack(spacing: JotUI.Spacing.xs) {
            ForEach(Screen.allCases, id: \.rawValue) { s in
                Circle()
                    .fill(s == screen ? JotUI.Colors.primary : JotUI.Colors.outlineVariant)
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
        VStack(spacing: JotUI.Spacing.l) {
            Text(headline)
                .font(JotUI.TypeScale.display(grad: scheme == .dark ? 25 : 0))
                .foregroundStyle(JotUI.Colors.onSurface)
                .multilineTextAlignment(.center)
            Text(body_)
                .font(JotUI.TypeScale.body(grad: scheme == .dark ? 25 : 0))
                .foregroundStyle(JotUI.Colors.onSurfaceVariant)
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
                .font(JotUI.TypeScale.title())
                .foregroundStyle(JotUI.Colors.onPrimary)
                .padding(.horizontal, JotUI.Spacing.xl)
                .padding(.vertical, JotUI.Spacing.s)
                .background(Capsule().fill(disabled ? JotUI.Colors.outlineVariant : JotUI.Colors.primary))
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
        HStack(spacing: JotUI.Spacing.s) {
            Image(systemName: icon)
                .font(.system(size: 18))
                .foregroundStyle(granted ? JotUI.Colors.success : JotUI.Colors.primary)
                .frame(width: 28)
            Text(title)
                .font(JotUI.TypeScale.body())
                .foregroundStyle(JotUI.Colors.onSurface)
            Spacer()
            if granted {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(JotUI.Colors.success)
                    .transition(.scale.combined(with: .opacity))
            } else {
                Button("Grant", action: action)
                    .buttonStyle(.bordered)
            }
        }
        .padding(JotUI.Spacing.m)
        .background(RoundedRectangle(cornerRadius: JotUI.Radius.large).fill(JotUI.Colors.surface))
        .overlay(RoundedRectangle(cornerRadius: JotUI.Radius.large).strokeBorder(JotUI.Colors.outlineVariant.opacity(0.3), lineWidth: 1))
        .animation(JotMotion.expressiveFastSpatial, value: granted)
    }
}

// MARK: - Screens

private struct WelcomeScreen: View {
    let onNext: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var demoLevel: Float = 0
    @State private var heardShown = ""
    @State private var cleanShown = ""
    @State private var demoTask: Task<Void, Never>?

    // The whole promise in one loop: messy thought in, clean sentence out.
    private static let heardLine = "um so let's meet at 1pm… actually no, 2pm"
    private static let cleanLine = "Let's meet at 2pm."

    var body: some View {
        ScreenScaffold("Speak. It types.", "Hold a key, say the thing, and polished text lands wherever your cursor is.") {
            VStack(spacing: JotUI.Spacing.m) {
                WaveformView(level: demoLevel, processing: false)
                    .frame(width: 200, height: 48)
                    .background(Capsule().fill(JotUI.Colors.surface).shadow(color: .black.opacity(0.15), radius: 10, y: 2))
                demoText
                    .frame(width: 420, height: 48)
                PrimaryButton(title: "Get started", action: onNext)
            }
        }
        .onAppear(perform: startDemo)
        .onDisappear {
            demoTask?.cancel() // process-lifetime leak otherwise (audit L32)
            demoTask = nil
        }
    }

    @ViewBuilder
    private var demoText: some View {
        if reduceMotion {
            VStack(spacing: 2) {
                Text("“\(Self.heardLine)”")
                    .font(JotUI.TypeScale.labelSmall())
                    .italic()
                    .foregroundStyle(JotUI.Colors.onSurfaceVariant)
                Text(Self.cleanLine)
                    .font(JotUI.TypeScale.body())
                    .foregroundStyle(JotUI.Colors.onSurface)
            }
        } else {
            VStack(spacing: 2) {
                Text(heardShown.isEmpty ? " " : "“\(heardShown)”")
                    .font(JotUI.TypeScale.labelSmall())
                    .italic()
                    .foregroundStyle(JotUI.Colors.onSurfaceVariant.opacity(cleanShown.isEmpty ? 1 : 0.45))
                Text(cleanShown.isEmpty ? " " : cleanShown)
                    .font(JotUI.TypeScale.body())
                    .foregroundStyle(JotUI.Colors.onSurface)
            }
            // The typewriter IS the animation — inherited implicit animations
            // crossfade every character and ghost the previous loop's text.
            .transaction { $0.animation = nil }
        }
    }

    private func startDemo() {
        guard !reduceMotion, demoTask == nil else { return }
        demoTask = Task { @MainActor in
            while !Task.isCancelled {
                heardShown = ""; cleanShown = ""
                // "Hearing": the messy line types in while the waveform speaks.
                for char in Self.heardLine {
                    guard !Task.isCancelled else { return }
                    heardShown.append(char)
                    demoLevel = Float.random(in: 0.35...0.8)
                    try? await Task.sleep(nanoseconds: 38_000_000)
                }
                demoLevel = 0.08
                try? await Task.sleep(nanoseconds: 450_000_000)
                // "Writing": the clean line lands, correction already applied.
                for char in Self.cleanLine {
                    guard !Task.isCancelled else { return }
                    cleanShown.append(char)
                    try? await Task.sleep(nanoseconds: 30_000_000)
                }
                try? await Task.sleep(nanoseconds: 2_400_000_000)
            }
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
        ScreenScaffold("Bring your own key.", "Jot uses your Gemini API key. It's stored in your Mac's Keychain and only ever sent to Google.") {
            VStack(spacing: JotUI.Spacing.s) {
                if hasStoredKey {
                    Label("Key already in your Keychain", systemImage: "checkmark.circle.fill")
                        .font(JotUI.TypeScale.body())
                        .foregroundStyle(JotUI.Colors.success)
                } else {
                    SecureField("Paste your key", text: $key)
                        .textFieldStyle(.roundedBorder)
                        .font(JotUI.TypeScale.code)
                        .frame(width: 320)
                    if failed {
                        Text("That key didn't work — check it in AI Studio.")
                            .font(JotUI.TypeScale.labelSmall())
                            .foregroundStyle(JotUI.Colors.error)
                    }
                    if saveFailed {
                        Text("Couldn't save to your Mac's Keychain — try again.")
                            .font(JotUI.TypeScale.labelSmall())
                            .foregroundStyle(JotUI.Colors.error)
                    }
                    Link("Get a key in Google AI Studio", destination: URL(string: "https://aistudio.google.com/apikey")!)
                        .font(JotUI.TypeScale.labelSmall())
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
                            .font(JotUI.TypeScale.labelSmall())
                            .foregroundStyle(JotUI.Colors.onSurfaceVariant)
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
    @State private var heard = false
    @State private var advancing = false
    @State private var speechFrames = 0

    // "Can we listen?" read as surveillance (dogfood). This screen is a mic
    // CHECK, so it behaves like one: say hello, Jot hears you, it moves on.
    private var headline: String { granted ? "Say hello." : "Turn on the mic." }
    private var sub: String {
        if heard { return "Heard you loud and clear." }
        return granted
            ? "Jot is listening — this just checks your mic."
            : "macOS asks once. Jot only ever records while you're dictating."
    }

    var body: some View {
        ScreenScaffold(headline, sub) {
            VStack(spacing: JotUI.Spacing.m) {
                if granted {
                    ZStack {
                        WaveformView(level: level, processing: false)
                            .opacity(heard ? 0 : 1)
                        if heard {
                            Image(systemName: "checkmark.circle.fill")
                                .font(.system(size: 26))
                                .foregroundStyle(JotUI.Colors.success)
                                .transition(.scale.combined(with: .opacity))
                        }
                    }
                    .frame(width: 200, height: 48)
                    .background(Capsule().fill(JotUI.Colors.surface).shadow(color: .black.opacity(0.15), radius: 10, y: 2))
                    .animation(JotMotion.expressiveDefaultSpatial, value: heard)
                    .onAppear(perform: startMeter)
                    .onDisappear(perform: stopMeter)
                    .onReceive(NotificationCenter.default.publisher(for: .onboardingWindowClosed)) { _ in
                        stopMeter() // window close bypasses onDisappear (audit #6)
                    }
                    // Speaking IS the continue gesture; the quiet link remains for
                    // silent environments and users who can't speak.
                    Button("Continue without speaking") { advance() }
                        .buttonStyle(.plain)
                        .font(JotUI.TypeScale.labelSmall())
                        .foregroundStyle(JotUI.Colors.onSurfaceVariant)
                } else {
                    PermissionCard(icon: "mic.fill", title: "Microphone", granted: granted) {
                        AVCaptureDevice.requestAccess(for: .audio) { ok in
                            Task { @MainActor in granted = ok }
                        }
                    }
                }
            }
        }
        .onChange(of: level) { _, value in
            // Sustained speech energy, not a door slam or chair scrape: ~150ms
            // above the speech threshold before it counts as "hello".
            guard !heard else { return }
            if value > 0.18 {
                speechFrames += 1
                if speechFrames >= 7 {
                    heard = true
                    advance(after: 0.9)
                }
            } else {
                speechFrames = max(0, speechFrames - 1)
            }
        }
    }

    private func advance(after delay: TimeInterval = 0) {
        guard !advancing else { return }
        advancing = true
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            stopMeter()
            onNext()
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
        ScreenScaffold("Let it type for you.", "macOS needs your OK before Jot can place text at your cursor.") {
            VStack(spacing: JotUI.Spacing.m) {
                PermissionCard(icon: "keyboard", title: "Accessibility", granted: granted) {
                    let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
                    _ = AXIsProcessTrustedWithOptions(options)
                    NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
                }
                if slowGrant && !granted {
                    Text("Granted but not detected? A relaunch may be needed.")
                        .font(JotUI.TypeScale.labelSmall())
                        .foregroundStyle(JotUI.Colors.onSurfaceVariant)
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
            VStack(spacing: JotUI.Spacing.m) {
                VStack(alignment: .leading, spacing: JotUI.Spacing.xs) {
                    Text("In Keyboard settings, set:")
                        .font(JotUI.TypeScale.labelSmall())
                        .foregroundStyle(JotUI.Colors.onSurfaceVariant)
                    Text("Press 🌐 key to  →  Do Nothing")
                        .font(JotUI.TypeScale.title())
                        .foregroundStyle(JotUI.Colors.onSurface)
                }
                .padding(JotUI.Spacing.m)
                .background(RoundedRectangle(cornerRadius: JotUI.Radius.large).fill(JotUI.Colors.surface))

                if fixed {
                    Label("Done — the Globe key is yours", systemImage: "checkmark.circle.fill")
                        .font(JotUI.TypeScale.body())
                        .foregroundStyle(JotUI.Colors.success)
                } else {
                    Button("Open Keyboard Settings") {
                        NSWorkspace.shared.open(FnUsageAdvisor.keyboardSettingsURL)
                    }
                    .buttonStyle(.bordered)
                }

                if FnUsageAdvisor.karabinerIsPresent() {
                    Text("Karabiner-Elements is running — if fn doesn't respond, add Jot to its exclusions.")
                        .font(JotUI.TypeScale.labelSmall())
                        .foregroundStyle(JotUI.Colors.onSurfaceVariant)
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

/// Teach the product, not just prove it works (dogfood): the three gestures,
/// with the user's ACTUAL configured key, before the hands-on Try It.
private struct HowToScreen: View {
    let onNext: () -> Void
    private let keyName = SettingsStore().hotkeyKey.displayName

    var body: some View {
        ScreenScaffold("Talk to Jot.", "Three gestures — that's the whole product.") {
            VStack(spacing: JotUI.Spacing.m) {
                VStack(alignment: .leading, spacing: JotUI.Spacing.s) {
                    gestureRow(keys: [keyName], title: "Hold and talk",
                               detail: "Release, and polished text lands at your cursor.")
                    gestureRow(keys: [keyName, "space"], title: "Go hands-free",
                               detail: "Tap Space while holding — talk as long as you like, tap \(keyName) to finish.")
                    gestureRow(keys: ["esc"], title: "Changed your mind",
                               detail: "Cancels the dictation. Long recordings are kept in History.")
                }
                .padding(JotUI.Spacing.m)
                .background(RoundedRectangle(cornerRadius: JotUI.Radius.large).fill(JotUI.Colors.surface)
                    .shadow(color: .black.opacity(0.1), radius: 12, y: 2))
                PrimaryButton(title: "Got it", action: onNext)
            }
        }
    }

    private func gestureRow(keys: [String], title: String, detail: String) -> some View {
        HStack(alignment: .top, spacing: JotUI.Spacing.s) {
            HStack(spacing: 4) {
                ForEach(keys, id: \.self) { key in
                    keycap(key)
                }
            }
            .frame(width: 132, alignment: .leading)
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(JotUI.TypeScale.body())
                    .foregroundStyle(JotUI.Colors.onSurface)
                Text(detail)
                    .font(JotUI.TypeScale.labelSmall())
                    .foregroundStyle(JotUI.Colors.onSurfaceVariant)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func keycap(_ label: String) -> some View {
        Text(label)
            .font(JotUI.TypeScale.code)
            .foregroundStyle(JotUI.Colors.onSurface)
            .fixedSize()
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(
                RoundedRectangle(cornerRadius: 5)
                    .fill(JotUI.Colors.surfaceContainer)
                    .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(JotUI.Colors.outlineVariant.opacity(0.6), lineWidth: 1))
            )
    }
}

private struct TryItScreen: View {
    let onNext: () -> Void
    var latestRecord: () -> DictationRecord? = { nil }
    @State private var text = ""
    @State private var celebrated = false
    @State private var revealRaw: String?
    @State private var revealClean: String?
    @State private var fetchTask: Task<Void, Never>?

    private let keyName = SettingsStore().hotkeyKey.displayName
    private var hasWords: Bool {
        !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
    private static let script = "Let's schedule the meeting for 1pm — actually, no, make it 2pm."

    var body: some View {
        ScreenScaffold("Try it.", "Click into the field, hold \(keyName), and change your mind mid-sentence:") {
            VStack(spacing: JotUI.Spacing.s) {
                if revealRaw == nil {
                    Text("“\(Self.script)”")
                        .font(JotUI.TypeScale.body())
                        .italic()
                        .foregroundStyle(JotUI.Colors.onSurface)
                        .padding(.horizontal, JotUI.Spacing.m)
                        .padding(.vertical, JotUI.Spacing.xs)
                        .background(Capsule().fill(JotUI.Colors.surfaceContainer))
                    Text("(or say anything you like)")
                        .font(JotUI.TypeScale.labelSmall())
                        .foregroundStyle(JotUI.Colors.onSurfaceVariant)
                }
                ZStack(alignment: .topLeading) {
                    TextEditor(text: $text)
                        .font(JotUI.TypeScale.bodyLarge())
                        .scrollContentBackground(.hidden)
                        .padding(JotUI.Spacing.s)
                        .frame(width: 400, height: 96)
                        .background(RoundedRectangle(cornerRadius: JotUI.Radius.large).fill(JotUI.Colors.surface))
                        .overlay(RoundedRectangle(cornerRadius: JotUI.Radius.large).strokeBorder(JotUI.Colors.outlineVariant.opacity(0.4), lineWidth: 1))
                    if text.isEmpty {
                        Text("Your words will land here.")
                            .font(JotUI.TypeScale.bodyLarge())
                            .foregroundStyle(JotUI.Colors.onSurfaceVariant.opacity(0.6))
                            .padding(JotUI.Spacing.m)
                            .allowsHitTesting(false)
                    }
                }
                if let raw = revealRaw, let clean = revealClean {
                    // The reveal: what the pipeline actually did to their words —
                    // real record data, shown only when a real difference exists.
                    // The two rows ARE the story — no caption needed.
                    VStack(alignment: .leading, spacing: 3) {
                        revealRow(label: "You said", value: raw, emphasized: false)
                        revealRow(label: "Jot wrote", value: clean, emphasized: true)
                    }
                    .padding(JotUI.Spacing.s)
                    .frame(width: 400, alignment: .leading)
                    .background(RoundedRectangle(cornerRadius: JotUI.Radius.medium).fill(JotUI.Colors.surfaceContainer))
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                } else if celebrated {
                    ConfettiBurst()
                        .frame(height: 40)
                    Text("You just dictated \(text.split(separator: " ").count) words. That's the whole trick.")
                        .font(JotUI.TypeScale.body())
                        .foregroundStyle(JotUI.Colors.onSurfaceVariant)
                }
                // Words in the field = the moment to move forward. Skipping is a
                // quiet option only while it's empty (dogfood: "Skip for now"
                // lingering after success wasn't helpful).
                if hasWords {
                    PrimaryButton(title: "Continue", action: onNext)
                } else {
                    Button("Skip for now", action: onNext)
                        .buttonStyle(.plain)
                        .font(JotUI.TypeScale.body())
                        .foregroundStyle(JotUI.Colors.onSurfaceVariant)
                        .padding(.vertical, JotUI.Spacing.s)
                }
            }
            .animation(JotMotion.expressiveDefaultSpatial, value: revealRaw)
        }
        .onChange(of: text) { _, newValue in
            if !celebrated, newValue.split(separator: " ").count >= 2 {
                celebrated = true
            }
            if hasWords, fetchTask == nil {
                fetchReveal()
            }
        }
        .onDisappear {
            fetchTask?.cancel()
            fetchTask = nil
        }
    }

    private func revealRow(label: String, value: String, emphasized: Bool) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: JotUI.Spacing.xs) {
            Text(label)
                .font(JotUI.TypeScale.labelSmall())
                .foregroundStyle(JotUI.Colors.onSurfaceVariant)
                .frame(width: 62, alignment: .trailing)
            Text(value)
                .font(emphasized ? JotUI.TypeScale.body() : JotUI.TypeScale.labelSmall())
                .italic(!emphasized)
                .foregroundStyle(emphasized ? JotUI.Colors.onSurface : JotUI.Colors.onSurfaceVariant)
                .lineLimit(2)
        }
    }

    /// The record lands moments after the text does — fetch with one retry, and
    /// only show the card when the cleanup genuinely changed their words.
    private func fetchReveal() {
        fetchTask = Task { @MainActor in
            for delay in [0.4, 1.0] {
                try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                guard !Task.isCancelled else { return }
                if let record = latestRecord(),
                   let raw = record.rawTranscript, let clean = record.cleanedTranscript,
                   Self.normalized(raw) != Self.normalized(clean) {
                    revealRaw = raw
                    revealClean = clean
                    return
                }
            }
        }
    }

    private static func normalized(_ s: String) -> String {
        s.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }
}

private struct DoneScreen: View {
    let onFinish: () -> Void
    // Default ON — consent by visibility; the finish handler reconciles against
    // the real SMAppService state, so unchecking on a re-run actually disables.
    @State private var launchAtLogin = true

    var body: some View {
        ScreenScaffold("You're set.", "Jot lives in your menu bar now. Hold \(SettingsStore().hotkeyKey.displayName) anywhere and start talking.") {
            VStack(spacing: JotUI.Spacing.m) {
                Text("It strips your ums, matches your tone to the app you're in, and takes \"new paragraph\" literally. Teach it your jargon in Settings → Dictionary.")
                    .font(JotUI.TypeScale.labelSmall())
                    .foregroundStyle(JotUI.Colors.onSurfaceVariant)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 400)
                Toggle("Start Jot at login", isOn: $launchAtLogin)
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
                    Circle().fill(JotUI.Colors.brandQuad[i]).frame(width: 8, height: 8)
                }
            }
        } else {
            GeometryReader { geo in
                ZStack {
                    ForEach(0..<24, id: \.self) { i in
                        Circle()
                            .fill(JotUI.Colors.brandQuad[i % 4])
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
