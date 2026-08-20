# Latency audit — 2026-08-19 (measured on Ammaar's M-series + AirPods)

40-agent hot-path audit, every finding adversarially verified with measurements.
**Fixed** in 062dcbc, 3e70bb3, 3280904: capture prewarm (75–147ms → 22–25ms), HAL tail
drain (+85–104ms of speech recovered per session), speech-aware carry-over past key-up,
async teardown, earcon route warm-up, Chromium a11y wake moved to session start, AX
messaging timeout, Sauce warm, 100ms paste sleep deleted, launch work off the main
actor, SQLite WAL, waveform redraw capped.

**Measured baseline after those fixes:** idle 0.0% CPU / ~90MB; recording ~13% CPU
(dominated by SwiftUI view updates, see below); launch process-up ~141ms.

## Still open (verified, not yet done)

### [DONE 2026-08-19] [P2] "capture start" stops the clock at engine.start() return, not at the first tap buffer — the HAL spin-up window (≥21.3 ms floor, ~100 ms typical) is invisible, and the new prewarm path is about to make the metric look ~10x better while lost speech is unchanged

> **Implemented.** `AudioCaptureEngine.logFirstBufferIfNeeded` now logs the
> interval from `start()` to the FIRST tap buffer, with the transport type
> (`built-in` / `bluetooth` / `aggregate` / …) and the real tap format. Two
> reasons this had to land before anything else in the noise work: it is the
> only honest measure of the window where speech is lost, and any
> voice-processing watchdog must have its deadline set per-transport from these
> numbers — a fixed 400 ms would false-positive on every AirPods session.
> The stale "~47Hz" comment at the tap install is corrected in the same change.
- **Win:** Zero user-visible latency and zero CPU — this buys measurement, not speed. Runtime cost of the fix itself: one compare inside an existing lock per buffer (~2 ns, no added lock acquisition) plus 2 os_log calls per session off the realtime thread (<0.1 ms total). What it exposes: a window that is ≥21.
- **Fix:** Two numbers, no protocol change, no per-buffer cost. (Line anchors are the working tree as read; rebase onto whatever the concurrent prewarm edit settles at.)

1. ENGINE SIDE — measure start() → first frame actually on disk, reusing the lock and the branch that already exist.

Add a stored property beside the other stateLock-guarded fields (~:42-45):
    private var startClock: DispatchTime?

In `

### [P2] Session-folder mkdir + atomic meta.json write block the main actor between the .warming publish and the pill paint
- **Win:** Removes 0.265 ms median / 0.514 ms p95 / 1.616 ms max (measured, N=400, Apple Silicon NVMe warm) from key-down → pill-visible; roughly 1-2 ms p95 on the mission's worst-case Intel/SATA target. Sub-frame either way — this does not move the frame the pill lands on, and no user will perceive it in isol
- **Fix:** Three edits. The load-bearing one is (2)+(3); (1) and (4) are cheap hygiene.

1. `JotCore/Sources/Support/FileLayout.swift` — hoist the formatter and split path computation from IO. `makeSessionFolder`'s only non-main-actor caller is none (DictationCoordinator is @MainActor), so a plain static is safe; add `nonisolated(unsafe)` if strict concurrency objects, matching the existing `static var overr

### [P1] CGWindowListCopyWindowInfo blocks the main thread before the pill's first paint on every session start
- **Win:** Removes 100% of a synchronous WindowServer IPC from the key-down -> pill-paint block, once per session.

Measured on this M4 Pro (idle, 33 on-screen windows, 280 samples, -O): -0.30 to -0.66 ms median, -0.65 to -4.27 ms p95, -7.41 ms p99, -8.97 ms max. Measured scaling: 581 windows costs 4.29 ms med
- **Fix:** Two changes in App/Sources/HUD/PillHUDController.swift. Do NOT reorder DictationController.swift:475/:476 — that buys nothing (see reasoning).

(1) Single-display early-out — one line, exactly equivalent, kills the round-trip for most users. At the top of `screenOfFocusedWindow()` (PillHUDController.swift:70):

    private static func screenOfFocusedWindow() -> NSScreen? {
        // One display: 

### [P2] Redundant CoreAudio name lookup in AudioCaptureEngine.start()'s log defer (real, but ~64µs — P2, not P1)
- **Win:** ~64us median (81us p90, 258us worst observed) of main-thread time removed per session start, plus one eliminated CoreAudio HAL round-trip per session. Measured on this machine with a Bluetooth device (AirPods Pro 3) as the system default input, so this is already the claimed worst case. Zero percept
- **Fix:** Two edits, both in JotCore/Sources/AudioEngine (same module, so no access-level widening beyond dropping `private`).

1. `/Users/ammaar/Development/jot/JotCore/Sources/AudioEngine/AudioInputDevices.swift:85` — drop `private` so the engine can resolve a name from an ID it already holds:

    static func name(of id: AudioDeviceID) -> String?

2. `/Users/ammaar/Development/jot/JotCore/Sources/AudioEn

### [P2] Tap buffer is clamped to a 100 ms floor — the "~47 Hz level meter" comment is wrong by 4.7x (real rate 10 Hz), but the visible symptom is smeared syllables, not a choppy waveform
- **Win:** Zero milliseconds on the critical path and no measurable CPU change — I want to be blunt about that, because the claim's headline ("4.7x worse than the code believes") reads like a latency win and there is none. Five vDSP_rmsqv calls over the same 2400 samples cost the same ~0.1 us as one, fired 10x
- **Fix:** Do NOT implement the claim's "emit 5 levels" fix — it is a regression (see reasoning #2). Keep onLevel firing once per buffer; change only what each value MEANS, and correct the comments.

In JotCore/Sources/AudioEngine/AudioCaptureEngine.swift:

1) Replace the stale block at :55-58 (delete the two vestigial ivars):

    // Level metering. The tap cannot deliver faster than 100 ms: AVAudioNode.h
 

### [P1] capture.start() blocks the main actor 111–258 ms, and the one-tick deferral does not actually let the pill paint first
- **Win:** Pill first-paint after key-down: measured 121.2 ms → 4.6 ms at a 120 ms engine cost (116.6 ms saved), instrumented against a real NSHostingView. Against the engine costs I measured on this Mac with the built-in mic, that is ~110–135 ms saved on a typical dictation and ~255 ms on the first dictation 
- **Fix:** Move the engine build off the main actor onto the serial queue that already owns the buffer path. Four surgical edits:

1. AudioCaptureEngine.swift:58 — make `start` async and run the whole body on the existing `queue` (which already serializes with `ingest`, so the tap can never fire before `writer` is assigned):

```swift
public func start(writingTo url: URL) async throws {
    try await withChe

### [P1] One-tick deferral of capture.start() does not yield a frame — mic start still blocks the pill's first paint
- **Win:** Removes the mic start from between `setPill` and the CATransaction commit entirely. Warm path (steady state, spare available): 18.2–23.0 ms off the pill's first-paint path, median 19.1 ms — enough to land the paint inside one 60 Hz vsync (16.7 ms) instead of missing one or two, and inside one 120 Hz
- **Fix:** Two parts. Part 1 is mandatory — without it part 2 introduces a data race worse than the bug.

PART 1 — make the graph safe to touch from two threads (JotCore/Sources/AudioEngine/AudioCaptureEngine.swift). `stateLock` guards only the counters; extend a lock over the graph fields. Add `private let graphLock = NSLock()` and take it around (a) the whole body of `buildEngine(reason:start:)` (:153-208)

### [P1] Engine start still runs on the main actor behind two Combine paint blocks — but the "no warm engine" premise is stale
- **Win:** First-audio-frame: ~2 ms sooner on Apple Silicon, plausibly 5–15 ms on the 3-year-old Intel target (measured components: 1.40 ms CGWindowListCopyWindowInfo + 0.43 ms beginSession pre-work + two removed main-queue hops). Not the claimed 21–42 ms — that figure is an artifact of subtracting a `defer`-s
- **Fix:** Four changes, highest value first.

1. Wire the dead `refresh()`. `WarmEnginePool.swift:52` has no callers. Call it from `StatusItemController.selectMicrophone` (:193) after `AudioInputDevices.setDefault(id:)`, and better, register an `AudioObjectAddPropertyListenerBlock` for `kAudioHardwarePropertyDefaultInputDevice` in `AudioInputDevices` that posts a notification `DictationController` forwards 

### [P0] Every recording drops its final 0–104 ms (mean 52 ms): the in-flight tap buffer is discarded at teardown
- **Win:** Recovers a mean of 52.0 ms (max 104.0 ms) of end-of-utterance audio on 100% of sessions — measured from 47 real recordings, all of which quantize to exact multiples of 1664 frames (104.0 ms). Also closes the queued-buffer drop at AudioCaptureEngine.swift:83/:234, worth up to another 104 ms under dis
- **Fix:** Bounded, signal-driven tail drain — off the main actor, engine still torn down per session.

**1. `AudioCapturing` (AudioCapturing.swift:39)** — make stop async:
`func stop() async -> AudioCaptureResult`

**2. `AudioCaptureEngine`** — add a continuation guarded by `stateLock`:
```swift
private var tailSignal: CheckedContinuation<Void, Never>?
```
In `ingest`'s write-queue block, right after the su

### [P1] AX insertion tier runs unbounded synchronous cross-process round trips on the main actor
- **Win:** Worst-case main-thread block on "transcript ready → text visible" drops from the undocumented HIServices default (seconds-scale, unbounded) to ~250 ms. In practice better than 250 ms: against a wedged target the very first round trip at AXInserter.swift:32 times out, its `guard ... == .success` retu
- **Fix:** Apply part (1) only, plus one guard the original proposal omits. Do NOT move AXInserter off the main actor.

1. Bound every AX round trip this process makes. Per Apple's docs, setting the timeout on the system-wide element becomes the process-wide default, so this one line also covers the app element at :94 and the focused element. In `AXInserter.insert`, at AXInserter.swift:30:

    let system = 

### [P2] Audio upload envelope: base64 String + JSONSerialization costs ~6.5x the CPU of a hand-assembled body (real, but off-main and sub-ms on realistic clips)
- **Win:** CPU on the GeminiClient actor (background, not main thread), current -> fixed, measured p50: 5s clip 0.41 -> 0.05 ms; 10s 0.53 -> 0.08 ms; 30s 1.56 -> 0.21 ms; 60s 2.91 -> 0.40 ms; 600s (hard cap) 30.86 -> 4.65 ms. So ~0.4-1.4 ms saved on the realistic 5-30s dictation, ~26 ms at the 10-minute cap; ~
- **Fix:** Give `generateContent` a pre-built body and hand-assemble the audio envelope. Leave cleanup() on JSONSerialization — its prompt is user text that genuinely needs escaping.

In JotCore/Sources/TranscriptionClient/GeminiClient.swift:

1) Add the two constant halves (every byte is a fixed literal):

    // Hand-assembled: base64's alphabet (A-Z a-z 0-9 + / =) can never contain a
    // character JSON

### [P1] stop()'s drain barrier shares its serial queue with the config-change engine rebuild: 110–165 ms (up to ~2 s on Bluetooth) main-thread freeze at key-up, plus an unsynchronized engine/converter race
- **Win:** On the config-change-at-key-up path, the main-thread block at AudioCaptureEngine.swift:130 drops from a MEASURED 110–165 ms (M-series, built-in 24kHz route; 294 ms cold) — or 0.3–2 s on a Bluetooth HFP route per the repo's own numbers, and ~1.5–3x the 110–165 ms figure on a 3-year-old Intel Mac — to
- **Fix:** Three edits in JotCore/Sources/AudioEngine/AudioCaptureEngine.swift. Minimal, and each is load-bearing — the first alone leaves a mic that opens after stop().

(1) Give engine lifecycle its own serial queue so the drain barrier never waits on it. Next to :40:

    private let queue = DispatchQueue(label: "com.ammaar.jot.audio.write", qos: .userInitiated)
+   /// Engine lifecycle NEVER shares the w

### [P1] CAF→FLAC transcode runs entirely at key-up instead of streaming during recording
- **Win:** Key-up → bytes-on-the-wire, network excluded, measured on this M4 Pro (3 runs each): 5 s clip 3.97-9.67 ms → 0.24-0.33 ms (~4-9 ms saved); 60 s clip 24.81-29.93 ms → 0.27-0.42 ms (~25-29 ms saved); 600 s clip (the cap at DictationCoordinator.swift:44) 252.14-267.78 ms → 3.13-12.05 ms (~240-256 ms sa
- **Fix:** Stream the FLAC alongside the CAF, and make a clean close structurally provable rather than guessed.

1) AudioCaptureEngine.swift — add `private var flacWriter: AVAudioFile?` and `private var flacPartialURL: URL?` next to `writer` (:34).

In `start(writingTo url:)` (after :97) only record the path; do NOT open the file here. `start()` is the key-down→first-frame path deliberately kept lean (:30-32

### [P1] 47 Hz mic level invalidates the whole pill subtree through two async hops and adds zero frames
- **Win:** Recording phase: eliminates ~47-51 full PillRootView→PillView→WaveformView body evaluations per second for the entire duration of every session, plus ~50 discarded Smoother allocations/s and ~50 accessibility-label String builds/s. Canvas draws and frame rate are unchanged at ~63/s — the pill looks 
- **Fix:** Five changes, smallest set that holds the invariants.

1. PillModel.swift — stop routing level through @Published.
   Add `final class LevelBox { var value: Float = 0 }` and `let levelBox = LevelBox()` (main-actor confined, so no locking needed). Replace `@Published var level: Float`. Keep ONE low-rate `@Published var staticLevel: Float` for the Reduce Motion branch only.

2. DictationController.s

### [P2] History reload does a full-corpus word count on the main thread per search keystroke (and forever after the window is closed)
- **Win:** Measured, release build, M4 Pro. Fix (1): per-keystroke main-thread cost in the search field drops 5.4ms -> 1.5ms at 500 rows (-72%) and 17.1ms -> 1.5ms at 2000 rows (-91%), and becomes O(1) in corpus size instead of growing forever. On a 3-year-old Intel Mac (~3x this scalar string work) that is ~4
- **Fix:** Two small, independent changes. Neither touches crash-safe CAF writes, device pinning, blip/discard, or focus.

(1) Take the query-independent work off the keystroke path (this is the whole win — no async, no SQL rewrite, no cache invalidation to get wrong).

App/Sources/Windows/HistoryWindow.swift — split reload():

    private func reloadRecords() {
        records = store.records(matching: quer

### [P2] EventTapEngine.start() blocks the main thread in 10ms poll quanta (measured 12.5ms floor) on every launch
- **Win:** ~9-12 ms of main-thread block removed per engine.start(), once per launch: measured floor drops from 12.51 ms (one full usleep quantum, incurred 200/200 trials) to the true tapCreate cost of ~1-3 ms; a cold launch where tapCreate exceeds 12.5 ms drops from 25 ms to ~15 ms. CPU change is 0% (the poll
- **Fix:** Replace the poll with a per-attempt DispatchSemaphore. It must be created fresh inside each start() call — a stored semaphore signalled after a timed-out wait would leave a stale count that satisfies the NEXT start() instantly.

EventTapEngine.swift:96-114:
    let ready = DispatchSemaphore(value: 0)
    let thread = Thread { [weak self] in
        self?.threadMain(ready: ready)
    }
    thread.n

