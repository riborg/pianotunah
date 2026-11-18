# Development

The host needs neither Node nor Go. Everything runs in containers. [Svenska](DEVELOP.sv.md).

## Tests

```sh
# Unit tests (theory and signal processing)
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

CI in `.github/workflows/ci.yml` runs the unit tests, `go vet`, a test build for amd64 and arm64, and govulncheck on the binary in the image. `vuln.yml` scans the published `latest` image every Monday. A red run means it is time for a release built with the latest Go patch.

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
| `web/js/saver.js` | save queue with revision check |
| `web/js/mic.js`, `recorder.js`, `tone.js` | microphone, recording (AudioWorklet) and reference tones |
| `web/js/i18n.js`, `lang/` | UI strings |
| `web/js/app.js` | state, DOM and events |
| `web/js/diag.js` | debug log to the server (`DEBUG=1`) |
| `web/fonts/` | ♭ ♮ ♯ from Bravura Text, built by `tools/accidentals.py` |
| `web/favicon.svg`, `web/icons/` | logo and app icons, built by `tools/icons.py` |
| `test/` | unit and end-to-end tests |
| `.github/workflows/` | CI, release, weekly vulnerability scan |
