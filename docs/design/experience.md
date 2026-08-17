# Experience & Design Plan — Google-styled macOS Dictation App

Scope: complete UX spec for the v1 push-to-talk dictation app (Swift/SwiftUI, LSUIElement menu-bar app, AppKit NSPanel HUD). All motion is expressed as M3 tokens mapped to SwiftUI `spring(response:dampingFraction:)`. All colors are GM3 production values. Sources: `google-design.md` (tokens, Gemini Live, sound), `wispr-flow.md` (Flow Bar behaviors), `new-entrants.md` (Gemini Live state grammar, ChatGPT regression lessons), `superwhisper-macwhisper-voiceink.md` (HUD/status-dot patterns), `macos-architecture.md` (NSPanel, secure input, AppleFnUsageType), `reliability-formatting.md` (failure states).

---

## 0. Motion token foundation (used throughout — define once)

`MotionTokens.swift` constants, direct M3 mapping (response = 2π/√stiffness):

| Token | M3 source (damping/stiffness) | SwiftUI |
|---|---|---|
| `.fastSpatial` | 0.9 / 1400 | `.spring(response: 0.17, dampingFraction: 0.9)` |
| `.defaultSpatial` | 0.9 / 700 | `.spring(response: 0.24, dampingFraction: 0.9)` |
| `.slowSpatial` | 0.9 / 300 | `.spring(response: 0.36, dampingFraction: 0.9)` |
| `.fastEffects` | 1.0 / 3800 | `.spring(response: 0.10, dampingFraction: 1.0)` |
| `.defaultEffects` | 1.0 / 1600 | `.spring(response: 0.16, dampingFraction: 1.0)` |
| `.slowEffects` | 1.0 / 800 | `.spring(response: 0.22, dampingFraction: 1.0)` |
| `.expressiveFastSpatial` | 0.6 / 800 | `.spring(response: 0.22, dampingFraction: 0.6)` |
| `.expressiveDefaultSpatial` | 0.8 / 380 | `.spring(response: 0.32, dampingFraction: 0.8)` |
| `.expressiveSlowSpatial` | 0.8 / 200 | `.spring(response: 0.44, dampingFraction: 0.8)` |

Bezier/duration tokens for non-spring cases: `emphasizedDecelerate = timingCurve(0.05, 0.7, 0.1, 1.0)` (enters, 250–400ms), `emphasizedAccelerate = timingCurve(0.3, 0.0, 0.8, 0.15)` (exits, 150–200ms). Rules (hard): spatial springs move/resize/morph things (overshoot allowed); effects springs (damping 1.0) fade/recolor things (never bounce opacity or color). Expressive springs reserved for hero moments: pill appear, lock, success, onboarding celebration.

---

## 1. The HUD pill

### 1.1 Panel + placement
- `NSPanel`: `.nonactivatingPanel + .borderless`, `isFloatingPanel = true`, `level = .screenSaver`, `collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]`, clear/nonopaque, `hidesOnDeactivate = false`, `canBecomeKey = false` (flip `becomesKeyOnlyIfNeeded = true` only in states with buttons: locked, error). SwiftUI content via `NSHostingView`. Never a SwiftUI `Window` (steals focus).
- Position: bottom-center of the screen containing the frontmost window's key screen; `x = visibleFrame.midX`, pill baseline `y = visibleFrame.minY + 16pt`. Multi-display: follows frontmost app's screen at dictation start; does not jump mid-session.
- The panel frame is fixed-size (max pill bounds ~360×64); the pill draws inside it and animates its own width/height — avoids NSWindow frame animation jank.

### 1.2 Geometry
- **Pill height 48pt, corner radius 24 (full pill)** in all active states. Surface: light `#FFFFFF` / dark `#1E1F20`, behind it `NSVisualEffectView` (.hudWindow material) so it sits on macOS like Google's own Gemini Mac app does — Google brand on native materials. 1px inner border `outlineVariant` at 8% opacity. Shadow: elevation-3 (y=2, blur=12, black 20%).
- Content padding 16pt horizontal; internal elements on a 4pt grid.
- Widths per state (animated): idle-dot 40, listening 200, locked 268, processing 132, inserting/success 48 (becomes circle), error/secure/offline: fit-to-text, max 320.

### 1.3 States (state machine: `hidden → idleDot ↔ listening → processing → inserting → success → idleDot`, with `locked`, `error`, `secureField`, `offline` branches)

**hidden** — nothing on screen (user setting "Show idle indicator: Always / Only while dictating"; default Always). Menu bar icon remains.

**idleDot** — 40×8pt capsule, `onSurface` at 25% over blur material. Hover: grows to 48×20 (`.fastSpatial`), shows mic glyph, tooltip "Hold fn to dictate" (rotates tips). Click = start hands-free; right-click = mini menu (Hide for 1 hour / History / Settings — the Wispr pattern users love). Draggable to bottom-left/center/right snap zones.

**listening** (key down) — dot inflates to 200×48 with `.expressiveDefaultSpatial` (visible overshoot ~3%), content fades in with `.defaultEffects`. Content: **waveform centered** (spec §1.4) in Google Blue `#4285F4` (both themes — brand pop is the point). After 10s a `Label M` timer fades in at left (tabular numerals, `onSurfaceVariant`). Hover reveals a 20pt ✕ cancel button at left edge (state-layer hover 8%). Esc cancels always. Appears **on key-down within one frame** — recording starts at t=0 regardless of animation.

**locked (hands-free)** — entered by double-tap of the PTT key (Wispr/Hex pattern) or clicking the idle dot. Width → 268 (`.expressiveFastSpatial` — an eager, springy grow: the "settling in" moment). Layout: left = lock glyph (12pt) + elapsed timer `Label M`; center = waveform; right = **stop button**: 32pt circle, `primary` fill, 10pt white rounded-square stop icon. Press feedback on stop = M3E shape morph circle→rounded-square (`.fastSpatial`). Center of pill is NOT click-to-stop (Wispr's deliberate misclick protection). Esc or hotkey also ends.

**processing** (key released / stop pressed) — width → 132 (`.defaultSpatial`), waveform bars freeze then decouple from mic and run the **four-color treatment** (§1.5). If the API takes >4s: pill widens to fit "Still working…" `Label M` (Wispr's "taking longer than usual" pattern); audio is already safe on disk, so no anxiety copy.

**inserting** — brief (target <150ms visible): bars collapse into a 24pt horizontal line that sweeps once (`.fastEffects` opacity + `.fastSpatial` scale). If insertion falls back to clipboard-only, jump to error-family state "Copied — press ⌘V to paste" (neutral styling, not error colors).

**success** — pill shrinks to a 48×48 circle (`.expressiveFastSpatial`), Material check draws on (trim-path, 250ms `emphasizedDecelerate`) in Google Green `#34A853` (light) / `#6DD58C` (dark). Holds 350ms, then collapses to idleDot (`.defaultSpatial`) with `.defaultEffects` fade. Total success dwell ≈ 700ms. Optional (Settings, default on): word count "42 words" `Label S` under the check for dictations >20 words.

**error** — surface animates to `errorContainer` (`.fastEffects` — color never bounces), icon `!` in `onErrorContainer` + message `Label M`: "Couldn't transcribe — saved to History" + inline **Retry** text button. Entry includes a 250ms horizontal shake (3 cycles, ±4pt, custom `timingCurve`) — the one deliberately non-M3 gesture, kept subtle. Auto-dismiss 6s; Esc dismisses; Retry re-runs from the on-disk CAF. Never lose words: the copy always names where the words went.

**secureField** — `IsSecureEventInputEnabled()` true at key-down: pill appears in neutral surface with shield glyph + "Secure field — dictation paused" `Label M`. No recording starts. Auto-dismiss 2.5s. (Detection per macos-architecture.md TN2150 polling.)

**offline** — dictation still works: listening state gains a small cloud-off badge (12pt, `onSurfaceVariant`) next to the timer; on release, instead of processing → "Saved — will transcribe when you're back online" (neutral), queued item visible in History. IdleDot shows a 4pt amber (`#FBBC04`) dot at its right end while the queue is non-empty.

### 1.4 Waveform rendering
- **5 rounded bars** (Gemini Live "condensed into a tiny pill" aesthetic): bar width 6pt, gap 4pt, radius 3 (full), heights 8–32pt inside the 48pt pill, vertically centered, Google Blue `#4285F4`.
- Driver: audio tap publishes 5 log-spaced band energies (Accelerate vDSP FFT, 512-sample windows) at 60Hz to an `@Observable` model; render with `TimelineView(.animation)` + `Canvas`. Per-band EMA smoothing: attack coefficient 0.35/frame, release 0.08/frame (fast rise, slow fall — the "alive" look). Idle undulation when silent: ±2pt sine at 0.8Hz with per-bar phase offset 0.5rad (Gemini Live's calm idle breathing).
- Perf: shallow view hierarchy, one Canvas; if profiling shows drops on 120Hz/Intel, fall back to CALayer + CADisplayLink (per macos-architecture.md guidance). Budget ~5ms/frame.

### 1.5 Four-color processing treatment
- Bars keep their frozen silhouette and animate a **left-to-right traveling gradient** through the Google quad `#4285F4 → #EA4335 → #FBBC04 → #34A853`, gradient width 2× pill, `background-position` style sweep, loop 1.2s, linear. Simultaneously bar heights run a gentle 4-phase chase (each bar `.slowEffects`-eased between 10pt and 22pt, staggered 120ms) — reads as "thinking," echoes the Aug-2025 Gemini overlay's four-color glow **without** copying the Assistant four-dot mark (bars stay bars).
- Plus a 1.5px **edge glow** around the pill using the classic AI-shimmer gradient (`#4285F4→#9B72CB→#D96570`), opacity 35%, same 1.2s sweep. This gradient family appears ONLY in processing — it is the "AI is working" signature, never decoration.

### 1.6 Full transition table

| Transition | Spatial | Effects/other |
|---|---|---|
| hidden → idleDot (launch) | `.slowSpatial` scale-up | `.slowEffects` fade; one "breath" pulse after settle |
| idleDot → listening | `.expressiveDefaultSpatial` width+height | `.defaultEffects` content fade-in |
| listening → locked | `.expressiveFastSpatial` width | lock glyph `.fastEffects` fade |
| listening/locked → processing | `.defaultSpatial` width | color-to-gradient `.defaultEffects` |
| processing → inserting | `.fastSpatial` bar collapse | `.fastEffects` |
| inserting → success | `.expressiveFastSpatial` circle morph | check draw 250ms `emphasizedDecelerate` |
| success → idleDot | `.defaultSpatial` collapse (after 350ms hold) | `.defaultEffects` fade |
| any → error | shake 250ms custom | surface color `.fastEffects` |
| error/secure/offline → idleDot | `.defaultSpatial` | `emphasizedAccelerate` 150ms fade-out |
| any → hidden (Esc cancel) | `.fastSpatial` shrink | `emphasizedAccelerate` 150ms |

---

## 2. Sound design — G-major earcon family

Philosophy (Pixel sound team): simple, human, playful; short (<400ms), rounded attacks, quiet (~-20dBFS peak, mixed toward -23 LUFS); design the silence — NO sounds on hover, buttons, or menu actions. Soft mallet/marimba + sine underlayer timbre.

| Event | Musical spec | Envelope | Bootstrap file (CC-BY Material pack) |
|---|---|---|---|
| **start** (key down) | D5 grace → G5 rise (4th up, tonic landing — "Super G" lineage) | 160ms; attack 8ms, decay 220ms tail | `navigation_forward-selection-minimal` |
| **stop** (release → processing) | G5 → D5 fall (mirror of start) | 140ms | `navigation_backward-selection-minimal` |
| **lock** (hands-free) | G4→B4→D5 ascending triad arpeggio | 240ms, 60ms note spacing | `state-change_confirm-down` |
| **success** (text inserted) | Bright G5 tap over soft G4 octave undertone | 180ms | `state-change_confirm-up` |
| **cancel** (Esc) | Single muted D4, felt-piano damp, −20¢ bend | 120ms | `navigation_cancel` / backward-selection |
| **error** | F♯4+G4 semitone dyad, muted, dull | 150ms | `alert_error-01` (quietest of the 3) |
| **celebration** (onboarding only) | G-major flourish | <1.2s | `hero_simple-celebration-01` |

- Implementation notes for the spec: preloaded `AVAudioPlayer` instances (`prepareToPlay`) for <10ms trigger latency; earcon fires on the same state-machine transition tick that starts the matching animation (Pixel's frame-sync principle: start sound onset = pill inflation start; success chime peak ≈ check-draw completion). Respect System Settings "Play user interface sound effects" (route/flag per macos-architecture.md `kAudioServicesPropertyIsUISound` note). Single Settings toggle "Sounds" + volume slider.
- Ship plan: v1.0 uses the Material pack files (with CC-BY 4.0 attribution in About + `CREDITS.md`); v1.x replaces with original recordings to the musical spec above (same filenames/keys so it's a drop-in).
- Known consideration: the start chime can bleed into the built-in mic recording; keep it short/quiet and note in the steering prompt that a brief chime may precede speech.

---

## 3. Design tokens file spec (`DesignTokens.swift`)

One file, no magic values anywhere else in the app. Structure:

```swift
enum GT {
  enum Color { /* semantic, each with light/dark */ }
  enum Type { /* text styles as Font + axis settings */ }
  enum Radius { }  enum Spacing { }  enum StateLayer { }
  enum Motion { /* §0 table */ }  enum Elevation { }
}
```

**Colors (light / dark)** — GM3 production values:
- `primary #0B57D0 / #A8C7FA`; `onPrimary #FFFFFF / #062E6F`; `primaryContainer #D3E3FD / #0842A0`; `onPrimaryContainer #041E49 / #D3E3FD`
- `surface #FFFFFF / #1E1F20`; `surfaceContainer #F0F4F9 / #28292A`; `windowBackground #F8FAFD / #131314` (never `#000`)
- `onSurface #1F1F1F / #E3E3E3`; `onSurfaceVariant #444746 / #C4C7C5`; `outline #747775 / #8E918F`; `outlineVariant #C4C7C5 / #444746`
- `error #B3261E / #F2B8B5`; `errorContainer #F9DEDC / #8C1D18`; `onErrorContainer #410E0B / #F9DEDC`
- `success #146C2E / #6DD58C`
- Brand quad (waveform/processing/celebration ONLY): `gBlue #4285F4, gRed #EA4335, gYellow #FBBC04, gGreen #34A853`; `aiShimmer = [#4285F4, #9B72CB, #D96570]`
- `StateLayer`: hover 0.08, focus 0.10, pressed 0.10, dragged 0.16 (of the on-color).

**Type** — bundled Google Sans Flex VF (`OFL.txt` shipped; fallback Roboto Flex → system):
- `display` 32pt wght 400, opsz 32, ROND 20 (onboarding hero)
- `headline` 24pt wght 400, opsz 24, ROND 15
- `title` 16pt wght 500, opsz 17
- `bodyLarge` 16/24 wght 400, opsz 17 (history transcripts)
- `body` 14pt wght 400, opsz 17
- `label` 12pt wght 500, opsz 17 (pill status text); `labelSmall` 11pt wght 500
- `numeric` = label + tabular figures (timers, stats)
- `code` = Google Sans Code 13pt wght 400 (API key field, endpoint override)
- Global: `GRAD 0` light / `GRAD +25` dark (thicken dark-mode strokes without layout shift), `slnt 0`.

**Radius**: 4 (xs — focus rings), 8 (small — chips), 12 (medium — menus/popovers), 16 (large — cards), 28 (xl — onboarding cards/sheets), `.full` (pill, buttons). **Spacing**: 4/8/12/16/20/24/32/40. **Elevation**: shadow presets for levels 1/3/6 + surface-tint overlay in dark mode.

---

## 4. Menu bar icon + menu

**Icon**: original 18×18 template glyph — a tiny pill outline containing 3 waveform bars (our mark; NOT the Gemini spark, NOT four circles). States via `NSStatusItem` custom view (MenuBarExtra can't animate):
- idle: static glyph
- listening: 3 bars animate (30fps equalizer; static filled variant under Reduce Motion)
- processing: bars run a subtle sequential opacity pulse
- queued/offline: small dot badge at lower-right
- needs-permission / paused: glyph at 40% opacity + dot badge
Always template/monochrome (menu bar convention; macOS shows its own orange mic indicator anyway).

**Menu** (minimal, static, no submenpunking):
1. Status line (disabled item): "Ready — hold fn to talk" / "Listening…" / "2 recordings waiting for network"
2. Start Dictation (shows toggle shortcut)
3. Paste Last Transcript
4. ─
5. History…  ·  6. Dictionary…
7. ─
8. Microphone ▸ (System default + device list, checkmark)
9. Hide Pill for 1 Hour
10. ─
11. Settings… ⌘,
12. Help ▸ (Setup Guide · Check for Updates… · Report an Issue · About)
13. Quit

---

## 5. Onboarding flow (first-launch window, 760×560, radius-28 card look, one screen at a time, progress dots)

Copy voice: short, warm, plain-spoken, playful-not-cute ("simple, human, playful"). Every screen: headline in `display/headline` style with ROND, one sentence of body, one primary pill button.

**S1 Welcome** — animated hero: the actual pill component demoing idle→listening→success on loop above the fold. Headline: **"Speak. It types."** Body: "Hold a key, say the thing, and polished text lands wherever your cursor is." CTA: "Get started". (Secondary link: "How it works" → expands 3-bullet privacy summary: audio → your Gemini key → text; history stays on your Mac.)

**S2 Your Gemini key** — headline "Bring your own key." Body: "[App] uses your Gemini API key. It's stored in your Mac's Keychain and only ever sent to Google." Paste field (`code` style, concealed after validation) with **paste-and-validate**: on paste, inline M3E shape-morph loader → GET `v1beta/models` with the key → success = green check + chip showing resolved model; failure = inline error "That key didn't work — check it in AI Studio." Link: "Get a key in Google AI Studio" (opens aistudio.google.com/apikey). "Skip for now" allowed (app enters setup-needed state).

**S3 Microphone** — permission card: status dot + "Allow microphone" button → `AVCaptureDevice.requestAccess`. On grant, the card turns into a **live level meter**: "Say hello — we're listening." (waveform reacts; instant delight + confirms the right device). Live-polls status; if denied, shows deep-link button to Settings pane.

**S4 Accessibility** — headline "Let it type for you." Body: "macOS needs your OK before [App] can place text at your cursor." Card with Grant button → `AXIsProcessTrustedWithOptions` prompt + deep link `x-apple.systempreferences:...Privacy_Accessibility`; **live polling every 1s** flips the card to a green check the moment it's granted (with the known Ventura+ caveat handled: if stale after 10s, show "Granted but not detected — a relaunch may be needed" + Relaunch button).

**S5 The Globe key** — shown only if user path uses fn AND `defaults read com.apple.HIToolbox AppleFnUsageType != 0`. Headline "Make the 🌐 key yours." Body: "macOS currently uses the Globe key for emoji. One switch and it's your dictation key." Button opens Keyboard settings; illustrated instruction "Press 🌐 key to → **Do Nothing**"; live-poll the default and auto-advance on success. Detect Karabiner-Elements and show a soft warning card ("Karabiner may capture fn — add [App] to its exclusions"). "Use a different key instead" escape hatch → S6.

**S6 Choose your key** — three preset cards: **Hold fn** (recommended, Apple keyboards), **Hold right ⌘**, **Hold ⌥Space**, + "Custom…" (recorder validating against OS-reserved combos). Explains the grammar inline: "Hold to talk. Double-tap to lock hands-free. Esc to cancel."

**S7 Try it** — the interactive tutorial. A big friendly text area with placeholder "Your words will land here." Prompt chip: "Hold your key and tell us the best thing you ate this week." The REAL HUD pill appears at the bottom of the screen (not a mock). On successful insertion: **confetti burst in the four Google colors** (~80 particles, 1.5s, `.expressiveSlowSpatial` physics; skipped under Reduce Motion → static four-color checkmark card) + `hero_simple-celebration-01` + stat line: "You just wrote 23 words in 6 seconds. That's ~230 WPM." Optional second chip: "Now try double-tap to go hands-free." Esc teaching happens naturally if they cancel.

**S8 Done** — summary card: chosen key, menu-bar callout ("We live up here now →" with arrow to the status item, which does one bounce), visible **"Start [App] at login"** checkbox (default ON but explicitly on-screen — consent by visibility; never silently re-added, the #1 Wispr gripe). CTA "Start dictating." Window closes; idleDot breathes once.

---

## 6. History, Dictionary, Settings IA (minimal-Googley, anti-Superwhisper)

One main window ("[App]" from menu → History/Dictionary), plus standard macOS Settings (⌘,). No modes, no per-mode model pickers, no prompt editors in v1 — the model handles formatting.

**History window** (default tab; 760×560, sidebar-less; segmented control History | Dictionary):
- Header stats card (Wispr's proven gamification, kept subtle): total words · current streak · avg WPM. `numeric` style, four-color mini bar accents.
- Search field; list grouped by day. Row = transcript first line (`bodyLarge`), target-app icon, duration, time, status chip when relevant ("Queued — offline", "Failed — Retry"). Hover actions (8% state layer): Copy · Insert again · Retry · Delete.
- Queued/failed items pinned in a banner at top: "2 recordings waiting — we'll keep trying." (never-lose-words made visible).
- Row click → detail: full text with **Cleaned / Raw toggle** (raw transcript always preserved), audio player (while audio retained per retention setting), "Add words to Dictionary" quick action, metadata footer (model, duration, app).
- Empty state: original four-color abstract mini-illustration + "Nothing here yet. Hold fn and say hello."

**Dictionary** (single screen): top field "Add a word or phrase…"; entries list: word, optional "Gemini hears it as…" misspelling mapping (one rule per word), star to prioritize, sparkle ✨ badge on auto-learned entries; search; CSV import/export via context menu. Learned entries flow in from the auto-learn loop with a toast (§7).

**Settings** (4 tabs, that's the cap):
1. **General** — hotkey recorder (PTT + hands-free), double-tap-lock toggle, launch at login, idle indicator (Always/While dictating), language (Auto-detect + preferred-languages list)
2. **Dictation** — microphone picker, Sounds toggle + volume, mute music while dictating (off by default), Smart formatting (on) / Verbatim mode, per-app trailing-period suppression (on)
3. **Privacy & Storage** — keep audio (7 days default / 30 / forever / never), history retention, "What leaves your Mac" explainer, Clear history
4. **Advanced** — API key (change/re-validate, Keychain-backed), custom endpoint + model override (`code` style fields), optional cleanup-pass model toggle (flash-lite, off by default), diagnostics log toggle

---

## 7. Delight details (the Google-grade small touches)

1. **Learned-word toast**: small pill toast above the HUD, sparkle icon: "Learned 'Kubernetes'" — tap to undo. (`.expressiveFastSpatial` in, auto-dismiss 3s.)
2. **Too-short press coaching**: tap (<0.3s) on the PTT key → pill shows "Hold to talk — double-tap to lock" once per session; never an error sound.
3. Hover states everywhere at exactly 8%; pressed 10%; no borders appearing on hover (color layers only).
4. Empty states with original four-color abstract illustrations (dots/bars, never the spark).
5. Milestone toasts (10k/100k words) with one confetti burst; streak counter in History header.
6. Idle dot "breathes" once on launch and after wake-from-sleep — "I'm here."
7. Menu-bar icon does a single 2pt bounce when a queued offline recording finally transcribes.
8. Word-count under the success check for long dictations ("128 words").
9. About window easter egg: the pill bounces with `.expressiveSlowSpatial` physics when clicked; credits list OFL/CC-BY attributions beautifully instead of burying them.
10. Rotating idle-dot tooltips teach one feature at a time ("Double-tap fn to go hands-free").
11. Retry succeeded state: History row does a brief green sweep (`.defaultEffects`).
12. First dictation of the day: nothing. Restraint is the delight — no daily greetings, no badges on the pill.

---

## 8. Accessibility

- **VoiceOver**: HUD panel is an accessibility element, role group, label "[App] dictation"; state changes posted as announcements: "Listening", "Hands-free — locked", "Processing", "Inserted 42 words", "Error — transcript saved to History", "Secure field — dictation paused". Stop/cancel buttons labeled with action + result ("Stop dictation and insert text"). Menu bar item: "Dictation — ready/listening/2 queued". All onboarding fully keyboard-operable (full keyboard access), permission cards announce status changes.
- **Reduce Motion** (`accessibilityDisplayShouldReduceMotion`): all spatial springs → 150ms crossfades; waveform → static 5-bar level meter with opacity-only response; four-color processing sweep → static four-color bars + gentle opacity pulse; confetti → static celebration card; shape-morph loader → three-dot fade; shake → none (color+icon carry the meaning).
- **Reduce Transparency**: solid `surface`/`surfaceContainer` instead of blur material. **Increase Contrast**: 1px `outline` borders on pill and cards.
- **Contrast**: all text ≥4.5:1 (`onSurface #1F1F1F` on `#FFFFFF`; `#E3E3E3` on `#1E1F20` both pass; pill status text uses `onSurface`, never `onSurfaceVariant`, at 12pt). Waveform is decorative (exempt) but pairs with the timer/state text. Never color-only signaling: success = check shape, error = icon + text, offline = badge + copy.
- Sounds are always redundant with visuals; app fully usable with sound off and with VoiceOver + sound both on (earcons don't collide with VO announcements — earcon first, announcement after 100ms).

---

## 9. Do-NOT-do list (trademark + anti-patterns)

- NO Gemini spark, no four-adjoining-circles negative-space construction, no rounded-four-point stars.
- NO Google "G" logo, no "Google"/"Gemini" in app name or icon; icon is our original pill-waveform mark.
- NO Assistant four-bouncing-dots animation verbatim (our processing treatment keeps bars as bars).
- NO proprietary Google Sans/Product Sans — only OFL Google Sans Flex/Code/Roboto Flex, with OFL text shipped.
- NO Material sound files without CC-BY 4.0 attribution in-app.
- NO Siri-style orb, no fullscreen takeover UI, no notch gimmick in v1.
- NO auto-send after dictation by default (ChatGPT's auto-send regression), no removing review-ability: History always holds everything.
- NO login-item re-adding, no telemetry/analytics SDKs, no screenshots/AX scraping (Wispr's wounds are our positioning).
- NO sounds on hover/click/menus; no pill stealing focus, ever; no blocking modal error dialogs.
- NO #000 backgrounds; no bouncing opacity/color (effects springs are damping 1.0, always).

---

## Implementation sequencing (design-side)

1. `DesignTokens.swift` + `MotionTokens.swift` (everything depends on them)
2. HUD panel + pill state machine + waveform (states hidden/idle/listening/processing/success first; error/secure/offline once the pipeline lands)
3. Earcon player + Material pack integration (wire to state machine transitions)
4. Menu bar icon/menu
5. Onboarding flow (needs permissions plumbing from the architecture workstream; S7 needs the real pipeline)
6. History/Dictionary/Settings windows
7. Delight pass + accessibility audit (VoiceOver + Reduce Motion walkthrough as a release gate)

### Critical Files for Implementation
- /Users/ammaar/Development/google-transcribe/Sources/App/DesignSystem/DesignTokens.swift (colors, type w/ Flex axes, radii, spacing, state layers, motion springs — §0, §3)
- /Users/ammaar/Development/google-transcribe/Sources/App/HUD/PillView.swift (pill state machine, per-state layouts, transition table — §1.2–1.3, 1.6)
- /Users/ammaar/Development/google-transcribe/Sources/App/HUD/WaveformView.swift (5-bar Canvas renderer + four-color processing treatment — §1.4–1.5)
- /Users/ammaar/Development/google-transcribe/Sources/App/Sound/EarconPlayer.swift (preloaded G-major earcon family, motion-synced triggers — §2)
- /Users/ammaar/Development/google-transcribe/Sources/App/Onboarding/OnboardingFlow.swift (8-screen flow incl. live-polling permission cards and the interactive tutorial — §5)

## RISKS
- fn/Globe onboarding friction: the AppleFnUsageType step (S5) requires a manual System Settings change and conflicts with Karabiner-Elements; it is the most likely drop-off point — the alternate-hotkey escape hatch must be prominent or activation rates will suffer.
- Trademark proximity: the four-color processing sweep, AI-shimmer edge glow, and a 'spark-adjacent' aesthetic sit close to protected Google/Gemini brand assets; since the author is a Googler shipping open source, the icon and processing treatment should get an informal brand/legal sanity check before public release.
- Google Sans Flex has no upstream source repo (google/fonts issues #10006/#10077); the served TTF is OFL-labeled but this should be re-verified and the exact font file + OFL text pinned in-repo before v1 ships.
- Batch-up/stream-down API means processing-state duration is variable (roughly 1–8s for long dictations); if real-world latency regularly exceeds ~2.5s the success/processing choreography will feel slow regardless of polish — the '>4s Still working' state and History fallback must be tuned against measured latency, and the pseudo-streaming transcript preview may need to be pulled forward from 'future experiment'.
- Waveform + gradient sweep at 60–120Hz in SwiftUI Canvas may drop frames on Intel/older machines; the CALayer/CADisplayLink fallback should be budgeted, not treated as optional.
- Start earcon can bleed into the recording on built-in mic/speakers and appear in transcripts as noise; needs empirical testing (mitigations: quiet/short chime, steering-prompt note, or 150ms record-head trim).
- Celebration/streak/WPM gamification can read as gimmicky to a segment of users; all of it must remain individually subtle and the stats card non-blocking, or it undermines the 'restraint is the delight' positioning.
- Success-state clipboard-fallback messaging ('press ⌘V') depends on insertion-ladder outcomes owned by another workstream; if that contract changes, the inserting/success/error state copy and flows here must be revisited.

## OPEN QUESTIONS
- App name and icon mark: needs an original spark-free identity before the menu bar glyph, About screen, and onboarding copy can be finalized (placeholder '[App]' used throughout).
- Default idle-dot visibility (Always vs While-dictating-only): spec says Always, but this should be validated in dogfood since Superwhisper's always-visible overlay drew 'intrusive' complaints.
- Exact Material CC-BY pack filenames: the pack's 40 files should be auditioned to confirm the proposed mappings (e.g. whether a 'lock'-suitable primary system sound exists) before wiring keys.
- Should the success state show word count by default, or only above a threshold (currently spec'd: >20 words, toggleable)?
- Localization scope for v1 onboarding/HUD copy (English-only vs matching the multilingual dictation story where ~60% of Wispr dictations are non-English).
- Whether the four-color processing treatment needs a mono-blue variant for users who find it too loud (a 'calm mode' token swap is cheap if decided early).
