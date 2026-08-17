# Google Transcribe — macOS Dictation App Plan

## Context

Ammaar wants a Mac dictation app in the Wispr Flow / Superwhisper category — hold a key anywhere, speak, release, polished text lands at the cursor — but unmistakably Google: Google Sans Flex, Material 3 Expressive motion, Gemini-Live-style pill HUD, G-major earcons, and reliability so good that losing a dictation is impossible. Powered by `gemini-3.5-transcribe-preview` (undocumented; API sample provided), open-sourced later.

This plan is the product of a 10-agent research sweep (Wispr Flow forensic teardown, Superwhisper/MacWhisper/VoiceInk, newer entrants, macOS system APIs, Google design system, reliability patterns, plus gap research on auth/wire-protocol/LLM-cleanup) and a 4-agent design phase (architecture / experience / product-reliability plans + adversarial critique). Full design specs are on disk (see **Reference documents** below) — they are the detailed contracts; this file is the executive plan.

## Locked decisions (confirmed with Ammaar)

- **Name**: Google Transcribe. **License**: MIT. (Flag: public release under the Google name needs Ammaar's internal brand/OSS review — start that process at M0; keep a neutral-rename fallback cheap. "Not an official Google product" README line until resolved.)
- **Stack**: Native Swift/SwiftUI menu-bar app (LSUIElement, no Dock icon), AppKit `NSPanel` HUD. macOS 14.0+, Apple Silicon + Intel. No Electron (research verdict was unambiguous: fn capture, non-activating overlays, AX insertion, idle footprint).
- **Invoke**: **Hold fn/Globe** (default) = push-to-talk; release = transcribe + insert. **Double-tap = hands-free lock**; single short tap = coaching hint ("Hold to talk — double-tap to lock"), audio discarded. Esc cancels. Rebindable (Ctrl+Opt fallback when no Apple keyboard); combo hotkeys via KeyboardShortcuts, fn via our CGEventTap.
- **API**: `POST https://generativelanguage.googleapis.com/v1beta/models/gemini-3.5-transcribe-preview:streamGenerateContent?alt=sse`, key in `x-goog-api-key` header (never `?key=` — leaks into logs). Request = `contents/parts`: `inline_data` (base64 FLAC) + TEXT steering prompt (formatting rules + dictionary + app-tone context ride in the same call), `generationConfig.audioTranscriptionConfig {wordTimestamp:false, diarization:false}`, temperature 0, safetySettings BLOCK_NONE. Response streams back via SSE. Batch-up/stream-down — no live partials while speaking (same as Wispr, whose full-context design is what enables cleanup). One call does transcription + formatting; a second-model cleanup pass is v1.x, not v1.
- **Auth**: BYOK Gemini API key (Ammaar provides), Keychain (`kSecUseDataProtectionKeychain`, AfterFirstUnlock, no iCloud sync). Settings override for endpoint + model ID. No accounts, no server, no telemetry.
- **V1 target-experience bar**: the 15-item "magic checklist" in the product spec (e.g., kill -9 mid-dictation → words recovered; ask a question aloud → it's transcribed, never answered; Wi-Fi off → calm "saved to History", auto-lands when back online; Little Snitch shows exactly one host).

## V1 scope

**In**: hold/lock dictation anywhere · crash-safe CAF recording from t=0 · FLAC upload + SSE streaming · steering-prompt formatting (punctuation, filler removal, self-correction collapsing "at 2, actually 3" → "at 3", per-app tone: Email/Work chat/Personal chat/Code/Other via a fixed authored bundle-ID map) · validation gate + auto-verbatim retry · verbatim escape hatch (toggle + hold-Shift-on-release + auto-degrade after 3 gate trips/24h) · spoken commands: "new line"/"new paragraph" only · dictionary (manual terms + misspelling replacements, quick-add ⌃⇧D, CSV import/export) · 3-tier insertion ladder with focus guard · persisted offline retry queue · History window (FTS search, Cleaned/Raw toggle, audio playback, Retry) · pill HUD + earcons + animated status item · 8-screen onboarding · Settings (4 tabs) · 10-min recording cap (soft warn 9:00) · Sparkle updates, notarized DMG.

**v1.x**: auto-learn dictionary from user edits (insertion code records AX element+range from day one to enable it) · "scratch that" post-insert · per-app custom modes · browser-URL tone detection · optional flash-lite cleanup pass · chunked >10-min dictations · pseudo-streaming HUD preview experiment · Apple SpeechTranscriber offline fallback · snippets.

**Never in v1**: accounts, telemetry/analytics SDKs, screenshots, full-AX-tree scraping, meeting notes, iOS.

## Architecture (full spec: `design/architecture.md`)

Thin app target + local SPM package `TranscribeCore` (~90% of logic, headless `swift test` in CI).

```
google-transcribe/
├── Transcribe.xcodeproj
├── App/                      # shell: TranscribeApp, StatusItemController (NSStatusItem, not MenuBarExtra),
│   ├── HUD/                  #   HUDPanel (NSPanel .nonactivatingPanel, .screenSaver level, canJoinAllSpaces),
│   ├── Windows/              #   History/Settings/Onboarding (SwiftUI)
│   ├── DesignSystem/         #   DesignTokens.swift + MotionTokens.swift (all M3 tokens; no magic values elsewhere)
│   └── Resources/            #   GoogleSansFlex VF + OFL.txt, earcons + CC-BY attribution
├── TranscribeCore/Sources/
│   ├── SessionCoordinator/   # DictationCoordinator (@MainActor), pure transition() state machine, session UUIDs
│   ├── HotkeyEngine/         # EventTapThread (CGEventTap .defaultTap on flagsChanged, fn=keycode 63, consume),
│   │                         #   HotkeyProcessor (Wispr grammar: hold=PTT, double-tap=lock, tap=hint; 1s typing-
│   │                         #   interruption abort), TapHealthMonitor (re-enable + 5s poll), FnUsageAdvisor
│   ├── AudioEngine/          # AVAudioEngine tap @ hardware format → AVAudioConverter → 16k mono Int16;
│   │                         #   CAFWriter (incremental AVAudioFile writes, fsync ~2s — CAF survives crashes);
│   │                         #   prewarm on keyDown (VoiceInk #687); device PINNED per session via
│   │                         #   kAudioOutputUnitProperty_CurrentDevice, fall back to built-in if it vanishes
│   ├── TranscriptionClient/  # GeminiTranscriptionClient (actor): FLACEncoder (AVAudioFile kAudioFormatFLAC,
│   │                         #   encode once at key-up), SSEParser (pure, golden-tested), TimeoutPolicy.swift
│   │                         #   (SINGLE source: connect 5s, TTFB 10s, stall 10s, overall 30s+duration/4,
│   │                         #   slow-state UI 3s), ConnectionPrewarmer (handshake on keyDown), RetryQueue
│   │                         #   (GRDB-backed, NWPathMonitor drain-on-network + drain-on-launch; one immediate
│   │                         #   silent retry; drained results notify + History, never auto-insert)
│   ├── FormattingPipeline/   # PromptAssembler (PromptV1.swift: static prefix → 3 few-shot incl. question-shaped
│   │                         #   speech → vocab block ≤100 terms → tone block → optional cursor context OFF by
│   │                         #   default), TranscriptValidator (G1 answer-pattern regex, G2 length-vs-speech-
│   │                         #   energy plausibility, G3 emptiness → one auto verbatim retry), ReplacementEngine
│   │                         #   (longest-match, word-boundary, case-preserving), VerbatimPolicy
│   ├── InsertionEngine/      # ladder: (1) AX kAXSelectedTextAttribute + AXManualAccessibility for Electron +
│   │                         #   read-back verify; (2) pasteboard snapshot-all → TransientType+session-UUID mark
│   │                         #   → synthetic ⌘V (Sauce layout-correct keycode, .privateState source) → restore
│   │                         #   ~1s w/ changeCount+UUID guard (per-app override in AppQuirksTable);
│   │                         #   (3) "Copied — press ⌘V" chip. Frontmost-change guard: never paste blind into a
│   │                         #   different app — actionable chip instead. SecureInputMonitor (TN2150).
│   ├── HistoryStore/         # per-dictation folder (audio.caf + audio.flac + meta.json) + GRDB (WAL, FTS5);
│   │                         #   RecoveryScanner (auto-transcribe ONLY most recent recovered; older = manual
│   │                         #   "Recovered — Retry" rows); RetentionPolicy (audio 7d default, never-delete
│   │                         #   before transcript exists)
│   ├── Permissions/ SettingsStore/ KeychainStore/ SoundEngine/ Support/
└── scripts/ + .github/workflows/   # ci.yml (swift test + build), release.yml (sign → notarize → staple → DMG →
                                    #   Sparkle EdDSA appcast → GitHub Release)
```

**SPM deps (all MIT)**: `sindresorhus/KeyboardShortcuts`, `Clipy/Sauce`, `sparkle-project/Sparkle`, `groue/GRDB.swift`. Nothing else — no EventSource lib (SSE parser is ~80 lines, golden-tested), no libopus (FLAC via CoreAudio), no PermissionsKit. VoiceInk/Hex/input0 are **pattern references only** (GPL — zero copied code; cleanroom stated in CONTRIBUTING).

**State machine**: `idle → warming → recording → finalizing → transcribing → inserting → done | error | cancelled`; HUD is a pure function of semantic state (Experience spec owns all HUD timing/lifecycle); overlapping sessions allowed (new dictation never blocks on a stuck old one, session-UUID stale guards).

## Design (full spec: `design/experience.md`)

- **HUD pill**: 48pt full-pill, bottom-center, `NSVisualEffectView` material + GM3 surfaces (`#FFFFFF`/`#1E1F20`), states idleDot(40pt) ↔ listening(200pt, 5-bar Google-Blue waveform, EMA attack .35/release .08, idle sine breathing) → locked(268pt, stop button w/ M3E shape-morph press) → processing(132pt, frozen bars run a four-color `#4285F4→#EA4335→#FBBC04→#34A853` traveling sweep + AI-shimmer edge glow — the only place that gradient family appears) → success(48pt circle, trim-path check in Google Green, word count) / error(errorContainer surface, shake, "saved to History" + Retry) / secureField / offline(amber queue dot). All motion from `MotionTokens.swift` (M3 springs mapped to SwiftUI: e.g. `.expressiveDefaultSpatial` = spring(response:0.32, damping:0.8); effects springs damping 1.0 — never bounce color/opacity).
- **Sound**: G-major earcon family (start = D5→G5 rise ~160ms; stop = mirror; success = G5 tap; error = muted F♯4+G4 dyad; lock = G4-B4-D5 arpeggio), <400ms, ~-20dBFS, frame-synced to state transitions, bootstrapped from CC-BY Material sound pack, zero sounds on hover/menus ("design the silence").
- **Type**: bundled Google Sans Flex VF (SIL OFL 1.1 since Nov 2025 — bundling legal; ship OFL.txt; pin exact TTF), opsz 17 UI / GRAD +25 dark / ROND 15-30 headlines; Google Sans Code for key/endpoint fields.
- **Onboarding** (8 screens): animated hero pill → paste-and-validate API key (live `models` call, AI Studio link) → mic permission (card becomes live level meter: "Say hello — we're listening") → Accessibility (1s live-polling card) → Globe-key step (reads `AppleFnUsageType`, deep-links System Settings → "Press 🌐 key to → Do Nothing", auto-advances; Karabiner warning; escape hatch to other keys) → hotkey pick → interactive first dictation with four-color confetti → done (launch-at-login checkbox visible, default on — consent by visibility).
- **Do-NOT list**: no Gemini spark / four-circle construction / Google "G" · no proprietary Google Sans · no auto-send default · no #000 · no focus stealing · no notch gimmicks · no telemetry.

## Reliability (full spec: `design/product-reliability.md` — 24-row failure matrix F1-F24)

Invariants: audio is on disk before any network I/O; every failure writes terminal status + error code to meta.json; one silent auto-retry for transient classes; errors are never modal. Highlights: offline → queue + auto-drain on network-restored; 401/403 → menu-bar error dot + Settings deep-link, new dictations still record and queue; 429 → distinguish RPM (retry) vs daily quota (banner + AI Studio link); model-answers-instead-of-transcribes → gate catches, silent verbatim retry; sleep mid-recording → finalize + transcribe on wake; disk full → loud degradation. Latency budget (5s dictation): FLAC encode ~30ms + upload ~20-90ms + TTFT (probe!) + streaming ≈ **p50 ≤0.9s key-up→inserted**, p95 2s; perceived speed via connection prewarm on keyDown, HUD choreography, insert-once-at-end.

## Critic reconciliations (canonical resolutions — supersede anything contrary in the three design docs)

1. Hotkey grammar = Wispr style (hold/double-tap-lock/tap-hint), not Hex short-press-locks.
2. Recording cap 10 min; **no ChunkPlanner in v1**; cap constant derived from measured request-size limit.
3. HUD streaming-transcript preview: gated on the day-0 endpoint probe (only if SSE is genuinely incremental with TTFT <1s; otherwise cut, processing choreography carries it).
4. Clipboard restore ~1s default + per-app override, after paste verification; empirical probe sets the number.
5. RetryQueue is a real module (see architecture); simple policy — no 24h exponential ladders.
6. Mic pinned per session; AU-level pinning spike before M2.
7. Experience spec owns all HUD lifecycle/timing; coordinator emits semantic states only.
8. Crash recovery: auto-transcribe most-recent only; never auto-insert.
9. One TimeoutPolicy.swift (connect 5s / TTFB 10s / stall 10s / overall 30s+duration÷4 / slow-UI 3s).
10. Cursor-context capture OFF by default; fixed authored tone map, no tone editor in v1.
11. Brand/legal review starts M0, gates public release; neutral-reskin fallback kept cheap.
12. Cut from v1: incremental-FLAC-during-hold (encode at key-up), CleanupPass code, milestone streaks/confetti (keep onboarding confetti + word count), draggable idle dot.

## Day-0 spikes (before M1; throwaway CLI + probes, need Ammaar's API key)

1. **Endpoint reality probe** (gates caps, streaming HUD, latency targets, timeout formula): FLAC accepted in inline_data? actual request-size ceiling (binary search)? SSE incremental or one lump? TTFT p50/p95 for 5s/30s/5min clips? temperature=0 / thinking-disable / audioTranscriptionConfig / BLOCK_NONE honored? 429 shape + free-tier limits? Does the steering prompt actually steer (tone, self-correction, question-shaped speech)?
2. **fn CGEventTap probe** on macOS 14/15/26: consume keycode-63 flagsChanged; system Globe action suppression at default AppleFnUsageType; tap survival; secure-input behavior; Tahoe `CGPreflightPostEventAccess` + synthetic ⌘V acceptance.
3. **AVAudioFile FLAC-write probe** (16k mono → .flac; encode time at key-up; endpoint accepts it).
4. **Electron AX insertion probe** (Slack, VS Code, Chrome, Google Docs): AXManualAccessibility latency, read-back truthfulness → seeds AppQuirksTable.
5. **Mic-pinning probe** + **paste-read-latency probe** (sets clipboard-restore constant).

## Milestones (each demoable; critic-approved order)

- **M0 Scaffold**: repo, TranscribeCore split, CI green, LSUIElement app + static status item, DesignTokens/MotionTokens, MIT LICENSE + THIRD_PARTY_NOTICES + "not an official Google product" README; brand review kicked off. Spikes run in parallel.
- **M1 Hotkey**: fn tap + Wispr grammar + tap health + FnUsageAdvisor; debug HUD shows begin/lock/finalize/cancel from any app.
- **M2 Crash-safe audio**: prewarm-on-keydown, CAF writes, device pinning, level meter. Verify: kill -9 leaves playable CAF; AirPods yank continues; zero-buffer errors.
- **M3 Transcription**: FLAC encode, request builder, SSE parser, TimeoutPolicy, RetryQueue; transcript into debug HUD; latency signposts.
- **M4 Insertion — first end-to-end dictation**: full ladder + guards; app matrix (TextEdit, Chrome, Safari, Slack, VS Code, iTerm2, Terminal+SecureInput, Google Docs, password field, Dvorak, Tahoe).
- **M5 HUD + sound**: real pill (all states), earcons, animated status item. Verify: 120Hz profiling, no focus stealing, full-screen apps.
- **M6 History + never-lose-words**: History window (FTS, playback, Retry, Cleaned/Raw), RecoveryScanner, RetentionPolicy, offline queue UX. Chaos tests: kill in every state.
- **M7 Onboarding + Settings + Dictionary**: full 8-screen flow, 4-tab Settings, dictionary + quick-add + CSV. Fresh-macOS-VM run-through.
- **M8 Hardening + release**: error-copy pass, full app/OS matrix, accessibility audit (VoiceOver + Reduce Motion as release gates), notarized DMG, Sparkle update path, PRIVACY.md, magic-checklist sign-off. Public only after brand review.

## Verification

- **Unit** (CI, every PR): HotkeyProcessor grammar matrix w/ fake Clock; coordinator transition table; SSEParser golden fixtures (split-mid-line, error frames); ValidationGate cases incl. answer-mode transcripts; ReplacementEngine; TimeoutPolicy/RetryQueue w/ virtual time; meta.json codec.
- **Integration**: URLProtocol-stubbed SSE streams (delays/stalls/drops); CAF crash harness (spawn recorder, kill -9, assert playable + recovery); GRDB migrations.
- **Insertion Lab**: hidden debug panel running the ladder against the frontmost app, reporting tier/verification/timing → checked-in `docs/insertion-matrix.md` per release.
- **Prompt eval set**: ~30 recorded clips (self-corrections, question-shaped speech, spoken punctuation, silence, numbers) run against the live endpoint; gate-trip and zero-edit rates tracked; required for any prompt change.
- **Dogfood ritual**: the 15-item magic checklist weekly; local latency overlay (key-up→inserted p50/p95).

## Reference documents (full specs — copy into repo `docs/design/` at M0)

Session scratchpad `/private/tmp/claude-1439432/-Users-ammaar-Development-google-transcribe/4ed52e0b-9358-4fa8-975e-b2b8df3e8e6c/scratchpad/`:
- `design/architecture.md` — module contracts, state machine table, concurrency, CI/signing detail
- `design/experience.md` — complete HUD/motion/sound/onboarding/settings spec w/ exact tokens
- `design/product-reliability.md` — failure matrix F1-F24, prompt v1 text, gate thresholds, latency math, PRIVACY.md outline
- `design/critique.md` — full must-fix list + spike definitions
- `research/*.md` — 9 research reports (competitor teardowns, macOS APIs, Google design, reliability, auth, wire, cleanup)
(Backup copies of raw agent output: `/private/tmp/claude-1439432/-Users-ammaar-Development-google-transcribe/4ed52e0b-9358-4fa8-975e-b2b8df3e8e6c/tasks/{w9m8zy70k,wob077n1r}.output`)

## Needed from Ammaar at implementation start

1. The Gemini API key (for day-0 spikes; goes into Keychain, never the repo).
2. Bundle identifier preference (e.g. `com.google.transcribe` vs personal reverse-DNS until brand review lands).
3. A quick listen to the earcon direction once M5 prototypes exist.
