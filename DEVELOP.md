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

## Release

```sh
git tag -a v1.2.0 -m v1.2.0
git push origin v1.2.0
```

GitHub Actions runs CI and publishes `ghcr.io/riborg/pianotunah` with the tags `1.2.0`, `1.2`, `1` and `latest`. The workflow then creates a GitHub Release with the commits since the previous tag. Pre-releases such as `v1.2.0-rc.1` do not get `latest`.

Moving an existing tag triggers the release again and overwrites `latest`. Disable the Release workflow first.

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
| `mac/PianoTunah/` | the app: SwiftUI views, the piano library, menus, strings in English and Swedish |
| `.github/workflows/` | CI, release, weekly vulnerability scan |
