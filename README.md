# Piano Tunah

Stämapparat för piano i webbläsaren. Lyssnar med datorns mikrofon, räknar fram stretch ur strängarnas inharmonicitet och sparar stämningar per piano.

<picture>
  <source media="(prefers-color-scheme: dark)" srcset="docs/screenshot-dark.png">
  <img alt="Piano Tunah: klaviatur, avvikelse, stroboskop och svävningsspektrogram" src="docs/screenshot-light.png">
</picture>

## Funktioner

- Tangentigenkänning A0–C8 och mätning på hundradels cent. I basen mäts delton 6, 4 eller 2.
- Kartläggning: *Snabb* (A0–A6) eller *Hela pianot*. Mäter inharmonicitet och nuvarande tonhöjd.
- Stretch med oktavtyp 2:1–8:4 per register, Railsback-kurva och extra stretch i ändarna.
- Temperaturer: liksvävande, Werckmeister III, Kirnberger III, Vallotti, Young II, medelton ¼ och ⅙ komma.
- Referens A4 380–480 Hz, eller satt efter pianots nuvarande tonhöjd. Överdrag vid uppdragning.
- Stroboskop, svävningsspektrogram och referenston (piano eller sinus).
- Pianino eller flygel, storlek i cm, 85 eller 88 tangenter.
- Stämningar sparas på servern med historik per omgång. Export och import som JSON.

## Teori

**Inharmonicitet.** En styv sträng har deltoner över heltalsmultiplerna:

$$f_n = n f_0 \sqrt{1 + B n^2}$$

$B$ skattas per tangent ur de uppmätta deltonerna. Uttrycket är linjärt i $n^2$ och löses med minsta kvadrat:

$$\left(\frac{f_n}{n}\right)^2 = f_0^2 + f_0^2 B\, n^2$$

Innan pianot är mätt gissas $B$ ur instrumentets storlek. Uppmätta värden korrigerar gissningen, och korrektionen (kvoten mot modellen, i log-skala) interpoleras mellan mätta tangenter.

**Stretch.** Oktavtyp $p{:}q$ ($p = 2q$) gör delton $p$ i den undre tonen och delton $q$ i den övre svävningsfria. Med $B_1$ för den undre och $B_2$ för den övre strängen blir oktaven bredare än 1200 cent med

$$\Delta = 1200 \log_2 \frac{g(B_1, p)}{g(B_2, q)}, \qquad g(B, n) = \sqrt{\frac{1 + B n^2}{1 + B}}$$

Temperaturoktaven A3–A4 läggs först. Därefter byggs oktaverna uppåt och nedåt en i taget.

**Temperatur.** En temperatur anges som avvikelsen från ren kvint för var och en av de tolv kvinterna. Summan är alltid $-\mathrm{PC}$, det pytagoreiska kommat (≈ 23,46 cent).

**Mätning.** En FFT (16 384 punkter) ger topparnas grova läge. Därefter förfinas frekvensen ur fasskillnaden $\Delta\varphi$ mellan två fönster förskjutna $H$ sampel:

$$f = f_c + \frac{f_s}{2\pi H}\,\mathrm{wrap}\left(\Delta\varphi - \frac{2\pi f_c H}{f_s}\right)$$

där $\mathrm{wrap}$ lägger vinkeln i $(-\pi, \pi]$.

<picture>
  <source media="(prefers-color-scheme: dark)" srcset="docs/settings-dark.png">
  <img alt="Inställningar med stämkurvan för ett pianino på 115 cm" src="docs/settings-light.png">
</picture>

## Drift

```sh
docker compose up -d --build
```

Imagen byggs `FROM scratch` (~7 MB): en statisk Go-binär med webbappen inbäddad. Containern kör read-only som uid 1000 utan capabilities, och data ligger i `./data`.

Mikrofonen kräver https. Routen `pianotunah.example.com` går via Traefik med `ip-allowlist` och nås bara från LAN.

| Variabel   | Standard | |
|------------|----------|-|
| `ADDR`     | `:8080`  | lyssningsadress |
| `DATA_DIR` | `/data`  | sparade stämningar (JSON) |

API: `GET /api/tunings`, `GET|PUT|DELETE /api/tunings/{id}`, `GET /healthz`. `PUT` kräver dokumentets `rev` och svarar 409 om någon annan har sparat sedan dess.

## Utveckling

```sh
# Enhetstester (teori och signalbehandling)
docker run --rm -v "$PWD":/app -w /app node:22-alpine npm test

# End-to-end: headless Chrome med syntetisk pianoton som mikrofon.
# Med en katalog som andra argument tas även skärmdumparna i docs/.
docker run --rm --network caddy -v "$PWD":/usr/src/app/pt zenika/alpine-chrome:with-puppeteer \
  node pt/test/e2e.mjs http://pianotunah:8080 [pt/docs]
```

| Fil | |
|-----|-|
| `main.go` | server: statiska filer och `/api/tunings` |
| `web/js/theory.js` | temperaturer, inharmonicitet, stretch, målfrekvenser |
| `web/js/dsp.js` | FFT, tangentigenkänning, deltonsmätning, skattning av $B$ |
| `web/js/draw.js` | canvasritning |
| `web/js/mapping.js` | kartläggningens planer och klar-kriterier |
| `web/js/saver.js` | sparkö med versionskontroll |
| `web/js/mic.js`, `tone.js` | mikrofon och referenstoner |
| `web/js/app.js` | tillstånd, DOM och händelser |
