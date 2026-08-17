# Google Transcribe

**Dictation for your Mac that never loses your words.**

Hold a key. Say the thing. Polished text lands wherever your cursor is.

> ⚠️ This is not an official Google product. It is an open-source project, pending
> brand review — the name and visual treatment may change before public release.

## What it does

- **Hold `fn` (Globe) anywhere** and speak — release, and clean, punctuated text is
  inserted at your cursor. Double-tap to lock hands-free. `Esc` cancels.
- **Formatting that understands dictation**: fillers dropped, self-corrections
  collapsed ("let's do 2pm — actually, 3" → "Let's do 3pm."), tone adapted to the app
  you're writing in (email vs. chat vs. code).
- **Your words are never lost.** Audio is written to crash-safe storage from the
  first millisecond. Offline? It queues and lands when you're back. App crashed?
  It recovers on relaunch. Everything is retryable from History.
- **Private by architecture**: your voice goes from your Mac directly to the Gemini
  API with *your own key*. No middleman server, no account, no analytics, no
  screenshots, no keystroke logging. One network host. Read the code.

## Setup (about 2 minutes)

1. Get a Gemini API key from [Google AI Studio](https://aistudio.google.com/apikey).
2. Launch Google Transcribe and paste the key when asked (it lives in your Keychain).
3. Grant the two macOS permissions (Microphone, Accessibility) from the guided setup.
4. Hold `fn` and say hello.

## Building from source

```bash
brew install xcodegen
xcodegen generate
open GoogleTranscribe.xcodeproj    # build the "Google Transcribe" scheme
```

Core logic lives in a headless Swift package:

```bash
./scripts/test.sh      # swift test on TranscribeCore
./scripts/build.sh     # xcodegen + xcodebuild
```

(The scripts wrap a `GIT_CONFIG` override for machines whose managed git config sets
`safe.bareRepository=explicit`, which otherwise breaks Swift Package Manager.)

## Privacy

One network host, your own key, zero telemetry — the full story (and how to verify
it) is in [docs/PRIVACY.md](docs/PRIVACY.md).

## Project layout

- `App/` — app shell: menu bar item, HUD pill, windows, design tokens, resources
- `TranscribeCore/` — all engine logic (hotkeys, audio, transcription, formatting,
  insertion, history) as a testable SPM package
- `docs/design/` — the full design specs this app is built to
- `docs/research/` — the competitive & technical research behind those specs

## License

MIT — see [LICENSE](LICENSE). Bundled fonts (Google Sans Flex, Google Sans Code) are
SIL OFL 1.1; sound assets are CC-BY 4.0. Details in
[THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).
