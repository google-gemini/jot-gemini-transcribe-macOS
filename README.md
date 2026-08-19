# Jot

**Dictation for your Mac that never loses your words.**

Hold a key. Say the thing. Polished text lands wherever your cursor is.

> **Not an official Google product.** Jot is a personal open-source project by a
> Google employee. It talks to the public Gemini API using *your* API key.

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

## Install

1. **Download** the latest `Jot-x.y.z.dmg` from
   [Releases](../../releases/latest).
2. **Open it and drag Jot into Applications.** Run it from Applications, not
   from the disk image — macOS sandboxes apps launched off a mounted DMG, and
   permissions you grant there do not stick.
3. **Launch Jot.** It lives in the menu bar; there is no Dock icon.

Setup then takes about two minutes and the app walks you through it:

1. **Paste a Gemini API key.** Get a free one at
   [Google AI Studio](https://aistudio.google.com/apikey). It is stored in your
   macOS Keychain and only ever sent to Google.
2. **Allow the microphone**, so Jot can hear you.
3. **Allow Accessibility**, so Jot can type at your cursor. macOS requires this
   for any app that inserts text into another app.
4. **Hold `fn` and say something.**

**Costs:** you pay Google for what you dictate, at
[Gemini API pricing](https://ai.google.dev/pricing) — a free tier exists and
typical dictation is a few seconds of audio per request. Jot never charges
anything and has no account.

**Which model:** Jot runs on Gemini's specialist transcription model,
`gemini-3.5-transcribe`. Your key needs access to it; Jot checks during setup and
tells you if it doesn't, rather than failing on your first dictation.

### If macOS says Jot "can't be opened"

That means this build was not notarized by Apple — see
[docs/RELEASING.md](docs/RELEASING.md). Releases published here are notarized;
if you built it yourself, run it from Applications and use
**System Settings → Privacy & Security → Open Anyway**.

## Uninstall

1. Quit Jot from the menu bar and drag it from Applications to the Trash.
2. Recordings and history: `~/Library/Application Support/Jot`
3. Settings: `defaults delete com.ammaar.jot`
4. Your API key: Keychain Access → search "jot" → delete.
5. If you enabled it: System Settings → General → Login Items.

## Building from source

Requires macOS 14+, Xcode 16+, and [xcodegen](https://github.com/yonaskolb/XcodeGen).
The `.xcodeproj` is generated, not checked in.

```bash
brew install xcodegen
xcodegen generate
open Jot.xcodeproj    # build the "Jot" scheme
```

Signing is set to Automatic with a `DEVELOPMENT_TEAM` in `project.yml`. If you
are not on that team, either set your own team in Xcode's Signing & Capabilities
tab or change `DEVELOPMENT_TEAM` in `project.yml` before generating.

Core logic lives in a headless Swift package:

```bash
./scripts/test.sh      # swift test on JotCore
./scripts/build.sh     # xcodegen + xcodebuild
```

(The scripts wrap a `GIT_CONFIG` override for machines whose managed git config sets
`safe.bareRepository=explicit`, which otherwise breaks Swift Package Manager.)

## Privacy

One network host, your own key, zero telemetry — the full story (and how to verify
it) is in [docs/PRIVACY.md](docs/PRIVACY.md).

## Project layout

- `App/` — app shell: menu bar item, HUD pill, windows, design tokens, resources
- `JotCore/` — all engine logic (hotkeys, audio, transcription, formatting,
  insertion, history) as a testable SPM package
- `docs/design/` — the full design specs this app is built to
- `docs/research/` — the competitive & technical research behind those specs

## Bugs, questions, ideas

Open an issue on this repo. Useful things to include: your macOS version, Jot's
version (menu bar → About Jot), what you expected, and what happened. Logs stay
on your Mac — you can read them with:

```bash
log show --last 30m --info --predicate 'subsystem == "com.ammaar.jot"'
```

Transcript text is logged as private and does not appear there.

## License

MIT — see [LICENSE](LICENSE). Bundled fonts (Google Sans Flex, Google Sans Code) are
SIL OFL 1.1; sound assets are CC-BY 4.0. Details in
[THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).
