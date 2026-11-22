# Porting Piano Tunah to a native macOS app

A plan for a native Mac version of Piano Tunah next to the web version. [Svenska](macos-port.sv.md).

Status: decided, being built on the branch `macos-port`. The app is for one Mac, is installed from GitHub Releases and updates itself, with no sync. See [Decisions](#decisions).

## Language: Swift, not Rust

The app is Swift 6 with SwiftUI, AVAudioEngine and Foundation, for macOS 26 for now, later 27 ([ADR 0001](adr/0001-native-mac-app-in-swift.md)).

- **The UI has to be SwiftUI or AppKit either way.** With Rust, either Swift draws the UI anyway and Rust is a library behind UniFFI, or the UI is something like egui or Tauri, which does not look or feel like a Mac app.
- **The core is small.** theory, dsp, survey, order and format total about 1,200 lines of JS. A Rust core would add a second toolchain, a C or UniFFI bridge and an xcframework build to the project. That costs more than writing 1,200 lines of Swift.
- **Audio is Apple's.** Microphone permission, device choice, voice processing, sleep and device changes all go through AVFoundation and Core Audio. Rust's `cpal` covers less of this, and the Swift glue would still be needed.
- **Rust would pay off only if one core served both the web (as WASM) and the Mac.** Nobody has asked for that, and the web version works in JS. If the need comes, the Swift core and its fixtures (below) are a precise specification to port from.

The app supports one macOS version and no older ones, so it uses the newest SwiftUI and Observation APIs directly, with no availability checks. The deployment target is macOS 26 for now: GitHub's macOS runners have Xcode 26.6 and no macOS 27 SDK yet (November 2026), and every step of the app is compiled there. It runs on macOS 27 as it is. When the runners get Xcode 27, the target (`mac/project.yml`, `sparkle:minimumSystemVersion`) moves to 27 in one change. Swift 6 language mode with strict concurrency checking.

## Shape

```
mac/
├── Package.swift                 PianoTunahCore: pure Swift, no Apple-only frameworks
├── Sources/PianoTunahCore/
│   ├── Theory.swift              ← web/js/theory.js
│   ├── DSP.swift                 ← web/js/dsp.js (own FFT, see below)
│   ├── Survey.swift              ← web/js/survey.js
│   ├── Order.swift               ← web/js/order.js
│   ├── Format.swift              ← web/js/format.js (decimal separator passed in)
│   ├── Engine.swift              ← web/js/engine.js (logic taken out of app.js, step 0)
│   └── Piano.swift               the saved document, Codable, same JSON as the web
├── Tests/PianoTunahCoreTests/    parity tests against the fixtures
│   └── Fixtures/                 generated from the JS by test/fixtures.mjs
└── PianoTunah.xcodeproj          the app: SwiftUI, audio, files, menus
    └── PianoTunah/
        ├── Audio/                MicInput, ToneEngine, Recorder, devices
        ├── Models/               PianoLibrary, TunerModel, SurveyModel, OrderModel
        ├── Views/                dial, keyboard, curve, panels, forms
        └── Localizable.xcstrings English and Swedish
```

The core package uses no Apple-only frameworks ([ADR 0003](adr/0003-mac-core-is-pure-swift.md)). It builds and tests on Linux in the `swift:6.4` container, so the same CI and the same agents that work here can run its tests. Only the app target needs Xcode. Foundation on Linux differs from Apple's in places, such as locale handling and number formatting, so the core's tests also run in Xcode on the Mac. The Format tests in particular must pass there.

## Step 0: take the logic out of app.js (in JS, first)

About 900 of app.js's 2,177 lines are domain logic mixed with the DOM:

- deviations and status (`devOf`, `curDev`, `statusDev`);
- frame analysis (`analyseFrame`, attacks, noise gate);
- following the key (`followDetectedKey`, `jumpConfirmed`);
- measuring (`measureCurrent`, `recordKey`, `storeB`);
- beats (`trackBeating`, `beatUnheard`);
- survey and order progress (`collectSurvey`, `advanceSurvey`, `trackOrder`, `recheckKeys`);
- the pass summary, `fitRefToPiano` and the clamping rules.

Move these into a DOM-free `web/js/engine.js` with unit tests, and leave app.js as the DOM layer. The web app gets better tests from this, and the Swift port becomes a module-by-module translation with no guessing about what app.js does. This is the riskiest refactor in the plan, so it is checked by the existing end-to-end tests (`e2e`, `survey`, `order`, `sync`) before anything else starts.

## Step 1: fixtures that prove parity

`test/fixtures.mjs` runs the JS modules and writes JSON files of inputs and expected outputs to `mac/Tests/PianoTunahCoreTests/Fixtures/`. The Swift tests read the same files.

- **Exact or within 1e-12:**
  - `computeTargets` across presets, sizes, temperaments, roots and measured B, including outliers;
  - `temperamentOffsets`, 7 × 12;
  - `migrateSettings` and `bOutliers`;
  - `buildOrder` for the four top and DSU settings, plus `checkRows` and `tunedBefore`;
  - the survey state machine, `steady` and `confirmReading` sequences;
  - `fmtC` and `parseNum` in both languages.
- **Engine, decisions exact and numbers within 1e-9:** engine.js scenarios, a sequence of readings in and state out. Which key, which step and whether a key is done must match exactly. Apple's libm and V8 may differ by an ulp in `log2` and `pow`, and those differences add up over a sequence, so the numbers get a looser tolerance than above.
- **The piano document, there and back:** copies of the two pianos in `data/`, one of them saved before `settings.unisons` existed, with the id, name and notes replaced (`data/` is in `.gitignore` and holds real pianos). Decoding and encoding again must give the same JSON value, key order aside. Decoding must give the same settings as `normalize` and `migrateSettings`.
- **DSP, within 0.01 cent:** store the sound as Float32 binary rather than regenerating it in Swift. JS `Math.sin` and the seeded generator do not repeat exactly in Swift. Cover `measure`, `inharmonicity`, `detectKey` on a sample of keys, the B♭0 peak list and BeatMeter verdicts. Add a few seconds cut from one or two real recordings, with the readings the web version gives for them. `*.wav` is in `.gitignore`, so the excerpts are committed as `.f32` files.

The fixtures are generated in one pinned image, `node:26.13.1-alpine`, both locally and in CI. They are regenerated whenever the JS changes. CI regenerates them and fails if they differ from what is committed, so the two versions cannot drift apart unnoticed. The image is pinned exactly because Node takes `Math.pow` from the C library: with the same Node, Alpine's musl and glibc differ in the last bit of some values. Moving to a new Node means changing the image in both places, regenerating, and checking that only the last digits moved.

## Step 2: the core in Swift

Seven files in three waves, following the imports in the JS. Within a wave, each file can be written by its own agent against its fixtures.

1. **Theory, Survey, Format.** These depend on nothing else.
2. **DSP, Order.** Both use Theory.
3. **Piano, Engine.** Piano needs Theory for the migration. Engine uses all the others.

**Watch out for these** (from reading dsp.js):

- **FFT:** keep the own radix-2 FFT in Float64 rather than vDSP. It keeps the core building on Linux, and 16,384 points 11 times a second is nothing for a Mac. vDSP can come later behind a protocol if profiling asks for it.
- **Hann window:** symmetric, with the denominator n − 1.
- **DFTs and the beat search:** `dftPhase` and `dftDb` rotate a phasor recursively. The beat search steps `rate += 0.05`. Copy both loops as they are; a cleaner formula gives slightly different numbers.
- **Rounding:** JS `Math.round` rounds halves up. Swift `.rounded()` rounds them away from zero. Use one helper, `jsRound`, that rounds like `Math.round`. A plain `floor(x + 0.5)` gets 0.49999999999999994 wrong, so give the helper its own fixture.
- **Division and conversions:**
  - division by zero must give ±∞ or NaN, never a trap;
  - `NaN ≥ 10` is false;
  - `Number(x) || default` needs explicit handling of 0 and NaN.
- **Text:** the minus sign is U+2212. `toExponential(2)` gives `1.23e-4`, without a leading zero in the exponent.

## Step 3: audio

**Input**
- An `AVAudioSinkNode` or `installTap` with a small buffer (512–1024) on the input writes channel 0 into a lock-free ring buffer of 32,768 samples.
- Analysis runs on its own queue every 90 ms of samples (4,320 at 48 kHz), counted by the audio clock rather than a timer. The frame time comes from `AVAudioTime.sampleTime`.
- Use the hardware sample rate. At 96 kHz the fixed windows cover half the time, and on Bluetooth headsets the bandwidth is too low. Resample to 48 kHz in those cases, or warn the user.

**Permission and settings**
- Microphone permission needs `NSMicrophoneUsageDescription` and `AVCaptureDevice.requestAccess`. The entitlement `com.apple.security.device.audio-input` is needed only with the App Sandbox or the hardened runtime, and the app uses neither (step 6).
- Without permission the engine delivers silence, not an error. Check `authorizationStatus` and link to System Settings › Privacy › Microphone.
- Voice processing is off by default and must stay off. That replaces the web version's `echoCancellation: false`.

**Devices and lifecycle**
- Choose the device by UID through Core Audio (`kAudioOutputUnitProperty_CurrentDevice`).
- Restart on `AVAudioEngineConfigurationChange` and after sleep.
- `ProcessInfo.beginActivity(.idleDisplaySleepDisabled)` replaces the wake lock and stops App Nap.

**Tone and recording**
- The reference tone uses a separate engine with an `AVAudioSourceNode`: pluck or sine with the web's partials and envelopes.
- Keep the gate that ignores readings while a tone plays and for 800 ms after.
- Recording goes from the same tap to a WAV in Float32, max 120 s, saved with `fileExporter`.

The audio callback and the render block must not allocate memory or take locks. The UI gets an immutable snapshot about 11 times a second.

## Step 4: the app

- **Window:** one main window with a `NavigationSplitView`.
  - **Sidebar:** the pianos.
  - **Main area:** the dial, the survey and order panels, and the keyboard with the curve.
  - **Folds:** beats and partials.
  - **Inspector:** the piano's settings. The Piano, Tuning and Pass tabs become sections of it.
- **Settings scene (⌘,):** what the App tab holds today: microphone, recording and color mode.
- **Menus:**
  - Tuner: microphone, Auto/Lock, previous/next key, tone, survey, order, measure B.
  - Piano: new, duplicate, import, export, delete, new pass.
  - Keep today's single-letter shortcuts in the tuner view (← → L A O T S H Esc).
- **Drawing:** the dial and the beat strip are `Canvas` in a `TimelineView(.animation)`. The geometry in draw.js is proportional to the width and carries over almost line by line.
  - The spectrogram is a 100 × 48 `CGImage` updated each frame.
  - The curve shares its key positions with the keyboard view. Use `Canvas` rather than Swift Charts, so the curve stays aligned with the keys.
  - Animation phases live outside the observed state, so 60–120 fps does not redraw the views.
- **Strings:** a String Catalog with the 366 keys in English and Swedish.
  - `{name}` becomes `%@`.
  - Counts get real plural forms.
  - The app follows the language macOS gives it (System Settings › General › Language & Region, per app). The web's language picker is not carried over.
  - Sentences that are assembled from pieces today become whole sentences.
  - Help becomes Markdown in the app.
  - The ♭ ♮ ♯ font is bundled as OTF under its OFL licence.
- **Colors:** the ~23 CSS variables become color assets with light and dark variants. Auto/Light/Dark sets `NSApp.appearance`.

Estimate: core 1,100–1,300 lines plus 600 lines of tests, app 4,000–5,000 lines.

## Step 5: storage

Each piano is a JSON file in `~/Library/Application Support/Piano Tunah/`, in exactly the web's format, so export and import work both ways between the versions ([ADR 0002](adr/0002-mac-app-stores-web-json-locally.md)). The app is not sandboxed (step 6), so the folder is where the path says, and Time Machine backs it up.

- Decode leniently: every field optional, defaults filled in, and the same migration as `normalize` and `migrateSettings`.
- Keep unknown fields when writing, so a file round-trips.
- `at` stays a number of milliseconds.
- Save automatically 2.5 s after a change and when the app quits.

There is no sync. The app does not talk to the Go server; its only network traffic is the update check in step 6. Pianos move between the web and the Mac by export and import. Because the format and `rev` are kept, sync could still be added later without changing the server.

## Step 6: releases and automatic updates

The app updates itself from GitHub Releases with [Sparkle](https://sparkle-project.org) 2 ([ADR 0004](adr/0004-mac-app-updates-itself-from-github.md)).

- **The feed** is `https://github.com/riborg/pianotunah/releases/latest/download/appcast.xml`, an asset on the latest release. GitHub skips pre-releases and drafts for `latest`, so a `v1.2.0-rc.1` never reaches the app, the same rule as the image's `latest` tag.
- **Checks:** Sparkle checks once a day and at launch, downloads a new version in the background and installs it when the app quits (`SUEnableAutomaticChecks`, `SUAutomaticallyUpdate`). *Check for Updates…* in the app menu checks at once.
- **Signature of the update:** every release zip is signed with an EdDSA key. The public key is in Info.plist (`SUPublicEDKey`), the private key is an Actions secret. Sparkle refuses an update that does not match.
- **Code signing:** no Apple Developer account, so no Developer ID and no notarization. CI signs with a self-signed code-signing certificate, made once and kept as an Actions secret. The same certificate in every release keeps the app's identity stable, so macOS keeps the microphone permission across updates. Ad-hoc signing would give each build a new identity and ask for the microphone again after every update.
- **First install:** download the zip from the release, move the app to Applications and open it. macOS blocks an app that is not notarized the first time; allow it once under System Settings › Privacy & Security › *Open Anyway*. Updates are installed by Sparkle and should not ask again; check that on the first real update.
- **No App Sandbox, no hardened runtime.** Sparkle in a sandboxed app needs extra installer services and entitlements, which is not worth it for one Mac. The hardened runtime matters only for notarization. Put `NSMicrophoneUsageDescription` in Info.plist; without it the app is stopped the first time it opens the microphone.
- **Version numbers:** `CFBundleShortVersionString` is the tag without `v` (1.2.0). `CFBundleVersion`, which Sparkle compares, is the number of commits up to the tag, so it always grows.

**The release job.** The release workflow runs on `v*` tags. Today one job builds the image and creates the GitHub Release. It changes like this:

1. **`release`** (as today) publishes the image, but creates the GitHub Release as a **draft**, and only if the tag has no release yet (`gh release view` first), so a re-run of a failed workflow continues with the same draft. Use `gh`, not the REST endpoint `releases/tags/{tag}`: that endpoint does not return drafts, while `gh release view` and `gh release upload` also look the tag up among drafts (through GraphQL, so they need `GH_TOKEN`, which the step that creates the release already sets). Only a *release not found* answer means the release is missing; any other error fails the job rather than creating a second draft. The image does not wait for the Mac. Uploads use `gh release upload --clobber`.
2. **`mac`**, a new job on a macOS runner, runs next to it after `ci`, with `fetch-depth: 0`, since the version number counts commits:
   1. builds the app with `xcodebuild` in Release, version numbers from the tag;
   2. signs it with the certificate from the secrets, imported into a temporary keychain. The certificate is self-signed and not trusted there, so `codesign` picks it by its SHA-1 hash. `security find-identity -p codesigning <keychain>` without `-v` lists it with the hash; `-v` hides untrusted identities. Sparkle's nested helpers (Autoupdate, Updater.app and the XPC services) are signed with the same identity, inside out, before the app itself;
   3. zips it with `ditto -c -k --keepParent` and signs the zip with Sparkle's `sign_update`;
   4. writes `appcast.xml` with one `<item>` for this version:
      - `sparkle:version` = `CFBundleVersion`;
      - `sparkle:shortVersionString` = the tag without `v`;
      - `sparkle:minimumSystemVersion` = the deployment target (26.0 for now);
      - a `sparkle:releaseNotesLink` to the GitHub Release;
      - an `<enclosure>` whose `url` is the tag's own asset, `releases/download/vX.Y.Z/PianoTunah.zip`, never the `latest` URL, with `sparkle:edSignature` and `length` from `sign_update`;
   5. saves the zip and the appcast as workflow artifacts.
3. **`publish`** needs both. It uploads the two files to the draft and publishes it (`gh release edit --draft=false`, plus `--prerelease` for tags with `-`).

If the Mac job fails, the release stays a draft and the run is red. `releases/latest` then keeps pointing at the previous release, which has its appcast, so installed apps see no 404 and simply stay on the version they have. The image is published either way. Fix the build, or build on your Mac, upload the two files to the draft by hand, and publish it.

Pre-release tags (`-rc.1`) build the Mac app too, so a pre-release can be tried by downloading it. Its appcast is never read, because `latest` skips pre-releases.

**Runner.** The job uses GitHub's newest macOS image and selects its newest Xcode. That Xcode must have the SDK of the deployment target; if it does not, the job fails and the rule above applies. If that happens more than once, register your Mac as a self-hosted runner for this job.

**One-time setup on your Mac.**
- Sparkle's `generate_keys` makes the EdDSA key pair.
- Make the code-signing certificate with `openssl`, valid for 10 years, and export it as a .p12. A self-signed certificate from Keychain Access lasts one year by default. A new certificate is a new identity, and macOS would ask for the microphone again. Sparkle itself checks the update by its EdDSA signature, so a new certificate would not stop the update; the microphone permission is the reason to keep it.
- Secrets: `SPARKLE_ED_PRIVATE_KEY`, `MAC_SIGNING_P12` and `MAC_SIGNING_PASSWORD`.

## Order and agents

| Phase | Work | Parallel |
|---|---|---|
| 0 | engine.js out of app.js, unit tests, the end-to-end tests green | 1 agent; it touches all of app.js |
| 1 | test/fixtures.mjs, the Swift package skeleton, the CI job in `swift:6.4` | 1 agent |
| 2 | Theory, Survey, Order, Format, DSP, Engine, Piano in Swift | three waves of 3, 2 and 2 agents, one file each, against the fixtures |
| 3 | Audio: input, tone, recording, devices | 1 agent; needs a Mac to run |
| 4 | Views and models | 3 agents: dial and folds, keyboard and curve, panels and inspector |
| 5 | Storage, import/export, menus, Settings, strings | 1–2 agents |
| 6 | Release job, Sparkle, appcast | 1 agent; you make the keys and the certificate once |

Phases 0–2 can run entirely here on Linux. From phase 3 on, the app is built and tried in Xcode on your Mac. The core's tests still run in CI.

## Decisions

1. **Distribution:** for your own use, installed from GitHub Releases. The app watches GitHub and updates itself when a new version is released ([ADR 0004](adr/0004-mac-app-updates-itself-from-github.md)).
2. **Several devices:** not needed. The Mac app is used on its own, so there is no sync ([ADR 0002](adr/0002-mac-app-stores-web-json-locally.md)).
3. **UI language:** follow macOS.
4. **Minimum version:** macOS 26 for now, so that CI can build the app; 27 once GitHub's runners have Xcode 27.
