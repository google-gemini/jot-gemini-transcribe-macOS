# Research: google-design
# Making a Mac Dictation App Read as "Google": Research Report

## 1. Typography — Google Sans Flex (now open) and fallbacks

- **Google Sans Flex** is a ground-up multi-axis rebuild of proprietary Google Sans by David Berlow (Font Bureau). Released free/open ~Nov 18–19, 2025 on Google Fonts under **SIL Open Font License 1.1** (https://fonts.google.com/specimen/Google+Sans+Flex). Single variable file with **6 axes**: `wght` 1–1000, `wdth` 25–151, `opsz` 6–144, `slnt` -10–0, `GRAD` 0–100, `ROND` 0–100 (roundness axis is distinctive — lets you dial geometric→rounded terminals). Named instances Thin(100)→Black(900).
- **Bundling in an open-source Mac app: YES, permitted.** OFL 1.1 allows embedding, redistribution, modification, commercial use. Obligations: ship the OFL license text + copyright notice with the font; may not sell the font by itself; if you *modify* the font you must rename it (Reserved Font Name clause). Distribution channels: Google Fonts, Fontsource npm `@fontsource-variable/google-sans-flex` (https://fontsource.org/fonts/google-sans-flex). Caveat: **no public upstream source repo** yet — google/fonts GitHub issues #10006 and #10077 note the font is served and labeled OFL but absent from the repo; LineageOS mirrors the TTF at `LineageOS/android_external_google-fonts_google-sans-flex`.
- **Google Sans Code**: fully open on GitHub (https://github.com/googlefonts/googlesans-code), OFL 1.1, designed with Universal Thirst, variable `wght` 300–800, Roman + Italic VFs — use for transcript/mono or settings code fields; its open license predates Flex's and is the cleanest legal precedent.
- **Roboto Flex**: OFL, 13 axes (`opsz, slnt, wdth, wght, GRAD, XOPQ, XTRA, YOPQ, YTAS, YTDE, YTFI, YTLC, YTUC`), `wght` 100–1000, `GRAD` -200–150. Repo: googlefonts/roboto-flex. Safe open fallback and the historic Android/Material default.
- Contrast: original **Google Sans / Google Sans Text / Product Sans remain proprietary** (licensed for Google-branded products only; Google Fonts API refuses to serve them to non-Google domains). Google Sans Flex is the sanctioned way to get the look.
- **GRAD axis trick** (from Google's own guidance): bump grade slightly in dark mode instead of weight — thickens strokes without layout shift.

## 2. Material 3 / M3 Expressive motion system (exact tokens)

Source: material-components-android `docs/theming/Motion.md` + m3.material.io/styles/motion.

**Spring tokens (physics-first system, introduced with M3 Expressive, I/O May 2025).** Two families × three speeds; damping 1.0 = no bounce:

| Token | Damping | Stiffness |
|---|---|---|
| motionSpringFastSpatial (standard) | 0.9 | 1400 |
| motionSpringDefaultSpatial (standard) | 0.9 | 700 |
| motionSpringSlowSpatial (standard) | 0.9 | 300 |
| motionSpringFastEffects | 1.0 | 3800 |
| motionSpringDefaultEffects | 1.0 | 1600 |
| motionSpringSlowEffects | 1.0 | 800 |
| expressiveSpatialFast | 0.6 | 800 |
| expressiveSpatialDefault | 0.8 | 380 |
| expressiveSpatialSlow | 0.8 | 200 |

Rules: **spatial springs** animate position/size/shape (visible overshoot OK); **effects springs** animate color/opacity/blur (never bounce, damping 1). "Expressive" scheme (lower damping → overshoot) is for hero moments; "Standard" for utility. These map directly to SwiftUI `Animation.spring(response:dampingFraction:)` — dampingFraction = the damping ratio above; response ≈ 2π/√stiffness.

**Easing/duration tokens (md.sys.motion, still valid for non-spring cases):**
- emphasized ≈ cubic-bezier(0.2, 0.0, 0, 1.0) (canonical version is a two-segment path curve)
- emphasized-decelerate cubic-bezier(0.05, 0.7, 0.1, 1.0); emphasized-accelerate cubic-bezier(0.3, 0.0, 0.8, 0.15)
- standard cubic-bezier(0.2, 0, 0, 1); standard-decelerate (0,0,0,1); standard-accelerate (0.3,0,1,1)
- Durations: short1–4 = 50/100/150/200ms; medium1–4 = 250/300/350/400ms; long1–4 = 450/500/550/600ms; extra-long1–4 = 700/800/900/1000ms. Enter = decelerate flavor, exit = accelerate flavor.
- CSS/bezier approximations of expressive spatial springs (community, note.com): fast ≈ 350ms cubic-bezier(0.42,1.67,0.21,0.9); default ≈ 500ms cubic-bezier(0.38,1.21,0.22,1); slow ≈ 650ms cubic-bezier(0.39,1.29,0.35,0.98).

**M3 Expressive additions** (46 research studies, 18k participants — Google's most-researched update): 35-shape library ("cookie" scallops, squircles, pills), **shape-morph transitions** (square→squircle on press), new **loading indicator = looping morph through 7 Material shapes** (replaces indeterminate spinner for waits <5s; shipped in Android 16), 15 new/updated components (button groups, split buttons, FAB menu, toolbars), pill-shaped buttons everywhere.

## 3. Color system

- **Google brand quad**: Blue **#4285F4**, Red **#EA4335**, Yellow **#FBBC04**, Green **#34A853**.
- **GM3/Workspace observed production values** (Gmail/Drive/Chrome CSS, high confidence): light primary **#0B57D0**, primary-container **#D3E3FD**, on-primary-container **#041E49**; dark primary **#A8C7FA**, dark primary-container **#0842A0**. Gemini app dark background ≈ **#131314**.
- **Tonal palette mechanics**: colors generated in HCT space; 13 tones (0–100) per palette. Role→tone mapping: primary = tone 40 (light) / **tone 80 (dark)**; onPrimary = 100/20; primaryContainer = 90/30; onPrimaryContainer = 10/90; surface = tone ~98 (light) / **tone 6 (dark — near-black #141314-ish, never pure #000)**; onSurface = 10/90. Dark theme = desaturated, lighter accent (that's why dark-mode Google blue is powdery #A8C7FA, not #4285F4).
- **State layers**: overlay of the on-color at hover **8%**, focus **10%**, pressed **10%** (12% in some component specs), dragged **16%**.
- **Elevation**: 6 levels — 0, 1, 3, 6, 8, 12dp; M3 de-emphasizes shadows in favor of **surface tint** (primary-tinted overlay whose opacity rises with elevation); menus/dialogs = level 2–3; hover raises one level.

## 4. Type scale (M3, sp = pt on Mac roughly)

Display L/M/S: 57/45/36 Regular; Headline L/M/S: 32/28/24 Regular; Title L 22 Regular, Title M 16 Medium, Title S 14 Medium; Body L/M/S: 16/14/12 Regular (Body L line-height 24); Label L 14 Medium, Label M 12 Medium, Label S 11 Medium. Google products set display/headline in Google Sans (now Flex, low GRAD, wide opsz) and body in Google Sans Text — with Flex, opsz axis handles both.

## 5. Shape / corner radii

M3 corner tokens: none 0, extra-small **4dp**, small **8dp**, medium **12dp**, large **16dp**, large-increased 20dp, extra-large **28–32dp**, full = pill/stadium. Chrome Refresh 2023 and Gemini UIs lean hard on 12–16dp for cards/menus and full-pill for inputs/buttons.

## 6. Gemini visual identity (the AI look)

- **Spark logo**: four-pointed star constructed from the **negative space of four adjoining circles**; mid-2025 redesign rounded the points and recolored it with the **four Google colors** (right side mostly blue, left subtle gradient) replacing the mono blue-purple spark. (9to5google.com/2025/06/30/new-gemini-icon/)
- **Classic Gemini/Bard gradient** (still the shorthand for "AI shimmer"): `linear-gradient(74deg, #4285F4 0%, #9B72CB 9%, #D96570 20%, #D96570 24%, #9B72CB 35%, #4285F4 44%, #9B72CB 50%, #FFF 56%...)` with `background-size: 400% 100%` animated — blue→purple→salmon sweep.
- **Aug 2025 onward**: the Gemini **overlay glow** (edge-lighting around the assistant sheet) switched from blue-purple to a **red/yellow/green/blue four-color gradient** (9to5google.com/2025/08/06/new-gemini-overlay-glow-colors/).
- **Gemini Live UI evolution — the best dictation-HUD reference**:
  - Feb 2026: **floating pill overlay** matching the Gemini text-prompt overlay: waveform rendered *inside/behind* the pill, live transcription above it, toggles top-right; expanded pill = control center (camera/screen share, mic mute, end); when user switches apps it **collapses into a draggable circle (chathead)**; **tap to expand, swipe down to dismiss** (9to5google.com/2026/02/02/gemini-live-floating-redesign/).
  - Apr 2026 (stable, Google app 17.14.60): fullscreen Live UI retired; bottom **pill-shaped container with a blue waveform**, camera/screen-share on the left inside the pill, mic-mute on the right, "Live with Gemini" header + transcript button; exit via keyboard icon or back gesture (9to5google.com/2026/04/19/gemini-live-app-redesign/).
  - Waveform aesthetic: rounded bars / blobby ribbon in Google blue (four-color accents in newer builds), calm idle undulation, amplitude-reactive while speaking.

## 7. Sound — what makes it "Googley"

- **Material sound guidelines** (m2.material.io/design/sound/): tonal sounds convey personality/emotion/state; atonal sounds support motion/haptic feel; design **silence** deliberately ("negative space" — Conor O'Sullivan, "Designing Sound and Silence", medium.com/google-design). Categories: **hero sounds** (celebrations), **alerts & notifications**, **primary system sounds** (taps, confirm-down/up, lock/unlock, camera-shutter, navigation back/forward, selection-complete-celebration), **secondary system sounds** (errors ×3, cancel, transitions L/R, unavailable, loading, refresh-feed).
- **Free asset pack**: "Material Design Sound Resources" — 40 files, WAV/FLAC/OGG/MP3/AAC, **CC-BY 4.0** (mirrored: archive.org/details/material-design-sound-resources). Legitimate to ship in an open-source app with attribution; ideal starting kit (use `navigation_forward-selection`, `state-change_confirm-up/down`, `alert_error-01`, `hero_simple-celebration-01`).
- **Pixel sound team philosophy** (blog.google "How Google designers create sounds for Pixel", 9to5google 2024-03-12): principles = **"simple, human, playful"**; sounds offload information from the visual channel; EQ'd per-hardware; motion and sound sync frame-to-frame (camera shutter example); a UX-writing team names sounds from the designers' "musical/aesthetic description"; Pixel 8 "Gems" pack was made with MusicFX gen-AI (2-second excerpts from 30s generations). ~12 sound designers; lead voice: Conor O'Sullivan (ex-Motorola HELLOMOTO, Xbox).
- **The Google sonic signature**: the "**Super G**" Gemini/Assistant sound is a **G-major chord swelling into a single G note** — continuity with Google Home sounds. Gemini for Home plays a **short chime at listening-start and listening-end** — exactly the pattern a push-to-talk dictation app needs. Overall aesthetic: short (<400ms) mallet/marimba-adjacent or soft-synth tones, major tonality, low loudness, rounded attack, no skeuomorphism.

## 8. Google on the desktop / Mac — how Material translates

- **Chrome Refresh 2023** (Chrome 117, Sep 12 2023): the canonical GM3-on-desktop example — pill/rounded tabs, rounded omnibox and menus (8–16dp), tonal color system from a seed color, flat but gradient-friendly. Material on desktop = spacing loosened, hover states added (8% layers), same tokens.
- **Gemini app for Mac** (launched **Apr 15, 2026**, macOS 15+, free, gemini.google/mac): **built natively in Swift**, NOT Electron and NOT strict Material — it wraps Gemini in **Apple's Liquid Glass** styling while keeping Google brand elements (menu-bar **spark icon**, Google colors, gemini.google.com layout parity). Shortcuts: **Option+Space** = compact floating pill "Ask Gemini" bar (attachment "+" left; model switcher, voice input, expand-to-full-app right); **Option+Shift+Space** = full chat window; screen/window sharing for context. Lesson: Google itself judges that on macOS you keep the brand's color/type/iconography and motion feel but respect native platform materials, vibrancy, and shortcut conventions.
- Other Google Mac software: Google Drive for desktop (menu-bar app, utilitarian), Antigravity IDE (VS Code fork, dark developer aesthetic), historically Chrome apps/PWAs. There is no Google-made AppKit Material framework — Material on Mac is always a custom reimplementation (their Swift Gemini app included).

## 9. Concrete recipe for a Google-flavored Mac dictation HUD

**Type**: Bundle Google Sans Flex VF (OFL text in About + repo). UI at `opsz` ~17, `GRAD` 0 (light) / +25 (dark); HUD transcript Body Large 16/24 Regular; status Label Medium 12 Medium; onboarding headlines Headline Small 24 w/ `ROND` 15–30 for warmth. Mono bits: Google Sans Code. Fallback stack: "Google Sans Flex", "Roboto Flex", -apple-system.

**Color** (light / dark):
- Accent primary: #0B57D0 / #A8C7FA; on-primary #FFFFFF / #062E6F(≈tone20)
- Primary container: #D3E3FD / #0842A0; on-container #041E49 / #D3E3FD
- HUD surface: #FFFFFF or #F0F4F9 / #1E1F20 on window, root dark bg #131314; never #000
- Waveform: Google Blue #4285F4 body; optional four-color sweep (#4285F4/#EA4335/#FBBC04/#34A853) on the "AI is processing" state; error #B3261E (light) / #F2B8B5 (dark)
- Recording glow: animated Gemini gradient #4285F4→#9B72CB→#D96570 as a 1.5–2px edge glow around the pill, background-position animated
- State layers: hover 8%, pressed 10%, drag 16% of on-surface.

**Shape**: HUD = **full pill** (corner radius = height/2, height ~44–56pt); expanded transcript card 28dp; menus/popovers 12dp; buttons inside pill = circular 36pt. Press feedback = shape morph (circle→rounded-square, M3E style).

**Motion** (SwiftUI): appear/expand = expressiveSpatialDefault → `spring(response ~0.32, dampingFraction 0.8)` with slight overshoot; collapse-to-dot = expressiveSpatialFast (response ~0.22, damping 0.6-0.8); color/opacity = effects springs → `spring(response 0.04–0.09, dampingFraction 1.0)` or emphasized-decelerate cubic-bezier(0.05,0.7,0.1,1) 250–400ms in, emphasized-accelerate (0.3,0,0.8,0.15) 150–200ms out. Waveform idle = slow sine undulation; processing = M3E loading morph (cycle 7 shapes) instead of a spinner.

**Behavioral pattern (copy Gemini Live)**: push-to-talk shows bottom-center floating pill with live waveform + inline streaming transcript above; collapses to a small draggable circle when idle; tap = expand, swipe/Esc = dismiss; mute state visible in pill; menu-bar item uses a spark-like glyph (do NOT copy the Gemini spark exactly — trademark).

**Sound**: two-note earcon family in **G major**; start-listening = short upward swell to G (~250ms, soft mallet/synth, rounded attack); stop/insert-text = the inverse resolving down; error = single muted minor-second tap; success paste = `state-change_confirm-up` from the CC-BY Material pack. Keep everything under 400ms, -20 LUFS-ish quiet, and design the silence — no sound on hover/keystrokes.

Key sources: fonts.google.com/specimen/Google+Sans+Flex; github.com/googlefonts/googlesans-code; github.com/material-components/material-components-android/blob/master/docs/theming/Motion.md; m3.material.io/styles/motion, /styles/shape/corner-radius-scale, /styles/elevation, /blog/tone-based-surface-color-m3; design.google/library/gemini-ai-visual-design; 9to5google.com (2026/02/02 + 2026/04/19 Gemini Live, 2026/04/15 Gemini Mac app, 2025/08/06 glow colors, 2025/05/16 loading indicator); blog.google/products/pixel/google-pixel-sound-design; medium.com/google-design/designing-sound-and-silence-1b9674301ec1; archive.org/details/material-design-sound-resources.

## KEY FACTS
- Google Sans Flex became free/open (~Nov 18-19 2025) under SIL OFL 1.1 on Google Fonts and Fontsource (@fontsource-variable/google-sans-flex); an open-source Mac app MAY bundle it (ship OFL.txt + copyright; rename if modified; can't sell font alone). No public upstream repo yet (google/fonts issues #10006/#10077).
- Google Sans Flex axes: wght 1-1000, wdth 25-151, opsz 6-144, slnt -10-0, GRAD 0-100, ROND 0-100 (roundness); rebuilt by David Berlow/Font Bureau. Google Sans Code is OFL on github.com/googlefonts/googlesans-code (wght 300-800). Roboto Flex is the OFL 13-axis fallback. Original Google Sans/Product Sans remain proprietary.
- M3 spring tokens: standard spatial fast/default/slow = stiffness 1400/700/300 @ damping 0.9; effects = 3800/1600/800 @ damping 1.0 (never bounce); M3 Expressive spatial fast/default/slow = 800 @ 0.6, 380 @ 0.8, 200 @ 0.8. Spatial springs move things; effects springs fade/recolor things.
- M3 easing/duration tokens: emphasized cubic-bezier(0.2,0,0,1); emphasized-decelerate (0.05,0.7,0.1,1); emphasized-accelerate (0.3,0,0.8,0.15); durations 50-200ms (short), 250-400 (medium), 450-600 (long), 700-1000 (extra-long).
- M3 corner radius tokens: 4 / 8 / 12 / 16 / 20 / 28-32 dp + 'full' (pill). M3 Expressive (I/O 2025) added a 35-shape library, shape-morph press states, and a loading indicator that loops a morph through 7 shapes (replaces spinners for waits <5s).
- Google brand colors: Blue #4285F4, Red #EA4335, Yellow #FBBC04, Green #34A853. Production GM3 (Gmail/Drive/Chrome): light primary #0B57D0 / container #D3E3FD / on-container #041E49; dark primary #A8C7FA / container #0842A0; Gemini dark bg ~#131314.
- M3 tonal-palette rules: primary = tone 40 light / tone 80 dark; container = 90/30; surface = ~98 light / 6 dark (never pure black); state layers hover 8%, focus/pressed 10-12%, dragged 16%; elevation levels 0/1/3/6/8/12dp with surface tint instead of heavy shadows.
- M3 type scale: Display 57/45/36, Headline 32/28/24 Regular, Title 22 Reg & 16/14 Medium, Body 16/14/12 Regular, Label 14/12/11 Medium.
- Gemini spark = four-point star built from negative space of four adjoining circles; mid-2025 redesign rounded it and applied the four Google colors; the assistant overlay glow switched Aug 2025 from blue-purple to a blue/red/yellow/green gradient.
- Classic Gemini 'AI shimmer' gradient (Bard CSS): linear-gradient(74deg, #4285F4 0%, #9B72CB 9%, #D96570 20-24%, back through #9B72CB to #4285F4 44%...) animated over background-size 400% 100%.
- Gemini Live UI (the best dictation-HUD reference): bottom pill with blue waveform inside, camera/screen-share left, mic-mute right, live transcription above; collapses to a draggable circle (chathead) during multitasking; tap to expand, swipe down to dismiss; fullscreen Live UI retired April 2026 (Google app 17.14.60).
- Google launched a NATIVE Gemini Mac app Apr 15 2026 (Swift, macOS 15+, free): Option+Space compact floating 'Ask Gemini' pill, Option+Shift+Space full window, spark icon in menu bar, screen sharing for context — and it adopts Apple's Liquid Glass rather than strict Material, keeping only Google brand color/type/iconography.
- Chrome Refresh 2023 (Chrome 117, Sep 12 2023) is the canonical Material-3-on-desktop translation: pill tabs, rounded omnibox/menus, seed-color tonal theming.
- Material sound resources: 40 CC-BY-4.0 audio files (hero, alerts/notifications, primary system, secondary system; WAV/FLAC/OGG/MP3/AAC) — legally shippable in an open-source app with attribution (archive.org/details/material-design-sound-resources).
- Google sound philosophy: 'simple, human, playful'; tonal sounds for personality/state, atonal for motion/haptics; design silence like negative space (Conor O'Sullivan); sounds sync to motion frame-accurately; team of ~12 designers.
- Google's sonic logo: the 'Super G' Gemini/Assistant sound is a G-major chord swelling into a single G note; Gemini for Home plays a short chime at listening-start and listening-end — the exact earcon pattern for push-to-talk.
- SwiftUI mapping: M3 damping = dampingFraction; expressive default spatial ~ spring(response 0.32, dampingFraction 0.8); effects springs ~ dampingFraction 1.0; CSS approximations: expressive spatial default = 500ms cubic-bezier(0.38,1.21,0.22,1).
- Trademark boundary: Google Sans Flex the FONT is open, but the Gemini spark, 'G' logo, and product names are protected brand assets — evoke (four-color palette, pill+waveform, spark-like glyph) without copying.

## RECOMMENDATIONS
- Bundle Google Sans Flex VF as the sole UI font (OFL text in About/repo), using opsz ~17 + GRAD 0/+25 (light/dark) for UI, ROND 15-30 for friendly headlines; Google Sans Code for transcripts/mono; declare Roboto Flex as fallback.
- Model the HUD directly on the 2026 Gemini Live pill: bottom-center floating full-pill (~48-56pt tall) with amplitude-reactive rounded-bar waveform in #4285F4, streaming transcript above the pill, mute state visible, collapse-to-draggable-dot when idle, tap-to-expand / Esc-or-swipe-to-dismiss.
- Use the two M3 spring families literally in SwiftUI: expressive spatial (stiffness 380-800, damping 0.6-0.8 -> visible overshoot) for pill appear/expand/morph; effects springs (damping 1.0) or emphasized-decelerate 250-400ms for fades and color; never bounce opacity/color.
- Adopt GM3 production colors, not raw brand colors, for chrome: accent #0B57D0 light / #A8C7FA dark, containers #D3E3FD / #0842A0, dark surfaces #131314-#1E1F20 (never #000), state layers 8/10/16%; reserve the four-color #4285F4/#EA4335/#FBBC04/#34A853 sweep and the #4285F4->#9B72CB->#D96570 animated gradient glow for 'AI processing' moments only.
- Corner radii: pill (full) for the HUD and buttons, 28dp for the expanded transcript card, 12dp for menus/popovers; implement M3E press feedback as a shape morph (circle->rounded square) and replace any spinner with the 7-shape M3E loading morph.
- Sound: build a tiny G-major earcon family — ~250ms soft-mallet upward swell to G for start-listening, inverse resolve for stop/insert, muted low tap for error — mixed quiet with rounded attacks; bootstrap from the CC-BY Material sound pack (state-change_confirm-up/down, alert_error-01) with attribution; no sounds on hover/keys (design the silence).
- Follow Google's own Mac playbook (Gemini Mac app): keep Google color/type/motion/sound identity but respect macOS conventions — menu-bar item with spark-like (not Gemini-identical) glyph, Option+Space-style global shortcut (ours should default to something non-conflicting like Fn/Globe or Option+Space alternative), native vibrancy/NSVisualEffectView under Material-tinted surfaces, no Electron.
- Legal hygiene for the open-source repo: include OFL.txt for Google Sans Flex/Code, CC-BY attribution file for any Material sounds, and design an original spark/waveform mark — do not reuse the Gemini spark, Google 'G', or four-circle construction verbatim.
- Consider shipping the M3 motion tokens as a small Swift 'MaterialMotion' constants file (springs + beziers + durations above) so all animation goes through tokens — this is what will make the app feel systematically Google rather than ad-hoc.

## OPEN QUESTIONS
- Exact retail licensing status of Google Sans Flex weights served via fonts.google.com vs a future upstream repo (no googlefonts/google-sans-flex repo exists yet; only the served TTF is OFL-labeled) — worth re-checking before v1 ships.
- Precise waveform rendering spec of Gemini Live (bar count, corner radius, FFT smoothing, four-color vs mono-blue in 2026 builds) — needs visual inspection of a Pixel/iOS device or APK assets rather than press coverage.
- Official M3 'emphasized' easing is a path-based two-segment curve, not a single cubic-bezier — decide whether to implement the true piecewise curve or the (0.2,0,0,1) approximation.
- Exact audio files/notes used for Gemini Live start/stop chimes (not published; would require recording/analyzing them — cannot be copied anyway, only stylistically referenced).
- Whether Google's Gemini Mac app added Material 3 Expressive motion behaviors in point releases after April 2026 (post-cutoff 'Gemini Spark' June 2026 updates were announced but design details were not researched).
- Confirmed hex values for GM3 dark on-primary (#062E6F assumed as tone 20 of the #0B57D0 palette) — derive properly by running the seed through material-color-utilities (HCT) rather than trusting observed CSS.
