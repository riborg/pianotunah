# Utveckling

Värden behöver varken Node eller Go. Allt körs i containrar. [English](DEVELOP.md).

## Tester

```sh
# Enhetstester (teori, signalbehandling och motorn)
docker run --rm -v "$PWD":/app -w /app node:26-alpine npm test

# End-to-end: Chrome utan fönster med en syntetisk pianoton som mikrofon,
# mot den körande containern. Med en katalog som andra argument tas
# skärmbilderna i docs/ om.
# Körs som din användare så att skärmbilderna kan skrivas.
docker run --rm --network container:pianotunah -v "$PWD":/home/pptruser/pt \
  --user "$(id -u):$(id -g)" -e PUPPETEER_CACHE_DIR=/home/pptruser/.cache/puppeteer ghcr.io/puppeteer/puppeteer \
  node pt/test/e2e.mjs http://localhost:8080 [pt/docs]

# Kartläggning: ett syntetiskt piano spelar de tangenter appen ber om, även fel
# tangenter och en överhoppad. "full" lägger till en kartläggning av alla
# tangenter (cirka 2 minuter).
docker run --rm --network container:pianotunah -v "$PWD":/home/pptruser/pt ghcr.io/puppeteer/puppeteer \
  node pt/test/survey.mjs http://localhost:8080 [full]

# Arbetsordning: det syntetiska pianot spelar de tangenter ordningen ber om,
# i stäm och ostämda, genom tempereringen och in i diskanten.
docker run --rm --network container:pianotunah -v "$PWD":/home/pptruser/pt ghcr.io/puppeteer/puppeteer \
  node pt/test/order.mjs http://localhost:8080

# Tillbaka till en flik: två enheter på samma stämning; den som blev kvar visar
# hur långt den andra kom, eller konfliktvarningen om den hade osparade ändringar.
docker run --rm --network container:pianotunah -v "$PWD":/home/pptruser/pt ghcr.io/puppeteer/puppeteer \
  node pt/test/sync.mjs http://localhost:8080
```

End-to-end-testerna delar nätverk med appens container, så de fungerar med vilken omvänd proxy som helst. De skapar och tar bort sin egen stämning.

CI i `.github/workflows/ci.yml` kör enhetstesterna, `go vet`, ett testbygge för amd64 och arm64, govulncheck på binären i avbilden och macOS-appens kontroller nedan. `vuln.yml` skannar den publicerade `latest`-avbilden varje måndag. En röd körning betyder att det är dags för en release byggd med den senaste Go-patchen.

## macOS-appen

Den inbyggda Mac-versionen byggs i `mac/` enligt [docs/macos-port.sv.md](docs/macos-port.sv.md). Dess kärna, Swift-paketet `PianoTunahCore`, testas mot fixturer som skrivs från webbens JS, så att de två versionerna räknar likadant.

```sh
# Skapa om fixturerna i mac/Tests/PianoTunahCoreTests/Fixtures/ efter en
# ändring i web/js/. Committa dem med ändringen.
docker run --rm --user "$(id -u):$(id -g)" -v "$PWD":/app -w /app node:26.13.1-alpine node test/fixtures.mjs

# Swift-tester av kärnan
docker run --rm --user "$(id -u):$(id -g)" -e HOME=/tmp -v "$PWD/mac":/pkg -w /pkg swift:6.4 swift test
```

CI skapar om fixturerna i samma image och misslyckas om de skiljer sig från de committade. Använd exakt den imagen: Node tar `Math.pow` från C-biblioteket, och Alpines (musl) och glibc:s skiljer sig i sista biten för vissa värden. För att byta Node: ändra imagen här och i `ci.yml`, skapa om, kontrollera att bara de sista siffrorna har flyttat sig och committa.

Pianodokumenten `a` och `b` i fixturernas mapp `piano/` är kopior av två riktiga pianon med id, namn och anteckningar utbytta. `node test/fixtures.mjs --pianos data` tar nya kopior av de två första i `data/`.

## Release

```sh
git tag -a v1.2.0 -m v1.2.0
git push origin v1.2.0
```

GitHub Actions kör CI och publicerar `ghcr.io/riborg/pianotunah` med taggarna `1.2.0`, `1.2`, `1` och `latest`. Arbetsflödet skapar sedan en GitHub Release med commitarna sedan föregående tagg. Förhandsversioner som `v1.2.0-rc.1` får inte `latest`.

Att flytta en befintlig tagg startar releasen igen och skriver över `latest`. Stäng av Release-arbetsflödet först.

## Översättningar

Gränssnittets texter finns i `web/js/lang/en.js` och `sv.js`. Statisk markup använder `data-i18n`-attribut, och koden använder `tr('key', { param })`. En ny text läggs i båda filerna. Nycklar som saknas faller tillbaka på engelska.

Dokumentationen finns på båda språken: varje `namn.md` i repots rot och i `docs/` har en svensk `namn.sv.md`, och de två länkar till varandra. Undantagen är `CLAUDE.md`, `CONTEXT.md` och `docs/agents/`, som är skrivna för agenter. Ändrar du det ena dokumentet ändrar du det andra i samma commit.

## API

Servern svarar på `GET /api/tunings`, `GET|PUT|DELETE /api/tunings/{id}`, `GET /api/version` och `GET /healthz`. `PUT` kräver dokumentets `rev` och svarar 409 om någon annan har sparat sedan dess. Servern vägrar skrivningar från ett annat ursprung med 403.

## Kod

| Fil | |
|-----|-|
| `main.go` | server: statiska filer och `/api/tunings` |
| `web/js/theory.js` | temperaturer, inharmonicitet, stretch, överdrag, målfrekvenser |
| `web/js/dsp.js` | FFT, tangentigenkänning, mätning av deltoner, skattning av B |
| `web/js/draw.js` | ritning på canvas |
| `web/js/survey.js` | kartläggningsplaner och när en kartläggning är klar |
| `web/js/order.js` | arbetsordning: steg, uppgifter, kontroller och när en uppgift är klar |
| `web/js/engine.js` | stämapparaten utan DOM: varje ljudram till avläsningar, sparade mätningar, svävningar, kartläggningens och arbetsordningens framsteg |
| `web/js/saver.js` | sparkö med revisionskontroll |
| `web/js/mic.js`, `recorder.js`, `tone.js` | mikrofon, inspelning (AudioWorklet) och referenstoner |
| `web/js/i18n.js`, `lang/` | gränssnittets texter |
| `web/js/app.js` | DOM och händelser; visar vad motorn gör |
| `web/js/diag.js` | felsökningslogg till servern (`DEBUG=1`) |
| `web/fonts/` | ♭ ♮ ♯ från Bravura Text, byggda av `tools/accidentals.py` |
| `web/favicon.svg`, `web/icons/` | logotyp och appikoner, byggda av `tools/icons.py` |
| `test/` | enhets- och end-to-end-tester |
| `test/fixtures.mjs` | fixturer för Swift-testerna, skrivna från webbens JS |
| `mac/` | macOS-appen: Swift-paketet `PianoTunahCore` och dess tester |
| `.github/workflows/` | CI, release, veckovis sårbarhetsskanning |
