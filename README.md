# Piano Tunah

Piano tuner in the browser. Listens through the computer's microphone, computes stretch from the strings' inharmonicity and saves tunings per piano.

<picture>
  <source media="(prefers-color-scheme: dark)" srcset="docs/screenshot-dark.png">
  <img alt="Piano Tunah: keyboard, deviation, strobe and beat spectrogram" src="docs/screenshot-light.png">
</picture>

## Features

- Key detection A0–C8 and measurement to a hundredth of a cent. In the bass, partial 6, 4 or 2 is measured.
- Survey: *Quick* (A0–A6) or *Whole piano*. Measures inharmonicity and the current pitch.
- Stretch with octave type 2:1–8:4 per register, Railsback curve and extra stretch at the ends.
- Temperaments: equal, Werckmeister III, Kirnberger III, Vallotti, Young II, ¼- and ⅙-comma meantone.
- Reference A4 380–480 Hz, or set from the piano's current pitch. Overpull for pitch raises, with a recommended amount when the piano is flat.
- Strobe, beat spectrogram and reference tone (piano or sine).
- Deviation per key as bars under the keyboard; the full tuning curve under Settings.
- Upright or grand, size in cm, 85 or 88 keys.
- Tunings are saved on the server with a history per pass. Export and import as JSON.
- English and Swedish UI.

## Theory

**Inharmonicity.** A stiff string has partials above the integer multiples:

$$f_n = n f_0 \sqrt{1 + B n^2}$$

$B$ is estimated per key from the measured partials. The expression is linear in $n^2$ and solved by least squares:

$$\left(\frac{f_n}{n}\right)^2 = f_0^2 + f_0^2 B\, n^2$$

Before the piano is measured, $B$ is guessed from the instrument's size. Measured values correct the guess, and the correction (the ratio to the model, on a log scale) is interpolated between measured keys.

**Stretch.** Octave type $p{:}q$ ($p = 2q$) makes partial $p$ of the lower note and partial $q$ of the upper note beatless. With $B_1$ for the lower and $B_2$ for the upper string, the octave is wider than 1200 cents by

$$\Delta = 1200 \log_2 \frac{g(B_1, p)}{g(B_2, q)}, \qquad g(B, n) = \sqrt{\frac{1 + B n^2}{1 + B}}$$

The temperament octave A3–A4 is laid first. Then the octaves are built up and down one at a time.

**Temperament.** A temperament is given as the deviation from a pure fifth for each of the twelve fifths. The sum is always $-\mathrm{PC}$, the Pythagorean comma (≈ 23.46 cents).

**Overpull.** When the pitch is raised, strings already tuned drop as the load on the plate and soundboard grows. Each key is tuned past the target by a share of how far it started from it: with 25%, a key at −16 cents is tuned to +4. The app recommends 25% when the middle of the piano is 10 cents or more flat.

**Measurement.** An FFT (16,384 points) gives the rough position of the peaks. The frequency is then refined from the phase difference $\Delta\varphi$ between two windows offset by $H$ samples:

$$f = f_c + \frac{f_s}{2\pi H}\,\mathrm{wrap}\left(\Delta\varphi - \frac{2\pi f_c H}{f_s}\right)$$

where $\mathrm{wrap}$ puts the angle in $(-\pi, \pi]$.

<picture>
  <source media="(prefers-color-scheme: dark)" srcset="docs/settings-dark.png">
  <img alt="Settings with the tuning curve for a 115 cm upright" src="docs/settings-light.png">
</picture>

## Installation

```sh
cp .env.example .env                          # reverse proxy settings
docker compose pull && docker compose up -d   # release image from ghcr.io
docker compose up -d --build                  # or build locally
```

The image is built `FROM scratch` (~7 MB) for amd64 and arm64: a static Go binary with the web app embedded. The container runs read-only as uid 1000 without capabilities, and data lives in `./data`. It listens on port 8080 over plain http.

| Variable   | Default | |
|------------|---------|-|
| `ADDR`     | `:8080` | listen address |
| `DATA_DIR` | `/data` | saved tunings (JSON) |

### Reverse proxy

Browsers only allow the microphone over https (or on `localhost`), so the app runs behind a reverse proxy.

**Traefik.** `.env.example` is set up for Traefik: `COMPOSE_FILE` adds `compose.traefik.yaml` with the router labels, and the `TRAEFIK_*` values set the hostname, Docker network, entrypoint and middlewares.

**Caddy.** Leave out `COMPOSE_FILE` and the `TRAEFIK_*` values, and publish the port on localhost in `compose.override.yaml` (Compose loads it automatically):

```yaml
services:
  pianotunah:
    ports:
      - 127.0.0.1:8080:8080
```

Caddyfile:

```caddyfile
pianotunah.example.com {
	# LAN only; remove these two lines to make it public.
	@outside not remote_ip private_ranges
	abort @outside

	reverse_proxy 127.0.0.1:8080
}
```

Caddy gets the certificate itself. A host that is not reachable from the internet needs the DNS challenge or `tls internal`. If Caddy runs in a container, put both containers on the same Docker network and use `reverse_proxy pianotunah:8080` instead of publishing the port.

Tests, releases and code layout: [DEVELOP.md](DEVELOP.md).
