# Releasing Jot

Current posture: **repo still private; builds already shared with colleagues;
public launch pending.** Releases are cut by hand from a local machine —
`scripts/release.sh` is the only path a release has ever gone through and the
only one known to work. `.github/workflows/release.yml` is
manual-dispatch only and has never produced a release — see "CI releases" below
before trusting it.

## Gates before anyone else gets a build

1. **Model availability** — Jot ships on `gemini-3.5-transcribe`. This is the
   product's model, not a default to tune: there is no automatic substitution
   anywhere in the pipeline. Before a release, dictate once and confirm a
   transcript lands. Preview model names get retired without warning (the
   `-preview` suffixed name died mid-session on 2026-08-18), so if this one ever
   404s, pick its successor deliberately and update `GeminiConfig`.


2. **Brand/OSS review** (public release only) — the Jot name, the
   four-color processing treatment, and the repo going public all ride on it.
   README carries "not an official Google product" until resolved.

## The DMG needs a LOCAL Developer ID certificate

Xcode's automatic signing gives you a **cloud-managed** Developer ID certificate:
it signs the .app during `xcodebuild -exportArchive`, but the private key stays
with Apple, so `codesign` cannot use it (`security find-identity` will not even
list it). That is fine for the app — and not enough for the DMG, which Gatekeeper
assesses *before* anything mounts. An unsigned DMG reports
`rejected: no usable signature` and warns the person opening it.

To get a certificate with a local private key (once, ~2 minutes):

1. **Keychain Access → Certificate Assistant → Request a Certificate From a
   Certificate Authority…** — enter your Apple ID email, choose *Saved to disk*,
   and save the `.certSigningRequest`. This creates the private key locally.
2. **[developer.apple.com/account/resources/certificates](https://developer.apple.com/account/resources/certificates)
   → + → Developer ID Application**, upload the CSR, download the `.cer`.
3. **Double-click the `.cer`** to install it.
4. Confirm: `security find-identity -v -p codesigning` now lists
   *Developer ID Application: Ammaar Reshi (7S264298H8)*.

`scripts/release.sh` finds it automatically and signs the DMG; without it the
script still builds and notarizes, but warns that the container is unsigned.

## One-time setup (personal Apple Developer Program account)

**Status on this Mac:** the personal team `7S264298H8` (Ammaar Reshi) is already
known to Xcode, but Apple refuses to issue it certificates until the updated
Program License Agreement is accepted:

> PLA Update available: You currently don't have access to this membership
> resource. To resolve this issue, agree to the latest Program License Agreement
> in your developer account.

So step 0 is: sign in at [developer.apple.com/account](https://developer.apple.com/account)
and accept the agreement. Nothing below can be issued until that is done.


1. In [developer.apple.com](https://developer.apple.com/account) → Certificates:
   create a **Developer ID Application** certificate. Export from Keychain Access
   as `.p12` with a password.
2. In [App Store Connect](https://appstoreconnect.apple.com) → Users and Access →
   Integrations: create an **API key** (Developer role). Note key ID + issuer ID,
   download the `.p8` once.
3. Local notarization profile (enables `scripts/release.sh` to notarize):
   ```bash
   xcrun notarytool store-credentials jot-notary \
     --key AuthKey_XXXX.p8 --key-id KEYID --issuer ISSUER-UUID
   ```
4. Already done in `project.yml`: `DEVELOPMENT_TEAM` is the personal team and
   `PRODUCT_BUNDLE_IDENTIFIER` is `com.ammaar.jot`. ⚠️ Do not change either after
   shipping — TCC keys permissions to team + bundle id, so a change silently
   revokes accessibility and microphone access for every existing user, who then
   has to re-grant both.

## Local release build

```bash
./scripts/release.sh
```

Produces `build/release/Jot-<version>.dmg`, notarized + stapled when the
`jot-notary` profile exists. Verify with `spctl -a -t exec -vv` on the app.

No identity variable: signing is cloud-managed through the Apple account Xcode is
signed into, so `release.sh` archives and exports rather than calling `codesign`
with a local identity. Override the team with `JOT_TEAM_ID` if you need to.

For a build only you will ever run, skip notarization:

```bash
JOT_ALLOW_UNNOTARIZED=1 ./scripts/release.sh
```

It marks the output `-UNNOTARIZED-DO-NOT-SHARE` so it cannot be mistaken for a
shippable artifact.

## CI releases (GitHub)

**This has never worked, and it is disabled on purpose** — the workflow is
`workflow_dispatch` only, so tagging no longer fires a job that is guaranteed to
fail. Two things block it:

1. **The signing certificate cannot be exported.** The Developer ID in use is
   cloud-managed: the private key lives with Apple, not in the login keychain,
   so there is no `.p12` to base64 into `SIGNING_CERT_P12`. Making CI viable
   means first creating a *second* Developer ID certificate from a local CSR
   (step 1 above) — which is needed to sign the DMG container anyway.
2. **Without a certificate the job dies at archive**, not at signing:
   `xcodebuild archive` needs an Apple account on the runner and fails with
   `No Accounts: Add a new account in Accounts settings.`

Once a local-CSR certificate exists, add these secrets and run the workflow
manually:

| Secret | Contents |
|---|---|
| `SIGNING_CERT_P12` | base64 of the Developer ID .p12 (`base64 -i cert.p12`) |
| `SIGNING_CERT_PASSWORD` | its password |
| `NOTARY_API_KEY` | contents of the .p8 |
| `NOTARY_API_KEY_ID` | key ID |
| `NOTARY_API_ISSUER` | issuer UUID |

Missing secrets do **not** degrade gracefully. The import steps skip cleanly,
but `release.sh` then refuses to emit an unsigned or unnotarized artifact — by
design, since a DMG that looks shippable and hits a Gatekeeper wall is worse than
no DMG. Expect a hard failure, not a fork build.

## At public launch (not before)

- **Sparkle auto-updates**: generate EdDSA keys (`generate_keys`), add
  `SUFeedURL` + `SUPublicEDKey` to project.yml info, host `appcast.xml` on GitHub
  Releases, add `generate_appcast` to release.yml. Pointless before a public URL
  exists; bump `CURRENT_PROJECT_VERSION` every release (Sparkle compares build
  numbers, not versions).
- Onboarding key screen: revisit copy for whichever public model ships.
- Build the prompt eval set (it does not exist yet — see CONTRIBUTING §4) and
  pin its results for the shipped prompt version in the release notes.

## Every release

1. `./scripts/test.sh` green; magic checklist pass (docs/design/product-reliability.md §8).
2. Bump `MARKETING_VERSION` (and `CURRENT_PROJECT_VERSION`) in project.yml.
3. Tag + push, or run `scripts/release.sh` locally.
4. Smoke the DMG on a clean account: onboarding → key → permissions → first dictation.
