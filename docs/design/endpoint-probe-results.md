# Endpoint probe results — 2026-08-17

Day-0 reality probe of `gemini-3.5-transcribe-preview` (and the cleanup-pass candidates)
against live traffic. These results **supersede the assumptions** in PLAN.md /
product-reliability.md wherever they differ.

## The transcribe model

| Fact | Result |
|---|---|
| Endpoint | `POST /v1beta/models/gemini-3.5-transcribe-preview:streamGenerateContent?alt=sse`, `x-goog-api-key` header works |
| Methods | `generateContent`, `countTokens` (no caching, no batch) |
| **`audioTranscriptionConfig.wordTimestamp: true` is REQUIRED** | With `{wordTimestamp:false, diarization:false}` or no config at all, the model returns an **empty transcript** with `finishReason: STOP`. Always send `wordTimestamp: true` (no timestamps appear in the response for short clips; the flag simply gates transcription). |
| **Steering prompts are ignored** | A text part rides along but counts as ~1 token and has zero effect: fillers kept, spoken punctuation left as words, self-corrections untouched. This is a *pure* transcription model. Consequence: it also **never answers questions** in the audio — answer-mode risk lives only in the cleanup pass. |
| **No streaming** | SSE delivers the entire transcript in one event after full processing (`first_event == total`). The HUD streaming-transcript preview is confirmed CUT (critic reconciliation #3). |
| Latency (warm, ~2–5s clips) | **1.3–2.0s total** (one cold-start outlier 4.2s). Scale-invariant for short clips. |
| Latency (10-min clip) | ~25s total. Slow-state UI + progress choreography required for long dictations. |
| Request size | 17.5MB payload (10-min FLAC, base64) **accepted**. 10-minute recording cap confirmed viable; token limit (98,304; audio ≈ 25 tok/s ⇒ ~65 min) is not the binding constraint. |
| Knobs | `temperature: 0` OK. `safetySettings BLOCK_NONE` OK. `thinkingConfig` → **400 "Thinking is not enabled for this model"** — never send it. |
| Quality | Verbatim-with-punctuation transcription was flawless on all fixtures, including capitalization and question marks. |
| Sibling model | **`gemini-3.5-transcribe-live-preview`** exists, `bidiGenerateContent` only (Live API WebSocket) — the future path for true real-time partials (v1.x+ experiment). |

## The cleanup pass (now v1 CORE, not optional)

Because the transcribe model ignores steering, all smart formatting (filler removal,
self-correction collapse, spoken punctuation, per-app tone, dictionary spelling) moves
to a second text-model call. Probe results (temp 0, ~350-token prompt, 4 test cases):

| Model | Config | Median total | Quality |
|---|---|---|---|
| **gemini-2.5-flash-lite** | `thinkingBudget: 0` | **0.30s** | Perfect on all 4 cases |
| gemini-2.5-flash-lite | no thinking config | 0.26s | Perfect |
| gemini-3.5-flash-lite | `thinkingBudget: 0` | — | **400 invalid argument** (do not send) |
| gemini-3.5-flash-lite | no thinking config | 0.56s | Perfect (thoughts=0 anyway) |

Test cases all passed on the winner: self-correction ("at two, actually, no, three" →
"at 3"), spoken punctuation ("period"/"comma"/"new line" → symbols/break), question
preserved un-answered, instruction-injection transcribed not obeyed.

**Decision: cleanup model = `gemini-2.5-flash-lite`, `temperature 0`,
`thinkingConfig.thinkingBudget 0`,** overridable in Settings. Hard deadline 1.5s; on
miss or validation-gate failure, insert the raw transcribe output (which already has
punctuation — the raw fallback is high quality).

## Revised end-to-end latency budget (key-up → inserted)

| Stage | Short clip (≤30s) |
|---|---|
| FLAC transcode at key-up | 5–15ms (measured) |
| Upload + transcribe (one lump) | 1.3–2.0s |
| Cleanup pass | 0.25–0.6s |
| Gate + replacements + insert | ~50ms |
| **Total p50 expectation** | **~1.7–2.3s** |

At the real-world Wispr par (users report 1–2s). Sub-second requires the live
(bidi) model — future work. Perceived speed rests on the processing choreography +
earcons, not text streaming.

## Architecture deltas vs the plan

1. **Two-call pipeline is v1 core** (transcribe → cleanup). The plan's "CleanupPass is
   v1.x" is reversed; "smart formatting = steering prompt" is dead.
2. Upside: the true raw transcript exists → the **two-call validation gate** from
   product-reliability.md §3.4 (word-ratio ∈ [0.55, 1.35] + content-word Jaccard ≥ 0.5 +
   trigram overlap ≥ 0.55) replaces the weaker single-call plausibility gate.
3. Dictionary: no ASR-level biasing exists → vocabulary rides in the cleanup prompt +
   deterministic post-replacements only.
4. Transcribe requests carry **no text part** (ignored; saves payload) and MUST set
   `audioTranscriptionConfig {wordTimestamp: true, diarization: false}`.
5. Verbatim mode = skip the cleanup call entirely (also the auto-degrade path).

## Probe environment note

The key used is an internal/EAP account exposing 1,023 models. Public keys may expose
fewer models/quotas — the app treats model IDs as configurable and handles 404/403 on
model names gracefully (fall back + Settings deep link).
