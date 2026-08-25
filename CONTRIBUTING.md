# How to Contribute

We'd love to accept your patches and contributions to this project.

External contributions are welcome: bug reports, fixes, and features are all accepted through GitHub pull requests.

There are just a few small guidelines you need to follow.

## Contributor License Agreement

Contributions to this project must be accompanied by a Contributor License
Agreement (CLA). You (or your employer) retain the copyright to your
contribution; this simply gives us permission to use and redistribute your
contributions as part of the project. Head over to
<https://cla.developers.google.com/> to see your current agreements on file or
to sign a new one.

You generally only need to submit a CLA once, so if you've already submitted one
(even if it was for a different project), you probably don't need to do it again.

## Code Reviews

All submissions, including submissions by project members, require review. We use
GitHub pull requests for this purpose. Consult
[GitHub Help](https://help.github.com/articles/about-pull-requests/) for more
information on using pull requests.

## Community Guidelines

This project follows
[Google's Open Source Community Guidelines](https://opensource.google/conduct/).

## Ground rules

1. **Cleanroom policy.** GPL-licensed projects in this space may be *studied for
   behavior* — never copied. Do not port, translate, or paraphrase their code into
   this repository. Signing the CLA above affirms you have the right to contribute
   the code; this rule is the stricter provenance bar that goes with it.
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
