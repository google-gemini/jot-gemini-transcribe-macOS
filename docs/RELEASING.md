# Releasing Jot

Current posture: **private, single-user dev build.** This runbook is the checklist
for when distribution starts. The machinery (scripts/release.sh, release.yml)
already works — it's waiting on credentials and decisions, not code.

## Gates before anyone else gets a build

1. **Model availability** — Jot prefers `gemini-3.7-transcribe` (early access) and
   falls back automatically to a general Gemini model, so an ordinary AI Studio key
   works. Before a release, verify the fallback with a NON-allowlisted key: mint a
   fresh key on a personal Google account, dictate once, and confirm the History row
   shows a transcript rather than a "model not available" failure. Preview models get
   renamed without warning — this gate exists because the 3.5 preview was retired
   mid-flight on 2026-08-18.
2. **Brand/OSS review** (public release only) — the Jot name, the
   four-color processing treatment, and the repo going public all ride on it.
   README carries "not an official Google product" until resolved.

## One-time setup (personal Apple Developer Program account)

1. In [developer.apple.com](https://developer.apple.com/account) → Certificates:
   create a **Developer ID Application** certificate. Export from Keychain Access
   as `.p12` with a password.
2. In [App Store Connect](https://appstoreconnect.apple.com) → Users and Access →
   Integrations: create an **API key** (Developer role). Note key ID + issuer ID,
   download the `.p8` once.
3. Local notarization profile (enables `scripts/release.sh` to notarize):
   ```bash
   xcrun notarytool store-credentials gt-notary \
     --key AuthKey_XXXX.p8 --key-id KEYID --issuer ISSUER-UUID
   ```
4. Update `project.yml`: set `DEVELOPMENT_TEAM` to the personal team ID and bump
   `PRODUCT_BUNDLE_IDENTIFIER` if the com.google prefix doesn't survive review.
   ⚠️ Changing team or bundle id resets TCC — everyone re-grants permissions once.

## Local release build

```bash
JOT_CODESIGN_IDENTITY="Developer ID Application: YOUR NAME (TEAMID)" ./scripts/release.sh
```

Produces `build/release/Jot-<version>.dmg`, notarized + stapled when
the `gt-notary` profile exists. Verify: `spctl -a -t exec -vv` on the app.

## CI releases (GitHub)

Add repo secrets, then push a tag (`git tag v0.2.0 && git push --tags`):

| Secret | Contents |
|---|---|
| `SIGNING_CERT_P12` | base64 of the Developer ID .p12 (`base64 -i cert.p12`) |
| `SIGNING_CERT_PASSWORD` | its password |
| `NOTARY_API_KEY` | contents of the .p8 |
| `NOTARY_API_KEY_ID` | key ID |
| `NOTARY_API_ISSUER` | issuer UUID |

Missing secrets degrade gracefully (unsigned fork build, unnotarized DMG).

## At public launch (not before)

- **Sparkle auto-updates**: generate EdDSA keys (`generate_keys`), add
  `SUFeedURL` + `SUPublicEDKey` to project.yml info, host `appcast.xml` on GitHub
  Releases, add `generate_appcast` to release.yml. Pointless before a public URL
  exists; bump `CURRENT_PROJECT_VERSION` every release (Sparkle compares build
  numbers, not versions).
- Onboarding key screen: revisit copy for whichever public model ships.
- Pin the eval set results for the shipped prompt version in the release notes.

## Every release

1. `./scripts/test.sh` green; magic checklist pass (docs/design/product-reliability.md §8).
2. Bump `MARKETING_VERSION` (and `CURRENT_PROJECT_VERSION`) in project.yml.
3. Tag + push, or run `scripts/release.sh` locally.
4. Smoke the DMG on a clean account: onboarding → key → permissions → first dictation.
