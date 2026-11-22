# Porting Piano Tunah to a native macOS app

A plan for a native Mac version of Piano Tunah next to the web version. [Svenska](macos-port.sv.md).

Status: decided, not built yet. The app is for one Mac and is run from Xcode, with no sync. See [Decisions](#decisions).

## Language: Swift, not Rust

The app is Swift 6 with SwiftUI, AVAudioEngine and Foundation, for macOS 27 ([ADR 0001](adr/0001-native-mac-app-in-swift.md)).

- **The UI has to be SwiftUI or AppKit either way.** With Rust, either Swift draws the UI anyway and Rust is a library behind UniFFI, or the UI is something like egui or Tauri, which does not look or feel like a Mac app.
- **The core is small.** theory, dsp, survey, order and format total about 1,200 lines of JS. A Rust core would add a second toolchain, a C or UniFFI bridge and an xcframework build to the project. That costs more than writing 1,200 lines of Swift.
- **Audio is Apple's.** Microphone permission, device choice, voice processing, sleep and device changes all go through AVFoundation and Core Audio. Rust's `cpal` covers less of this, and the Swift glue would still be needed.
- **Rust would pay off only if one core served both the web (as WASM) and the Mac.** Nobody has asked for that, and the web version works in JS. If the need comes, the Swift core and its fixtures (below) are a precise specification to port from.

The app targets the current macOS (27) and supports no older versions, so it uses the newest SwiftUI and Observation APIs directly, with no availability checks. That needs the Xcode whose SDK is macOS 27. Phase 3 starts by checking that the installed Xcode has it. If it does not, the deployment target follows the SDK the installed Xcode has. Swift 6 language mode with strict concurrency checking.

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

The core package uses no Apple-only frameworks ([ADR 0003](adr/0003-mac-core-is-pure-swift.md)). It builds and tests on Linux in the `swift:6` container, so the same CI and the same agents that work here can run its tests. Only the app target needs Xcode. Foundation on Linux differs from Apple's in places, such as locale handling and number formatting, so the core's tests also run in Xcode on the Mac. The Format tests in particular must pass there.

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

The fixtures are generated with Node 26, the major version the unit tests and CI use. They are regenerated whenever the JS changes. CI regenerates them and fails if they differ from what is committed, so the two versions cannot drift apart unnoticed. The minor version of Node is not pinned, so a new V8 can move a `Math.*` result by an ulp. If CI fails with no change to the JS, regenerate the fixtures, check that only the last digits moved, and commit them.

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
- Microphone permission needs `NSMicrophoneUsageDescription`, the entitlement `com.apple.security.device.audio-input` and `AVCaptureDevice.requestAccess`.
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

Each piano is a JSON file in the app's Application Support folder, in exactly the web's format, so export and import work both ways between the versions ([ADR 0002](adr/0002-mac-app-stores-web-json-locally.md)).

The app is sandboxed (step 6), so that folder is inside its container: `~/Library/Containers/<bundle id>/Data/Library/Application Support/`.
- Set the bundle id once and never change it. A new id gets a new, empty container, and the pianos are left behind in the old one.
- Export is the way to get a piano out of the app. Time Machine backs up the container like any other folder.

- Decode leniently: every field optional, defaults filled in, and the same migration as `normalize` and `migrateSettings`.
- Keep unknown fields when writing, so a file round-trips.
- `at` stays a number of milliseconds.
- Save automatically 2.5 s after a change and when the app quits.

There is no sync. The app does not talk to the Go server, and it needs no network entitlement. Pianos move between the web and the Mac by export and import. Because the format and `rev` are kept, sync could still be added later without changing the server.

## Step 6: signing for one Mac

- Build and run from Xcode, signed with the personal team of your Apple ID (free) or *Sign to Run Locally*. No Developer ID, notarization or DMG.
- Keep the App Sandbox on, with two entitlements:
  - `com.apple.security.device.audio-input` for the microphone;
  - `com.apple.security.files.user-selected.read-write` for export, import and recordings.
- Put `NSMicrophoneUsageDescription` in Info.plist. Without it the app is stopped the first time it opens the microphone.
- If the app is shared later, Developer ID signing, notarization and a DMG built in Actions are the next step.

## Order and agents

| Phase | Work | Parallel |
|---|---|---|
| 0 | engine.js out of app.js, unit tests, the end-to-end tests green | 1 agent; it touches all of app.js |
| 1 | test/fixtures.mjs, the Swift package skeleton, the CI job in `swift:6` | 1 agent |
| 2 | Theory, Survey, Order, Format, DSP, Engine, Piano in Swift | three waves of 3, 2 and 2 agents, one file each, against the fixtures |
| 3 | Audio: input, tone, recording, devices | 1 agent; needs a Mac to run |
| 4 | Views and models | 3 agents: dial and folds, keyboard and curve, panels and inspector |
| 5 | Storage, import/export, menus, Settings, strings | 1–2 agents |
| 6 | Signing for local use | you in Xcode, with your Apple ID |

Phases 0–2 can run entirely here on Linux. From phase 3 on, the app is built and tried in Xcode on your Mac. The core's tests still run in CI.

## Decisions

1. **Distribution:** for your own use only, run from Xcode.
2. **Several devices:** not needed. The Mac app is used on its own, so there is no sync ([ADR 0002](adr/0002-mac-app-stores-web-json-locally.md)).
3. **UI language:** follow macOS.
4. **Minimum version:** macOS 27, the current one.
