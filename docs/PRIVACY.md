# Privacy

## The promise

Your voice goes from your Mac directly to Google's Gemini API, using your own API
key. There is no middleman server, no account, no analytics, no telemetry.
Everything else stays on your Mac. The code is open — verify all of this.

## What leaves your machine (the complete list)

1. **The audio of each dictation** (FLAC-compressed), sent to
   `generativelanguage.googleapis.com` — the only network host this app talks to.
2. **Your dictionary terms**, alongside that audio. The transcription model uses
   them to bias what it hears, which is why names and jargon come out spelled
   right as you speak rather than being corrected afterwards. Only the correct
   spellings are sent — never the misspellings you record. They ride on every
   dictation, including with Smart transcription off.
3. **The formatting prompt**, *only if* "Match tone to the app you're in" is on
   in Settings → Dictation — off by default. It contains the transcript being
   formatted, the formatting rules, a coarse tone category derived from the
   frontmost app's *category* (e.g. "chat message"), and your dictionary terms.
   With that setting off, your transcript text never leaves this Mac at all.
   Never window contents, never screenshots, never surrounding text.
4. **Your API key**, in the request header to Google only. It is stored in the
   macOS Keychain, never in files or preferences.

## What never leaves

- Your history database and stored recordings — audio and transcript text leave
  only as part of the requests above, never in bulk and never anywhere else
- Your dictionary as a file. Individual terms ride with the audio as described
  above, and your misspelling rules are included in the formatting prompt *only*
  when tone matching is on — with it off (the default) they never leave. The
  store itself, and everything you have not dictated against, stays on this Mac
- Which apps you use, when you dictate, or anything you type
- Keystrokes: the event tap watches your dictation key, plus — only while a
  dictation is active — Esc (cancel), Space (the hands-free gesture), and the
  *fact that* another key was pressed (the accidental-chord guard; which key it
  was is never examined beyond its keycode, never logged, never stored, never
  transmitted). When you're not dictating, other keys pass through untouched.
- Screenshots: never taken. The app contains no screen-capture code.
- Telemetry: there is none. No analytics SDK, no crash uploader, no phone-home.

## What's stored locally, and your controls

- One folder per dictation (`~/Library/Application Support/Jot/recordings/`):
  crash-safe audio, transcript, metadata — this is what makes Retry and recovery work.
- Settings → Privacy & Storage: audio retention (24h / 7d / 30d / forever / never —
  "never" disables Retry), plus one-click **Delete all history**.
- Local files are protected by FileVault if enabled; they are not separately
  encrypted (stated honestly).

## Google's side of the wire

Your audio is governed by your own Gemini API terms with Google. As of writing,
paid-tier API usage is not used for model training; free-tier usage may be. That
relationship is yours — this app doesn't broker it. Review the
[Gemini API terms](https://ai.google.dev/gemini-api/terms).

## Secure input

When a password field is focused (secure input), dictation refuses to start, and
a transcript in flight is held in History only — never inserted, never placed on
the clipboard.

## Verify it

- Build from source (`./scripts/build.sh`).
- Watch traffic with Little Snitch or `nettop` — you'll see exactly one host.
- Read the prompt: it's a source file — note it governs only the optional tone pass; with that off, formatting happens inside Google's transcription model and there is no local prompt to read
  ([PromptV1.swift](../JotCore/Sources/FormattingPipeline/PromptV1.swift)).
