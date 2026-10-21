# Development

Node and Go are not needed on the host; everything runs in containers.

## Tests

```sh
# Unit tests (theory and signal processing)
docker run --rm -v "$PWD":/app -w /app node:22-alpine npm test

# End-to-end: headless Chrome with a synthetic piano tone as the microphone,
# against the running container. With a directory as the second argument,
# the screenshots in docs/ are retaken.
docker run --rm --network container:pianotunah -v "$PWD":/usr/src/app/pt zenika/alpine-chrome:with-puppeteer \
  node pt/test/e2e.mjs http://localhost:8080 [pt/docs]

# Survey: a synthetic piano plays the keys the app asks for, including wrong
# keys and a skip. "full" adds a survey of all keys (about 2 minutes).
docker run --rm --network container:pianotunah -v "$PWD":/usr/src/app/pt zenika/alpine-chrome:with-puppeteer \
  node pt/test/survey.mjs http://localhost:8080 [full]
```

The end-to-end tests share the app container's network, so they work with any reverse proxy. They create and delete their own tuning.

CI (`.github/workflows/ci.yml`) runs the unit tests, `go vet`, a test build for amd64 and arm64, and govulncheck on the binary in the image. `vuln.yml` scans the published `latest` image every Monday; a red run means it is time for a release built with the latest Go patch.

## Release

```sh
git tag -a v1.2.0 -m v1.2.0
git push origin v1.2.0
```

GitHub Actions runs CI and publishes `ghcr.io/riborg/pianotunah` with the tags `1.2.0`, `1.2`, `1` and `latest`. A GitHub Release is then created with the commits since the previous tag. Pre-releases (`v1.2.0-rc.1`) do not get `latest`.

Moving an existing tag triggers the release again and overwrites `latest`. Disable the Release workflow first.

## Translations

UI strings are in `web/js/lang/en.js` and `sv.js`. Static markup uses `data-i18n` attributes, code uses `tr('key', { param })`. A new string goes in both files; missing keys fall back to English.

## API

`GET /api/tunings`, `GET|PUT|DELETE /api/tunings/{id}`, `GET /api/version`, `GET /healthz`. `PUT` requires the document's `rev` and answers 409 if someone else has saved since.

## Code

| File | |
|------|-|
| `main.go` | server: static files and `/api/tunings` |
| `web/js/theory.js` | temperaments, inharmonicity, stretch, overpull, target frequencies |
| `web/js/dsp.js` | FFT, key detection, partial measurement, estimation of B |
| `web/js/draw.js` | canvas drawing |
| `web/js/mapping.js` | survey plans and completion criteria |
| `web/js/saver.js` | save queue with revision check |
| `web/js/mic.js`, `recorder.js`, `tone.js` | microphone, recording (AudioWorklet) and reference tones |
| `web/js/i18n.js`, `lang/` | UI strings |
| `web/js/app.js` | state, DOM and events |
| `test/` | unit and end-to-end tests |
| `.github/workflows/` | CI, release, weekly vulnerability scan |
