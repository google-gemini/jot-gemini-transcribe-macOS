# Research: new-entrants
# Competitive Survey: Dictation & Voice-Input Products (2024–2026)

## 1. Aqua Voice (YC W24, aquavoice.com)
- **Differentiators**: (a) Proprietary STT model **"Avalon"** (launched Aug 2025), claims 97.3% accuracy on their "AISpeak" benchmark, positioned above Whisper/NVIDIA/ElevenLabs/AssemblyAI on technical speech (kubectl, PyTorch, GPT-4o etc.). (b) **"Your screen is its dictionary"** — reads on-screen content + active app/website to bias vocabulary and adjust tone (casual Slack vs formal Gmail vs technical Cursor). (c) **Latency claims**: startup <50ms, text insertion as fast as ~450ms; a Max-tier "real-time mode" streams text as you speak with per-word refinement.
- **Activation**: Mac = **hold Spacebar** (unusual choice); iOS press-and-hold; browser app at app.aquavoice.com.
- **Voice commands**: blends verbatim transcription with intent ("make this a list", "it's Erin with an E", "send it" in Max tier). Original Launch HN (news.ycombinator.com/item?id=39828686) described "6 models working together to transcribe, interpret, and rewrite"; WER 0.05–0.06 claim.
- **Dictionary**: 5 entries free, **800 entries Pro/Max**; custom instructions for style.
- **Pricing**: Free 1,000 words/mo; Pro $8/mo; Max $24/mo (real-time mode + voice commands); Team $12/user/mo.
- **Reviews**: HN praise "hands down one of the best AI demos"; dyslexic founder story resonates. Criticisms in HN launch: slow early demo, token-pricing confusion, missing privacy policy, accent degradation (Scottish), Firefox AudioContext bugs. 2026 Product Hunt 5.0.

## 2. Willow Voice (YC X25, willowvoice.com)
- **Differentiators**: (a) **~200ms processing latency claim** vs "700ms+ for most competitors". (b) iOS keyboard ships a **full QWERTY keyboard alongside voice** so you can manually fix a word without switching keyboards (TechCrunch 2025-11-12: Wispr Flow only exposes a numeric pad). (c) "AI Mode" expands short spoken prompts into full messages; desktop "Hey Willow" voice assistant composes replies.
- **Context**: looks at what you're working on for technical terms/names; style-matching learns your tone per app category (work/messaging/email).
- **Offline**: optional local-model fallback mode on Mac/iOS when wifi drops.
- **Pricing**: free 2,000 words/week recharging (no card), then $12/mo annual.
- **Traction**: 50k+ users, $4.5M raised (BoxGroup, YC; angels: Dharmesh Shah, Alexis Ohanian, Max Mullen), 50% MoM growth. Mullen quote: fewer edits than built-in dictation.

## 3. Monologue (Every, monologue.to, launched Sep 23 2025; iOS Feb 2026)
- **Differentiators**: (a) **"Deep context" screen capture with permission** — sees your screen so it knows what you're referencing (file names inferred from surrounding code). (b) **Modes** — prebuilt workflows (Chatting, Email, Notes, Coding) plus custom instructions, auto-switched per app. (c) Expanding into **voice notes + bot-free meeting notes** (mic + system audio via Screen Recording permission, no meeting bot), synced across Mac/iPhone/iPad/Watch, exposed to agents via **MCP, API, and CLI**.
- **Dictionary**: proper nouns/acronyms/slang "remembered automatically."
- **Multilingual**: 100+ languages, mid-sentence switching.
- **Numbers**: beta 7,000 uses/day, 1M+ words/week; site claims 500M+ words dictated. Free 1,000 words; Pro $15/mo ($144/yr); in $30/mo Every bundle. Offline local-model transcription available on Mac free tier.
- **Reception**: PH 5.0 (small n); praised for "writes what you meant to say," Mac-only youth cited as limitation.

## 4. Voicenotes (voicenotes.com) & VoicePal
- **Voicenotes**: note-capture (not system dictation). Praised for ultra-low-friction capture (one tap), strong transcription, 100+ languages, iOS/macOS/watchOS, AI actions on notes (tweet/summary/email/to-dos), "ask about every word you spoke" chat over all notes, integrations (Notion, Todoist, Readwise, Zapier). Criticisms: crashes, cut-off/lost transcriptions, invented to-dos, failed uploads losing notes — reliability of capture is sacred.
- **VoicePal ("your AI Ghostwriter", Ali Abdaal-promoted)**: signature feature = **AI follow-up questions after you speak** — contextual, not generic — prompting you to expand ideas; plus topic prompts for journaling. Users call the interviewing loop "a game-changer." Idea: dictation as dialogue, not one-shot.

## 5. Wispr Flow (wisprflow.ai) — market leader reference
- **Activation**: hold a key (default fn) push-to-talk system-wide; "Flow Sessions" on iOS with auto-end times (5min/15min/1hr/never).
- **Signature features**: (a) **Auto-learn dictionary** — "Auto-add to Dictionary" monitors the pasted-into text box for your manual corrections and silently adds changed spellings to your personal dictionary. (b) **Tone matching** by app name (formal email vs casual chat). (c) **Command Mode** — select text, speak an edit ("make this more concise", "turn this into bullet points"). (d) **Whisper Mode** — works when whispering for open offices. (e) Filler-word removal, self-correction collapsing ("no wait, make that Tuesday" → final intent).
- **iOS keyboard** (4.8/5, 8,500+ App Store ratings): full QWERTY + top bar mic, waveform while recording, undo/redo chips after dictation, space-bar-as-trackpad, double-space→period, autocorrect skips digit-words/acronyms, static spinner under Reduce Motion. 9to5Mac coverage Jun 30 2025. Android app Feb 2026.
- **Complaints (Reddit/Trustpilot 2.7/5)**: reliability degrades post-trial ("works 60% of the time after payment"); latency creep as features added; audio sent to AWS (privacy backlash; CTO apologized after viral Reddit thread + banned user); heavy Electron app on Windows freezing target apps; screen-capture context feature raised privacy alarm. Praise: best-in-class onboarding, cleanup quality.

## 6. Apple built-in dictation (macOS 26 Tahoe / iOS 26)
- **Big platform change**: new **SpeechAnalyzer** class + **SpeechTranscriber** module (iOS 26/macOS Tahoe/visionOS) — on-device, ~**55% faster than Whisper Large V3 Turbo** (34-min video: 45s via Apple API vs 1:41 MacWhisper LargeV3Turbo vs 3:55 LargeV2; MacRumors 2025-06-18), comparable accuracy. Free, private, no network. This is the obvious engine for a local-fallback path or latency baseline.
- **Current UX**: double-tap fn (or mic key), auto-punctuation (commas/periods/question marks), emoji by voice ("heart emoji"), spoken commands ("new line", "new paragraph", "caps on"), dual-language mixing (iOS 18+), on-device language packs 30–100MB.
- **Persistent complaints** (Reddit/Apple Communities): ~30s silence timeout not configurable, interrupts long-form; fn double-tap conflicts with Karabiner/BTT/Raycast/Hyperkey; wrong-tone bug where dictation forgets input source; accuracy perceived as regressing (85–90%); random punctuation; text landing at wrong cursor position. These are the pain points a third-party app gets hired to fix.

## 7. ChatGPT voice UX (design reference)
- Two distinct affordances: **dictation** (waveform/mic icon → transcribe into composer) vs **Voice Mode** (two-way conversation, animated pulsing blue orb).
- 2025 redesign: voice no longer a separate takeover screen — talk while seeing responses stream as text in the normal chat ("Separate Mode" full-screen orb still optional).
- **Documented UX regression backlash** (OpenAI community forum): dictation used to place editable transcript in the message box before sending; a change that auto-sent removed the review step and users revolted — lesson: always allow review-before-commit, or make commit instant but undoable.
- Dictation model upgraded Whisper → gpt-4o-transcribe/mini (better accents/names/noise).

## 8. Gemini Live UX (design reference — closest to our Google-style brief)
- Material 3 Expressive + new "Gemini Intelligence"/Neural Expressive language: **waveform animation condensed into a tiny pill**, thinner icons, blur effects, overlay sheet redesign (androidauthority.com Gemini overlay deep dive).
- Live mode: distinct animated states for **listening / processing / speaking / error**; **tap to interrupt**, and on interrupt a plain-text transcript of what was said appears; surrounding buttons for video/screen-share/mute/exit; stays on a tweaked homepage rather than a modal takeover.
- Steal: state-differentiated waveform pill + M3 Expressive motion tokens is exactly the visual grammar for a Google-styled dictation HUD.

## 9. Talon Voice (talonvoice.com)
- Power-user command system: community grammar **talonhub/community (knausj_talon)**; custom **phonetic alphabet** (short words, fewer syllables); formatters for identifiers (snake/camel/etc.), operator/symbol commands, snippets.
- **Cursorless** (VS Code): colored "hats" decorate tokens so any on-screen code is addressable in one short command — gold standard for precision voice editing.
- **Noise recognition**: pop/hiss sounds as instant triggers (e.g. pop = click) — zero-latency non-verbal activation. Eye tracking for cursor.
- Reviews (handsfreecoding.org, joshwcomeau.com, blakewatson.com): unmatched precision, but "first two weeks are slow and frustrating"; steep learning curve is the #1 complaint. Lesson: expose a tiny optional command vocabulary, never require one (Aqua explicitly positions natural language over learned commands).

## 10. Open-source landscape (GitHub/HN)
- **Handy** (github.com/cjpais/Handy, ~30k stars, MIT, Tauri Rust+React): push-to-talk or toggle, Whisper GGML + **Parakeet V3** (CPU, auto language) via transcribe-rs, Silero VAD, rdev global shortcuts, Raycast extension, custom GGML models. HN front page twice (247 pts Jan 2026, 237 pts Sep 2025; threads 44302416, 46628397). HN praise: "incredibly fast on my M1 Air and more accurate than native"; philosophy "not the best, the most forkable." **HN complaints/requests**: Bluetooth/AirPods mic 1–2s wake latency (workaround: Always-On Microphone debug option); wants custom dictionaries, streaming-to-cursor, edit/correction of typed text, iOS app. Known macOS issue: fn/Globe hotkey only on Apple keyboards; Bluetooth mic degrades audio quality while recording.
- **VoiceInk** (github.com/Beingpax/VoiceInk, GPLv3, native Swift, 4,100+ stars, $29 binary/free source): **Power Mode** = per-app auto-config via NSWorkspace frontmost-app detection, **browser URL extraction via accessibility APIs**; context from selected text/clipboard/visible screen text feeding AI enhancement; personal dictionary; push-to-talk.
- **FluidVoice** (github.com/altic-dev/FluidVoice, GPL-3.0, Swift, ~9.4k stars by Aug 2026): "fastest" claim with Parakeet near-zero delay; **Fluid-1** custom local enhancement model ("Fluid Intelligence") for on-device formatting/capitalization; 99 languages via Whisper.
- **Hex** (github.com/kitlangton/Hex, SwiftUI + Composable Architecture, menu-bar): press-and-hold OR **double-tap to lock recording, tap again to stop**; Parakeet TDT v3 via FluidAudio default + WhisperKit; HN comment: "haven't seen any STT app faster than Hex."
- **Whispering/Epicenter** (github.com/EpicenterHQ/epicenter, AGPL-3.0): local-first, **hands-free VAD-driven auto start/stop** (no button holding), BYO API keys, data transparency positioning; YC-backed.
- **MacWhisper** (goodsnooze.gumroad.com, €59 lifetime): file-transcription-first with a system-wide dictation mode; Whisper + Parakeet; meeting auto-record.
- **Superwhisper** (reference incumbent, $249.99 lifetime): **custom Modes** each with own model + AI prompt + own hotkey, auto-switching per app; local processing; praised for single-button flow and privacy. Complaints: setup "like configuring a server," overwhelming settings; **audio recordings saved by default with no opt-out** (top privacy gripe); **API keys in plaintext JSON not Keychain**.

## Cross-cutting numbers
- Latency claims to beat: Willow 200ms, Aqua insertion ~450ms/startup 50ms, "most competitors 700ms+", Parakeet V3 local = near-instant on Apple Silicon, Apple SpeechTranscriber 55% faster than Whisper L3T.
- Model consensus 2025–2026: **NVIDIA Parakeet V3 (CPU) beats Whisper for live dictation speed** at acceptable accuracy; Whisper Large kept for accuracy-critical/multilingual; Apple SpeechTranscriber newly competitive and free.
- Pricing bands: $8–15/mo subscriptions (Aqua 8, Willow 12, Monologue 15, Wispr 12–15) vs one-time $29–69 (VoiceInk, MacWhisper) vs free OSS (Handy, FluidVoice, Hex, Whispering). Recurring anger at subscriptions for a keyboard-replacement utility is a real wedge for an open-source app.

## Ranked: 10 most stealable ideas
1. **Auto-learning dictionary from user corrections** (Wispr Flow): watch the target text field after paste; any user edit to a transcribed word silently becomes a dictionary entry. Highest-leverage retention feature; no competitor does it as invisibly.
2. **Per-app context + tone via frontmost-app detection** (VoiceInk Power Mode / Wispr / Aqua / Monologue Modes): NSWorkspace app + AX browser-URL → per-app formatting profile (casual Slack, formal Mail, technical in IDE), with user-overridable Modes carrying custom instructions and optional per-mode hotkeys (Superwhisper).
3. **Screen-as-dictionary deep context, permissioned** (Aqua "your screen is its dictionary", Monologue "Deep context", VoiceInk selected-text/clipboard): feed visible text/selection into the pass that fixes proper nouns and jargon. Must be opt-in with a visible indicator — Wispr's screen capture caused a privacy backlash.
4. **Sub-500ms perceived latency architecture**: local Parakeet V3 (or Apple SpeechTranscriber on Tahoe) for instant draft + optional cloud/LLM refinement pass; pre-warm mic (Handy's Bluetooth 1–2s wake delay is the #1 OSS complaint — offer an "always-on mic" option); stream text into the field as spoken (Aqua real-time mode; top Handy feature request).
5. **Self-correction collapsing + filler removal by default** ("no wait, Tuesday" → Tuesday): the single most-praised LLM cleanup behavior across Wispr/Monologue/Willow reviews; keep a "verbatim" toggle.
6. **Voice edit commands on selection** (Wispr Command Mode / Willow keyboard editing / Aqua natural commands): select text, hold key, speak transformation ("more concise", "bullet points", "fix the greeting"). Natural language, not a Talon-style learned grammar — Talon proves precision is possible but its learning curve is the #1 complaint.
7. **State-differentiated waveform pill HUD** (Gemini Live): one compact M3 Expressive pill with distinct listening/processing/inserting/error animations, tap-to-cancel, esc-to-discard; plus review-before-commit or instant-undo (ChatGPT's auto-send regression drew organized backlash; Wispr's iOS undo/redo chips are the pattern).
8. **Whisper Mode + polished audio cues** (Wispr): works at whisper volume for open offices; discreet, distinct start/stop sounds (Apple's wrong-tone bug shows sound *is* the trust signal — an obvious place for Google-quality sonic design).
9. **Never require the cloud**: offline fallback tier (Willow/Monologue) or fully local path (VoiceInk/Handy/FluidVoice); store keys in Keychain, don't retain audio by default (Superwhisper's two top gripes), zero-retention documentation. As an open-source Google-styled app this is the credibility play against Wispr's AWS/privacy incidents.
10. **Fix Apple's known irritations explicitly**: no silence timeout, configurable hotkey that coexists with Karabiner/Raycast (support hold, double-tap-lock like Hex, and fn/Globe), reliable insertion at cursor via AX with clipboard-paste fallback, and unlimited-length sessions — market copy writes itself against the documented 30s-timeout/fn-conflict complaints.

## KEY FACTS
- Aqua Voice: proprietary Avalon STT model (Aug 2025), 97.3% on own AISpeak benchmark, <50ms startup / ~450ms insertion claims, Mac activation = hold Spacebar, 800-entry dictionary on Pro ($8/mo), Max $24/mo adds real-time streaming mode + voice commands ('send it'); 'your screen is its dictionary' screen-context feature
- Aqua Launch HN (id=39828686): '6 models working together to transcribe, interpret, and rewrite'; WER 0.05-0.06 claim; complaints = early slowness, accent degradation, missing privacy policy
- Willow Voice (YC X25): ~200ms latency claim vs '700ms+ competitors'; iOS keyboard ships full QWERTY next to voice for manual fixes (vs Wispr's numeric-only pad, per TechCrunch 2025-11-12); free 2,000 words/week recharging; $4.5M raised, 50k+ users
- Monologue (Every, launched 2025-09-23): permissioned screen 'Deep context', per-app Modes (Chatting/Email/Notes/Coding), auto-remembered dictionary, bot-free meeting notes via mic+system audio, notes exposed via MCP/API/CLI; $15/mo; 500M+ words dictated claim
- Wispr Flow: auto-add-to-dictionary watches the pasted text field for user spelling corrections and learns them automatically; Command Mode edits selected text by voice; Whisper Mode works at whisper volume; iOS keyboard 4.8/5 (8,500+ ratings) with waveform, undo/redo chips, spacebar-trackpad
- Wispr Flow complaints: Trustpilot 2.7/5; 'works 60% of the time after payment'; latency creep; audio to AWS + screen-capture privacy backlash with CTO apology after viral Reddit thread; Electron app freezes target apps on Windows
- macOS 26 Tahoe / iOS 26: new SpeechAnalyzer + SpeechTranscriber on-device APIs, ~55% faster than Whisper Large V3 Turbo (34-min video: 45s vs 1:41 MacWhisper L3T vs 3:55 L2), comparable accuracy, free and offline (MacRumors 2025-06-18)
- Apple built-in dictation pain points: ~30s non-configurable silence timeout, fn double-tap conflicts with Karabiner/BetterTouchTool/Raycast/Hyperkey, wrong-tone input-source bug, perceived accuracy regression (85-90%), text inserted at wrong cursor position
- ChatGPT voice UX: dictation (waveform icon, transcript editable in composer) is separate from Voice Mode (blue orb); 2025 unified redesign shows text in-chat during voice; removing the review-transcript-before-send step caused documented user backlash on OpenAI forums
- Gemini Live UX: Material 3 Expressive / 'Neural Expressive' condenses waveform into a tiny pill; distinct animated listening/processing/speaking/error states; tap-to-interrupt reveals plain-text transcript
- Talon Voice: talonhub/community (knausj) grammar, custom phonetic alphabet, Cursorless colored 'hats' for one-command code edits, pop/hiss noise triggers, eye tracking; #1 complaint = weeks-long learning curve
- Handy (cjpais/Handy, ~30k stars, MIT, Tauri/Rust): offline Whisper + Parakeet V3 + Silero VAD; HN front page twice (247 pts Jan 2026, 237 pts Sep 2025); top complaint = 1-2s Bluetooth/AirPods mic wake latency (Always-On Microphone workaround); top requests = custom dictionary, streaming-to-cursor, iOS app
- VoiceInk (GPLv3 Swift, 4.1k+ stars, $29): Power Mode auto-switches config per app via NSWorkspace + extracts browser URL via accessibility APIs; context from selected text/clipboard/visible screen text
- FluidVoice (altic-dev, GPL-3.0, ~9.4k stars Aug 2026): Parakeet near-zero-delay dictation + custom local 'Fluid-1' enhancement model for on-device formatting
- Hex (kitlangton/Hex, SwiftUI/TCA): press-and-hold OR double-tap-to-lock recording; Parakeet TDT v3 via FluidAudio default, WhisperKit fallback; HN calls it fastest Mac STT
- Superwhisper ($249.99 lifetime): per-mode model+prompt+hotkey with app-based auto-switching; complaints = 'configuring a server' setup complexity, audio recordings saved by default with no opt-out, API keys in plaintext JSON not Keychain
- Model consensus 2025-2026: NVIDIA Parakeet V3 (CPU) is near-instant and 'accurate enough', preferred over Whisper for live dictation; Whisper Large for accuracy-critical; Apple SpeechTranscriber newly competitive and free
- VoicePal: AI asks contextual follow-up questions after you speak to draw out ideas (dictation-as-interview); Voicenotes praised for one-tap capture + AI chat over all notes, criticized for lost/cut-off transcriptions
- Pricing bands: subscriptions $8-15/mo (Aqua/Willow/Wispr/Monologue) vs one-time $29-69 (VoiceInk/MacWhisper) vs free OSS (Handy/FluidVoice/Hex/Whispering); subscription fatigue is a recurring HN/Reddit theme
- Whispering/Epicenter (AGPL): hands-free VAD auto start/stop without button holding; local-first data-transparency positioning

## RECOMMENDATIONS
- Steal #1 — Auto-learning dictionary (Wispr): after pasting, watch the target field via AX for user corrections to transcribed words and silently add them to the personal dictionary; surface a subtle 'learned Kubernetes' toast for delight
- Steal #2 — Per-app Modes with frontmost-app detection (VoiceInk/Superwhisper/Monologue): NSWorkspace bundle-id + AX browser URL -> tone/formatting profile (Slack casual, Mail formal, IDE technical), user-editable custom instructions per mode
- Steal #3 — Opt-in screen/selection context (Aqua/Monologue/VoiceInk): feed selected text, clipboard, and visible window text into the correction pass for proper nouns/jargon; make it permissioned and visibly indicated — Wispr's screen capture triggered a privacy backlash
- Steal #4 — Latency architecture: local Parakeet V3 or Apple SpeechTranscriber (macOS 26) instant draft + optional REST-API refinement; pre-warm/always-on mic option to kill the 1-2s Bluetooth wake delay (Handy's #1 complaint); target <500ms end-to-end to beat Willow's 200ms claim narrative
- Steal #5 — Default LLM cleanup: filler removal + self-correction collapsing ('no wait, Tuesday' -> Tuesday) with a verbatim toggle; this is the single most-praised behavior across all 2025 apps
- Steal #6 — Natural-language edit-on-selection (Wispr Command Mode): hold hotkey with text selected to transform it by voice; avoid Talon-style learned grammar (its learning curve is the #1 complaint), but borrow Talon's noise-trigger idea only as an optional power feature
- Steal #7 — HUD: one compact Material 3 Expressive waveform pill with distinct listening/processing/inserting/error motion states (Gemini Live pattern), esc-to-cancel, and instant undo after insertion (Wispr iOS undo chips; ChatGPT's removed review step caused revolt)
- Steal #8 — Whisper-volume support + Google-quality sonic branding: distinct, quiet start/stop/insert/error earcons; Apple's wrong-tone bug proves sound is the trust channel and nobody in this market has polished audio
- Steal #9 — Privacy as product: local-first default, no audio retention by default, keys in macOS Keychain, zero-retention docs — directly counters Superwhisper's and Wispr's top documented gripes and fits the open-source plan
- Steal #10 — Explicitly fix Apple dictation's documented failures: no silence timeout, hotkey engine supporting hold / double-tap-lock (Hex) / fn-Globe that coexists with Karabiner-Raycast, reliable AX insertion with clipboard fallback, unlimited session length
- Activation: default to push-to-talk hold-fn plus double-tap-to-lock toggle (Hex pattern covers both quick and long-form); consider Aqua's hold-Space as an experiment but expect conflicts
- Free/pricing positioning: OSS + generous free tier (Willow's recharging 2,000 words/week is a liked pattern) undercuts $12-15/mo incumbents where subscription resentment is loudest on HN/Reddit
- Distribution ideas seen working: Raycast extension (Handy), MCP/API/CLI access to transcripts (Monologue) for agent workflows
- Design references to study directly: Gemini overlay redesign (androidauthority.com/gemini-overlay-and-live-ui-changes-3655577), Wispr iOS keyboard docs (docs.wisprflow.ai), Cursorless demo for future precision-editing ambitions

## OPEN QUESTIONS
- Exact sound assets/earcon specs used by Wispr Flow and Superwhisper (no public documentation found — needs hands-on testing)
- Whether Apple's SpeechTranscriber API supports true streaming partial results suitable for live text-in-field insertion, and its real WER vs Parakeet V3 on technical vocabulary
- Wispr Flow's precise default hotkey configuration and desktop HUD animation details (docs focus on iOS keyboard)
- Monologue's activation hotkey and latency numbers (site and launch post do not disclose)
- Aqua Voice Avalon API pricing/terms — relevant if benchmarking our custom REST STT API against it
- Real-world accuracy of the ~200ms (Willow) and ~450ms (Aqua) latency claims — all self-reported, no independent benchmarks found
- Whether Handy's planned features (custom dictionary, streaming-to-cursor) have shipped since the Jan 2026 HN thread — check cjpais/Handy releases before finalizing differentiation
