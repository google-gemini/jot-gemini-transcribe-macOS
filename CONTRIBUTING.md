# Contributing

Thanks for helping build dictation that never loses anyone's words.

## Ground rules

1. **Cleanroom policy.** GPL-licensed projects in this space (VoiceInk, FluidVoice,
   and others) may be *studied for behavior* — never copied. Do not port, translate,
   or paraphrase their code into this repository. PRs affirm originality via DCO
   sign-off (`git commit -s`).
2. **No secrets, ever.** No API keys, tokens, or signing material in code, fixtures,
   tests, or CI files. The app takes the user's own Gemini key at runtime and stores
   it in the Keychain.
3. **Design tokens only.** UI changes must use `DesignTokens.swift` /
   `MotionTokens.swift`. If a value isn't in the tokens file, add it there first —
   no magic numbers in views. The full design contract is `docs/design/experience.md`.
4. **Prompt changes require evals.** `PromptV1.swift` is a load-bearing source file.
   Any change must run the eval set in `docs/design/product-reliability.md` §Verification
   (self-corrections, question-shaped speech, spoken punctuation, silence) and report
   gate-trip rates in the PR.
5. **Never-lose-words is an invariant, not a feature.** Any change touching audio,
   networking, or insertion must keep these true: audio is on disk before network I/O
   begins; every failure writes a terminal status; errors are never modal; nothing is
   silently discarded.
6. **No telemetry.** PRs adding analytics, tracking, or phone-home behavior of any
   kind will be declined.

## Getting started

```bash
brew install xcodegen
xcodegen generate
swift test --package-path JotCore   # fast, headless
```

The failure-mode matrix (`docs/design/product-reliability.md`) and the architecture
contract (`docs/design/architecture.md`) are the best places to understand how the
pieces fit.
