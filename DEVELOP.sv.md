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

### Appen i Xcode

Appen behöver en Mac med Xcode 26 eller senare. Dess Xcode-projekt genereras från `mac/project.yml` av [XcodeGen](https://github.com/yonaskolb/XcodeGen) och committas inte, så generera det på nytt efter en pull som lägger till eller tar bort filer:

```sh
brew install xcodegen
cd mac && xcodegen generate && open PianoTunah.xcodeproj
```

Kör schemat `PianoTunah` med ⌘R. Debug-byggen signeras för att köras lokalt, utan utvecklarkonto. Pianona sparas i `~/Library/Application Support/Piano Tunah/`. CI bygger appen på samma sätt vid varje push, osignerad.

Appens egna tester ligger i `mac/PianoTunahTests/` (målet `PianoTunahTests`, körs med ⌘U). De körs inuti appen, som startar som vanligt men utan mikrofonen, och testar dess modeller, till exempel vad avslut gör med en osparad inspelning. Dialoger som avslutsfrågan ligger bakom en söm som testerna svarar i (`RecordingModel.quitPrompts`). CI kör dem vid varje push. Kärnans tester ligger kvar i Swift-paketet (`swift test`).

Bara release-jobbet ger appen Sparkles publika nyckel (bygginställningen `SPARKLE_PUBLIC_KEY`, som skrivs till `SUPublicEDKey`). Utan den startar appen aldrig uppdateraren och har inget *Sök efter uppdateringar…*, så ett bygge från Xcode byter aldrig ut sig självt mot en release. CI kontrollerar att ett Debug-bygge saknar nyckel.

## Release

```sh
git tag -a v1.2.0 -m v1.2.0
git push origin v1.2.0
```

GitHub Actions kör CI och publicerar `ghcr.io/riborg/pianotunah` med taggarna `1.2.0`, `1.2`, `1` och `latest`. Förhandsversioner som `v1.2.0-rc.1` får inte `latest`. Arbetsflödet skapar ett utkast till GitHub Release med commitarna sedan föregående tagg, bygger Mac-appen bredvid avbilden och publicerar releasen när appen och dess appcast ligger i den.

Att flytta en befintlig tagg startar releasen igen och skriver över `latest`. Stäng av Release-arbetsflödet först.

### Mac-appen

Mac-appen uppdaterar sig själv från GitHub Releases med Sparkle ([docs/macos-port.sv.md](docs/macos-port.sv.md), steg 6). En release går till så här:

1. `ci` körs, med `release-dry-run` nedan.
2. `release` publicerar avbilden och skapar GitHub-releasen som ett **utkast**, eller fortsätter med det som en fallerad körning lämnade.
3. `mac` kör samtidigt `mac/scripts/release.sh` på en macOS-runner. Det:
   1. bygger appen i Release, version `1.2.0` från taggen och byggnumret från `build-number.sh` (`C.99` för en release, `C.N` för en förhandsrelease, C = antalet commits fram till taggen);
   2. signerar Sparkles hjälpprogram och sedan appen med ditt certifikat, från en tillfällig nyckelring;
   3. zippar appen, signerar zip-filen med Sparkles `sign_update` och skriver `appcast.xml`;
   4. kontrollerar alltihop med `check-release.sh`.
4. `publish` laddar upp `PianoTunah.zip` och `appcast.xml` till utkastet och publicerar det. De installerade apparna ser den nya appcasten på `releases/latest/download/appcast.xml` inom ett dygn, laddar ner uppdateringen och installerar den när de avslutas. Sedan blir `appcast.xml` också betaflödet (`beta.xml` på grenen `appcast`) om dess bygge är det nyaste, så att appar med *Hämta betaversioner* påslaget också får förhandsreleaser som `v1.2.0-beta.1`.

Om `mac` fallerar förblir releasen ett utkast och apparna stannar på den version de har. Rätta felet och kör om de fallerade jobben; körningen fortsätter med samma utkast. Eller kör `mac/scripts/release.sh` på din Mac med variablerna som står överst i skriptet, ladda upp `mac/build/dist/*` till utkastet med `gh release upload --clobber` och publicera det med `gh release edit v1.2.0 --draft=false`.

`mac/scripts/dry-run.sh` kör hela Mac-delen för en låtsad `v0.0.1` med ett engångscertifikat och en engångsnyckel, i en tillfällig nyckelring. CI kör det vid varje push (`release-dry-run`); det går också att köra på din Mac.

**Engångssteg på din Mac.** Gör det före nästa `v*`-tagg: tills de tre hemligheterna finns fallerar Mac-jobbet på varje tagg och GitHub-releasen förblir ett utkast (imagen publiceras ändå). Tre hemligheter, som skapas en gång och sparas. Guiden `mac/scripts/setup-release-secrets.sh` leder dig igenom det: den kör kommandona nedan, kontrollerar EdDSA-nyckeln och certifikatets lösenord och listar hemligheterna på GitHub till sist. För hand:

```sh
cd mac && xcodegen generate
xcodebuild -resolvePackageDependencies -project PianoTunah.xcodeproj -clonedSourcePackagesDirPath build/SourcePackages
sparkle=build/SourcePackages/artifacts/sparkle/Sparkle/bin

# 1. EdDSA-nyckeln som uppdateringarna signeras med. generate_keys sparar den
#    i din inloggningsnyckelring (din säkerhetskopia) och skriver ut den
#    publika nyckeln; release-jobbet räknar fram den publika nyckeln ur den
#    privata, så ingenting committas.
"$sparkle/generate_keys"
"$sparkle/generate_keys" -x sparkle-private-key.txt
gh secret set SPARKLE_ED_PRIVATE_KEY < sparkle-private-key.txt
rm sparkle-private-key.txt

# 2. Kodsigneringscertifikatet: självsignerat med openssl, giltigt i 10 år,
#    exporterat med sin nyckel som .p12. Spara .p12-filen och lösenordet
#    (till exempel i din lösenordshanterare).
export MAC_SIGNING_PASSWORD=$(openssl rand -base64 24)
scripts/make-signing-cert.sh ~/PianoTunah-signing.p12
base64 < ~/PianoTunah-signing.p12 | tr -d '\n' | gh secret set MAC_SIGNING_P12
printf %s "$MAC_SIGNING_PASSWORD" | gh secret set MAC_SIGNING_PASSWORD
```

Skapa ett nytt certifikat bara när det här går ut: ett nytt certifikat är en ny identitet, och macOS frågar om mikrofonen igen. En ny EdDSA-nyckel skulle få de installerade apparna att inte ta emot uppdateringar alls, eftersom de kontrollerar mot nyckeln de byggdes med.

**Första installationen.** Ladda ner `PianoTunah.zip` från releasen, flytta appen till Program och öppna den. macOS stoppar den första gången, eftersom den inte är notariserad; tillåt den en gång under Systeminställningar › Integritet och säkerhet › *Öppna ändå*. Senare versioner kommer av sig själva.

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
| `mac/project.yml` | appens Xcode-projekt, för XcodeGen: target, bygginställningar, Info.plist |
| `mac/PianoTunah/` | appen: SwiftUI-vyer, pianobiblioteket, menyer, uppdateringar, texter på engelska och svenska |
| `mac/PianoTunah/Assets.xcassets/` | Mac-appens ikon, byggd av `tools/icons.py` |
| `mac/PianoTunah/Fonts/` | samma typsnitt med ♭ ♮ ♯ som `web/fonts/`, med licensen, byggt av `tools/accidentals.py` |
| `mac/scripts/` | Mac-releasen: bygge, signering, zip, appcast, kontroller och provkörningen |
| `.github/workflows/` | CI, release, veckovis sårbarhetsskanning |
