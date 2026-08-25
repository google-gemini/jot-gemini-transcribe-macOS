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
4. **Prompt changes need evidence in the PR.** `PromptV1.swift` steers the
   optional flash-lite cleanup pass (Settings › Dictation → Tone). There is no
   automated eval set yet, so verification is by hand and the results belong in
   the PR description: dictate a self-correction, question-shaped speech ("what
   if we shipped it on Friday"), spoken punctuation, and an all-filler take —
   then confirm the ValidationGate did not trip on any of them. Building a real
   eval set is open work and a good first contribution.
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
