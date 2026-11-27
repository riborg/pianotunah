# Development

The host needs neither Node nor Go. Everything runs in containers. [Svenska](DEVELOP.sv.md).

## Tests

```sh
# Unit tests (theory, signal processing and the engine)
docker run --rm -v "$PWD":/app -w /app node:26-alpine npm test

# End-to-end: headless Chrome with a synthetic piano tone as the microphone,
# against the running container. With a directory as the second argument,
# the screenshots in docs/ are retaken.
# Runs as your user so the screenshots can be written.
docker run --rm --network container:pianotunah -v "$PWD":/home/pptruser/pt \
  --user "$(id -u):$(id -g)" -e PUPPETEER_CACHE_DIR=/home/pptruser/.cache/puppeteer ghcr.io/puppeteer/puppeteer \
  node pt/test/e2e.mjs http://localhost:8080 [pt/docs]

# Survey: a synthetic piano plays the keys the app asks for, including wrong
# keys and a skip. "full" adds a survey of all keys (about 2 minutes).
docker run --rm --network container:pianotunah -v "$PWD":/home/pptruser/pt ghcr.io/puppeteer/puppeteer \
  node pt/test/survey.mjs http://localhost:8080 [full]

# Tuning order: the synthetic piano plays the keys the order asks for, in tune
# and off, through the temperament and into the treble.
docker run --rm --network container:pianotunah -v "$PWD":/home/pptruser/pt ghcr.io/puppeteer/puppeteer \
  node pt/test/order.mjs http://localhost:8080

# Coming back to a tab: two devices on one tuning; the one left behind shows
# where the other got to, or the conflict warning if it had unsaved changes.
docker run --rm --network container:pianotunah -v "$PWD":/home/pptruser/pt ghcr.io/puppeteer/puppeteer \
  node pt/test/sync.mjs http://localhost:8080
```

The end-to-end tests share the app container's network, so they work with any reverse proxy. They create and delete their own tuning.

CI in `.github/workflows/ci.yml` runs the unit tests, `go vet`, a test build for amd64 and arm64, govulncheck on the binary in the image, and the macOS app's checks below. `vuln.yml` scans the published `latest` image every Monday. A red run means it is time for a release built with the latest Go patch.

## macOS app

The native Mac version is being built in `mac/`, following [docs/macos-port.md](docs/macos-port.md). Its core, the Swift package `PianoTunahCore`, is tested against fixtures written from the web JS, so the two versions compute the same things.

```sh
# Regenerate the fixtures in mac/Tests/PianoTunahCoreTests/Fixtures/ after a
# change to web/js/. Commit them with the change.
docker run --rm --user "$(id -u):$(id -g)" -v "$PWD":/app -w /app node:26.13.1-alpine node test/fixtures.mjs

# Swift tests of the core
docker run --rm --user "$(id -u):$(id -g)" -e HOME=/tmp -v "$PWD/mac":/pkg -w /pkg swift:6.4 swift test
```

CI regenerates the fixtures in the same image and fails if they differ from the committed ones. Use exactly that image: Node takes `Math.pow` from the C library, and Alpine's (musl) and glibc's differ in the last bit of some values. To move to a new Node, change the image here and in `ci.yml`, regenerate, check that only the last digits moved, and commit.

The piano documents `a` and `b` in the fixtures' `piano/` folder are copies of two real pianos with the id, name and notes replaced. `node test/fixtures.mjs --pianos data` takes new copies of the first two in `data/`.

### The app in Xcode

The app needs a Mac with Xcode 26 or later. Its Xcode project is generated from `mac/project.yml` by [XcodeGen](https://github.com/yonaskolb/XcodeGen) and is not committed, so generate it again after a pull that adds or removes files:

```sh
brew install xcodegen
cd mac && xcodegen generate && open PianoTunah.xcodeproj
```

Run the scheme `PianoTunah` with ⌘R. Debug builds are signed to run locally, without a developer account. The pianos are saved in `~/Library/Application Support/Piano Tunah/`. CI builds the app the same way on every push, unsigned.

The app's own tests are in `mac/PianoTunahTests/` (the target `PianoTunahTests`, run with ⌘U). They run inside the app, which starts as usual but without the microphone, and test its models, such as what quitting does with an unsaved recording. Dialogs such as the quit alert sit behind a seam that the tests answer (`RecordingModel.quitPrompts`). CI runs them on every push. The core's tests stay in the Swift package (`swift test`).

Only the release job gives the app Sparkle's public key (the build setting `SPARKLE_PUBLIC_KEY`, written to `SUPublicEDKey`). Without it the app never starts the updater and has no *Check for Updates…*, so a build from Xcode never replaces itself with a release. CI checks that a Debug build has no key.

## Release

```sh
git tag -a v1.2.0 -m v1.2.0
git push origin v1.2.0
```

GitHub Actions runs CI and publishes `ghcr.io/riborg/pianotunah` with the tags `1.2.0`, `1.2`, `1` and `latest`. Pre-releases such as `v1.2.0-rc.1` do not get `latest`. The workflow creates a draft GitHub Release with the commits since the previous tag, builds the Mac app next to the image, and publishes the release once the app and its appcast are in it.

Moving an existing tag triggers the release again and overwrites `latest`. Disable the Release workflow first.

### The Mac app

The Mac app updates itself from GitHub Releases with Sparkle ([docs/macos-port.md](docs/macos-port.md), step 6). A release goes like this:

1. `ci` runs, including `release-dry-run` below.
2. `release` publishes the image and creates the GitHub Release as a **draft**, or continues with the one a failed run left.
3. `mac`, at the same time, runs `mac/scripts/release.sh` on a macOS runner. It:
   1. builds the app in Release, version `1.2.0` from the tag and the build number from `build-number.sh` (`C.99` for a release, `C.N` for a pre-release, C = the commits up to the tag);
   2. signs Sparkle's helpers and then the app with your certificate, from a temporary keychain;
   3. zips the app, signs the zip with Sparkle's `sign_update`, and writes `appcast.xml`;
   4. checks the lot with `check-release.sh`.
4. `publish` uploads `PianoTunah.zip` and `appcast.xml` to the draft and publishes it. The installed apps see the new appcast at `releases/latest/download/appcast.xml` within a day, download the update and install it when they quit. Then `appcast.xml` also becomes the beta feed (`beta.xml` on the `appcast` branch) if its build is the newest, so apps with *Get beta versions* on get pre-releases such as `v1.2.0-beta.1` too.

If `mac` fails, the release stays a draft and the apps stay on the version they have. Fix it and re-run the failed jobs; the run continues with the same draft. Or run `mac/scripts/release.sh` on your Mac with the variables listed at its top, upload `mac/build/dist/*` to the draft with `gh release upload --clobber`, and publish it with `gh release edit v1.2.0 --draft=false`.

`mac/scripts/dry-run.sh` runs the whole Mac part for a fake `v0.0.1` with a throwaway certificate and key, in a temporary keychain. CI runs it on every push (`release-dry-run`); it also runs on your Mac.

**One-time setup on your Mac.** Do it before the next `v*` tag: until the three secrets exist, the Mac job fails on every tag and the GitHub Release stays a draft (the image is still published). Three secrets, made once and kept. The wizard `mac/scripts/setup-release-secrets.sh` walks you through it: it runs the commands below, checks the EdDSA key and the certificate's password, and lists the secrets on GitHub at the end. By hand:

```sh
cd mac && xcodegen generate
xcodebuild -resolvePackageDependencies -project PianoTunah.xcodeproj -clonedSourcePackagesDirPath build/SourcePackages
sparkle=build/SourcePackages/artifacts/sparkle/Sparkle/bin

# 1. The EdDSA key that updates are signed with. generate_keys keeps it in
#    your login keychain (your backup) and prints the public key; the release
#    job derives the public key from the private one, so nothing is committed.
"$sparkle/generate_keys"
"$sparkle/generate_keys" -x sparkle-private-key.txt
gh secret set SPARKLE_ED_PRIVATE_KEY < sparkle-private-key.txt
rm sparkle-private-key.txt

# 2. The code-signing certificate: self-signed with openssl, valid for 10
#    years, exported with its key as a .p12. Keep the .p12 and the password
#    (in your password manager, say).
export MAC_SIGNING_PASSWORD=$(openssl rand -base64 24)
scripts/make-signing-cert.sh ~/PianoTunah-signing.p12
base64 < ~/PianoTunah-signing.p12 | tr -d '\n' | gh secret set MAC_SIGNING_P12
printf %s "$MAC_SIGNING_PASSWORD" | gh secret set MAC_SIGNING_PASSWORD
```

Make a new certificate only when this one expires: a new certificate is a new identity, and macOS asks for the microphone again. A new EdDSA key would stop the installed apps from accepting updates at all, since they check against the key they were built with.

**First install.** Download `PianoTunah.zip` from the release, move the app to Applications and open it. macOS blocks it the first time, because it is not notarized; allow it once under System Settings › Privacy & Security › *Open Anyway*. Later versions come by themselves.

## Translations

UI strings are in `web/js/lang/en.js` and `sv.js`. Static markup uses `data-i18n` attributes, and code uses `tr('key', { param })`. A new string goes in both files. Missing keys fall back to English.

The documentation is in both languages: each `name.md` in the repo root and in `docs/` has a Swedish `name.sv.md`, and the two link to each other. The exceptions are `CLAUDE.md`, `CONTEXT.md` and `docs/agents/`, which are written for agents. A change to one document goes into the other in the same commit.

## API

The server answers `GET /api/tunings`, `GET|PUT|DELETE /api/tunings/{id}`, `GET /api/version` and `GET /healthz`. `PUT` requires the document's `rev` and answers 409 if someone else has saved since. The server refuses writes from another origin with 403.

## Code

| File | |
|------|-|
| `main.go` | server: static files and `/api/tunings` |
| `web/js/theory.js` | temperaments, inharmonicity, stretch, overpull, target frequencies |
| `web/js/dsp.js` | FFT, key detection, partial measurement, estimation of B |
| `web/js/draw.js` | canvas drawing |
| `web/js/survey.js` | survey plans and completion criteria |
| `web/js/order.js` | tuning order: steps, tasks, checks and when a task is done |
| `web/js/engine.js` | the tuner without the DOM: each frame of sound to readings, saved measurements, beats, survey and order progress |
| `web/js/saver.js` | save queue with revision check |
| `web/js/mic.js`, `recorder.js`, `tone.js` | microphone, recording (AudioWorklet) and reference tones |
| `web/js/i18n.js`, `lang/` | UI strings |
| `web/js/app.js` | DOM and events; draws what the engine does |
| `web/js/diag.js` | debug log to the server (`DEBUG=1`) |
| `web/fonts/` | ♭ ♮ ♯ from Bravura Text, built by `tools/accidentals.py` |
| `web/favicon.svg`, `web/icons/` | logo and app icons, built by `tools/icons.py` |
| `test/` | unit and end-to-end tests |
| `test/fixtures.mjs` | fixtures for the Swift tests, written from the web JS |
| `mac/` | the macOS app: Swift package `PianoTunahCore` and its tests |
| `mac/project.yml` | the app's Xcode project, for XcodeGen: target, build settings, Info.plist |
| `mac/PianoTunah/` | the app: SwiftUI views, the piano library, menus, updates, strings in English and Swedish |
| `mac/PianoTunah/Assets.xcassets/` | the Mac app icon, built by `tools/icons.py` |
| `mac/PianoTunah/Fonts/` | the same ♭ ♮ ♯ font as `web/fonts/`, with its license, built by `tools/accidentals.py` |
| `mac/scripts/` | the Mac release: build, sign, zip, appcast, checks and the dry run |
| `.github/workflows/` | CI, release, weekly vulnerability scan |
