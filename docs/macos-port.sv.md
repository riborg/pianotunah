# Porta Piano Tunah till en native macOS-app

En plan för en native Mac-version av Piano Tunah vid sidan av webbversionen. [English](macos-port.md).

Status: beslutad, byggs på grenen `macos-port`. Appen är för en Mac, installeras från GitHub Releases och uppdaterar sig själv, utan synk. Se [Beslut](#beslut).

## Språk: Swift, inte Rust

Appen skrivs i Swift 6 med SwiftUI, AVAudioEngine och Foundation, för macOS 27 ([ADR 0001](adr/0001-native-mac-app-in-swift.sv.md)).

- **Gränssnittet blir SwiftUI eller AppKit i vilket fall som helst.** Med Rust ritar antingen Swift gränssnittet ändå och Rust blir ett bibliotek bakom UniFFI, eller så blir gränssnittet något som egui eller Tauri, som inte ser ut eller känns som en Mac-app.
- **Kärnan är liten.** theory, dsp, survey, order och format är sammanlagt ungefär 1 200 rader JS. En Rust-kärna skulle lägga till en andra verktygskedja, en C- eller UniFFI-brygga och ett xcframework-bygge i projektet. Det kostar mer än att skriva 1 200 rader Swift.
- **Ljudet är Apples.** Mikrofonbehörighet, val av enhet, röstbehandling, viloläge och enhetsbyten går alla genom AVFoundation och Core Audio. Rusts `cpal` täcker mindre av detta, och Swift-limmet skulle behövas ändå.
- **Rust lönar sig bara om en kärna ska tjäna både webben (som WASM) och Macen.** Ingen har bett om det, och webbversionen fungerar i JS. Om behovet uppstår är Swift-kärnan och dess fixturer (nedan) en exakt specifikation att porta från.

Appen riktar sig till aktuell macOS (27) och stöder inga äldre versioner, så den använder de nyaste API:erna i SwiftUI och Observation direkt, utan versionskontroller. Det kräver den Xcode vars SDK är macOS 27. Fas 3 börjar med att kontrollera att den installerade Xcode har den. Om inte följer deployment target den SDK som den installerade Xcode har. Swift 6-läge med strikt kontroll av samtidighet.

## Struktur

```
mac/
├── Package.swift                 PianoTunahCore: ren Swift, inga Apple-specifika ramverk
├── Sources/PianoTunahCore/
│   ├── Theory.swift              ← web/js/theory.js
│   ├── DSP.swift                 ← web/js/dsp.js (egen FFT, se nedan)
│   ├── Survey.swift              ← web/js/survey.js
│   ├── Order.swift               ← web/js/order.js
│   ├── Format.swift              ← web/js/format.js (decimaltecknet skickas in)
│   ├── Engine.swift              ← web/js/engine.js (logik som lyfts ur app.js, steg 0)
│   └── Piano.swift               det sparade dokumentet, Codable, samma JSON som webben
├── Tests/PianoTunahCoreTests/    paritetstester mot fixturerna
│   └── Fixtures/                 genereras från JS av test/fixtures.mjs
└── PianoTunah.xcodeproj          appen: SwiftUI, ljud, filer, menyer
    └── PianoTunah/
        ├── Audio/                MicInput, ToneEngine, Recorder, enheter
        ├── Models/               PianoLibrary, TunerModel, SurveyModel, OrderModel
        ├── Views/                ratt, klaviatur, kurva, paneler, formulär
        └── Localizable.xcstrings engelska och svenska
```

Kärnpaketet använder inga Apple-specifika ramverk ([ADR 0003](adr/0003-mac-core-is-pure-swift.sv.md)). Det byggs och testas på Linux i containern `swift:6`, så samma CI och samma agenter som arbetar här kan köra dess tester. Bara app-målet behöver Xcode. Foundation på Linux skiljer sig på sina ställen från Apples, till exempel i hantering av locale och formatering av tal, så kärnans tester körs också i Xcode på Macen. Särskilt Format-testerna måste gå igenom där.

## Steg 0: lyft ut logiken ur app.js (i JS, först)

Ungefär 900 av app.js 2 177 rader är domänlogik som är blandad med DOM:en:

- avvikelser och status (`devOf`, `curDev`, `statusDev`);
- analys av varje ram (`analyseFrame`, anslag, brusgrind);
- att följa tangenten (`followDetectedKey`, `jumpConfirmed`);
- mätning (`measureCurrent`, `recordKey`, `storeB`);
- svävningar (`trackBeating`, `beatUnheard`);
- hur kartläggningen och arbetsordningen går framåt (`collectSurvey`, `advanceSurvey`, `trackOrder`, `recheckKeys`);
- sammanfattningen av omgången, `fitRefToPiano` och reglerna för gränsvärden.

Flytta detta till en DOM-fri `web/js/engine.js` med enhetstester, och låt app.js vara kvar som DOM-lagret. Webbappen får bättre tester av det, och Swift-porten blir en översättning modul för modul utan gissningar om vad app.js gör. Det är den mest riskabla omstruktureringen i planen, så den kontrolleras med de befintliga end-to-end-testerna (`e2e`, `survey`, `order`, `sync`) innan något annat påbörjas.

## Steg 1: fixturer som bevisar paritet

`test/fixtures.mjs` kör JS-modulerna och skriver JSON-filer med indata och förväntade utdata till `mac/Tests/PianoTunahCoreTests/Fixtures/`. Swift-testerna läser samma filer.

- **Exakt eller inom 1e-12:**
  - `computeTargets` över förval, storlekar, tempereringar, grundtoner och uppmätt B, inklusive avvikare;
  - `temperamentOffsets`, 7 × 12;
  - `migrateSettings` och `bOutliers`;
  - `buildOrder` för de fyra inställningarna av topp och DSU, plus `checkRows` och `tunedBefore`;
  - kartläggningens tillståndsmaskin, och sekvenser för `steady` och `confirmReading`;
  - `fmtC` och `parseNum` på båda språken.
- **Motorn, beslut exakt och tal inom 1e-9:** scenarier för engine.js, en följd av avläsningar in och tillstånd ut. Vilken tangent, vilket steg och om en tangent är klar ska stämma exakt. Apples libm och V8 kan skilja sig med en ulp i `log2` och `pow`, och de skillnaderna läggs ihop över en följd, så talen får en större tolerans än ovan.
- **Pianodokumentet, fram och tillbaka:** kopior av de två pianona i `data/`, varav ett sparades innan `settings.unisons` fanns, med id, namn och anteckningar utbytta (`data/` står i `.gitignore` och innehåller riktiga pianon). Att avkoda och koda igen ska ge samma JSON-värde, bortsett från nyckelordningen. Avkodningen ska ge samma inställningar som `normalize` och `migrateSettings`.
- **DSP, inom 0,01 cent:** spara ljudet som binär Float32 i stället för att generera om det i Swift. JS `Math.sin` och den seedade generatorn går inte att återskapa exakt i Swift. Täck `measure`, `inharmonicity`, `detectKey` för ett urval tangenter, listan med toppar för B♭0 och utslagen från BeatMeter. Lägg till några sekunder klippta ur en eller två riktiga inspelningar, med de avläsningar webbversionen ger för dem. `*.wav` står i `.gitignore`, så utdragen committas som `.f32`-filer.

Fixturerna genereras med Node 26, samma huvudversion som enhetstesterna och CI. De genereras om när JS ändras. CI genererar om dem och fallerar om de skiljer sig från det som är committat, så de två versionerna kan inte glida isär utan att någon märker det. Nodes underversion är inte låst, så en ny V8 kan flytta ett `Math.*`-resultat en ulp. Fallerar CI utan att JS har ändrats: generera om fixturerna, kontrollera att bara de sista siffrorna flyttade sig och committa dem.

## Steg 2: kärnan i Swift

Sju filer i tre vågor, efter importerna i JS-koden. Inom en våg kan varje fil skrivas av en egen agent mot sina fixturer.

1. **Theory, Survey, Format.** De beror inte på något annat.
2. **DSP, Order.** Båda använder Theory.
3. **Piano, Engine.** Piano behöver Theory för migreringen. Engine använder alla de andra.

**Se upp med detta** (från genomläsningen av dsp.js):

- **FFT:** behåll den egna radix-2-FFT:n i Float64 i stället för vDSP. Då går kärnan fortfarande att bygga på Linux, och 16 384 punkter elva gånger i sekunden är ingenting för en Mac. vDSP kan komma senare bakom ett protokoll om profilering visar att det behövs.
- **Hann-fönster:** symmetriskt, med nämnaren n − 1.
- **DFT:er och svävningssökningen:** `dftPhase` och `dftDb` roterar en visare rekursivt. Svävningssökningen stegar `rate += 0.05`. Kopiera båda looparna som de är; en snyggare formel ger något andra tal.
- **Avrundning:** JS `Math.round` avrundar halvor uppåt. Swift `.rounded()` avrundar dem bort från noll. Använd en hjälpfunktion, `jsRound`, som avrundar som `Math.round`. Ett enkelt `floor(x + 0.5)` ger fel för 0.49999999999999994, så hjälpfunktionen får en egen fixtur.
- **Division och omvandlingar:**
  - division med noll ska ge ±∞ eller NaN, aldrig krascha;
  - `NaN ≥ 10` är falskt;
  - `Number(x) || default` kräver att 0 och NaN hanteras uttryckligen.
- **Text:** minustecknet är U+2212. `toExponential(2)` ger `1.23e-4`, utan inledande nolla i exponenten.

## Steg 3: ljud

**Indata**
- En `AVAudioSinkNode` eller `installTap` med liten buffert (512–1024) på ingången skriver kanal 0 till en låsfri ringbuffert på 32 768 sampel.
- Analysen körs på en egen kö var 90:e ms räknat i sampel (4 320 vid 48 kHz), alltså efter ljudklockan och inte efter en timer. Ramens tid tas från `AVAudioTime.sampleTime`.
- Använd hårdvarans samplingsfrekvens. Vid 96 kHz täcker de fasta fönstren halva tiden, och i Bluetooth-headset är bandbredden för låg. Sampla om till 48 kHz i de fallen, eller varna användaren.

**Behörighet och inställningar**
- Mikrofonbehörighet kräver `NSMicrophoneUsageDescription` och `AVCaptureDevice.requestAccess`. Entitlementet `com.apple.security.device.audio-input` behövs bara med App Sandbox eller hardened runtime, och appen använder ingetdera (steg 6).
- Utan behörighet levererar motorn tystnad, inte ett fel. Kontrollera `authorizationStatus` och länka till Systeminställningar › Integritet › Mikrofon.
- Röstbehandling är avstängd från början och ska förbli det. Det ersätter webbversionens `echoCancellation: false`.

**Enheter och livscykel**
- Välj enhet via dess UID genom Core Audio (`kAudioOutputUnitProperty_CurrentDevice`).
- Starta om vid `AVAudioEngineConfigurationChange` och efter viloläge.
- `ProcessInfo.beginActivity(.idleDisplaySleepDisabled)` ersätter wake lock och stoppar App Nap.

**Ton och inspelning**
- Referenstonen använder en egen motor med en `AVAudioSourceNode`: knäpp eller sinus med webbens deltoner och envelopper.
- Behåll grinden som ignorerar avläsningar medan en ton spelas och 800 ms efteråt.
- Inspelningen går från samma tap till en WAV i Float32, högst 120 s, som sparas med `fileExporter`.

Ljudcallbacken och renderblocket får inte allokera minne eller ta lås. Gränssnittet får en oföränderlig ögonblicksbild ungefär elva gånger i sekunden.

## Steg 4: appen

- **Fönster:** ett huvudfönster med en `NavigationSplitView`.
  - **Sidofält:** pianona.
  - **Huvudyta:** ratten, panelerna för kartläggning och arbetsordning, och klaviaturen med kurvan.
  - **Utfällbara delar:** svävningar och deltoner.
  - **Inspektör:** pianots inställningar. Flikarna Piano, Stämning och Omgång blir sektioner i den.
- **Inställningar (⌘,):** det som fliken App har i dag: mikrofon, inspelning och färgläge.
- **Menyer:**
  - Stämapparat: mikrofon, Auto/Lås, föregående/nästa tangent, ton, kartläggning, arbetsordning, mät B.
  - Piano: nytt, duplicera, importera, exportera, radera, ny omgång.
  - Behåll dagens kortkommandon med en bokstav i stämvyn (← → L A O T S H Esc).
- **Ritning:** ratten och svävningsremsan är `Canvas` i en `TimelineView(.animation)`. Geometrin i draw.js är proportionell mot bredden och går att föra över nästan rad för rad.
  - Spektrogrammet är en `CGImage` på 100 × 48 som uppdateras varje ram.
  - Kurvan delar tangentpositioner med klaviaturvyn. Använd `Canvas` i stället för Swift Charts, så att kurvan ligger kvar i linje med tangenterna.
  - Animationsfaserna ligger utanför det observerade tillståndet, så att 60–120 bilder per sekund inte ritar om vyerna.
- **Texter:** en String Catalog med de 366 nycklarna på engelska och svenska.
  - `{name}` blir `%@`.
  - Antal får riktiga pluralformer.
  - Appen följer språket som macOS ger den (Systeminställningar › Allmänt › Språk och region, per app). Webbens språkväljare följer inte med.
  - Meningar som byggs av bitar i dag blir hela meningar.
  - Hjälpen blir Markdown i appen.
  - Typsnittet för ♭ ♮ ♯ följer med som OTF under sin OFL-licens.
- **Färger:** de ungefär 23 CSS-variablerna blir färgresurser med ljus och mörk variant. Auto/Ljust/Mörkt sätter `NSApp.appearance`.

Uppskattning: kärnan 1 100–1 300 rader plus 600 rader tester, appen 4 000–5 000 rader.

## Steg 5: lagring

Varje piano är en JSON-fil i `~/Library/Application Support/Piano Tunah/`, i exakt webbens format, så att export och import fungerar åt båda hållen mellan versionerna ([ADR 0002](adr/0002-mac-app-stores-web-json-locally.sv.md)). Appen körs inte i sandlåda (steg 6), så mappen ligger där sökvägen säger, och Time Machine säkerhetskopierar den.

- Avkoda tillåtande: alla fält är valfria, standardvärden fylls i, och samma migrering som `normalize` och `migrateSettings` körs.
- Behåll okända fält när filen skrivs, så att den kan gå fram och tillbaka.
- `at` förblir ett antal millisekunder.
- Spara automatiskt 2,5 s efter en ändring och när appen avslutas.

Det finns ingen synk. Appen pratar inte med Go-servern; den enda nätverkstrafiken är uppdateringskontrollen i steg 6. Pianon flyttas mellan webben och Macen med export och import. Eftersom formatet och `rev` behålls går synk ändå att lägga till senare utan att ändra servern.

## Steg 6: releaser och automatiska uppdateringar

Appen uppdaterar sig själv från GitHub Releases med [Sparkle](https://sparkle-project.org) 2 ([ADR 0004](adr/0004-mac-app-updates-itself-from-github.sv.md)).

- **Flödet** är `https://github.com/riborg/pianotunah/releases/latest/download/appcast.xml`, en fil på den senaste releasen. GitHub hoppar över förhandsreleaser och utkast för `latest`, så en `v1.2.0-rc.1` når aldrig appen, samma regel som för imagens tagg `latest`.
- **Kontroller:** Sparkle kontrollerar en gång om dagen och vid start, laddar ner en ny version i bakgrunden och installerar den när appen avslutas (`SUEnableAutomaticChecks`, `SUAutomaticallyUpdate`). *Sök efter uppdateringar…* i appmenyn kontrollerar direkt.
- **Uppdateringens signatur:** varje release-zip signeras med en EdDSA-nyckel. Den publika nyckeln ligger i Info.plist (`SUPublicEDKey`), den privata är en hemlighet i Actions. Sparkle vägrar en uppdatering som inte stämmer.
- **Kodsignering:** inget Apple Developer-konto, alltså inget Developer ID och ingen notarisering. CI signerar med ett självsignerat kodsigneringscertifikat, som skapas en gång och sparas som hemlighet i Actions. Samma certifikat i varje release håller appens identitet stabil, så att macOS behåller mikrofonbehörigheten mellan uppdateringar. Ad hoc-signering skulle ge varje bygge en ny identitet och fråga om mikrofonen igen efter varje uppdatering.
- **Första installationen:** ladda ner zip-filen från releasen, flytta appen till Program och öppna den. macOS stoppar en app som inte är notariserad första gången; tillåt den en gång under Systeminställningar › Integritet och säkerhet › *Öppna ändå*. Uppdateringar installeras av Sparkle och ska inte fråga igen; kontrollera det vid den första riktiga uppdateringen.
- **Ingen App Sandbox, ingen hardened runtime.** Sparkle i en app i sandlåda kräver extra installationstjänster och entitlements, vilket inte är värt det för en Mac. Hardened runtime behövs bara för notarisering. Lägg `NSMicrophoneUsageDescription` i Info.plist; utan den stoppas appen första gången den öppnar mikrofonen.
- **Versionsnummer:** `CFBundleShortVersionString` är taggen utan `v` (1.2.0). `CFBundleVersion`, som Sparkle jämför, är antalet commits fram till taggen, så den växer alltid.

**Release-jobbet.** Release-arbetsflödet körs på `v*`-taggar. I dag bygger ett jobb imagen och skapar GitHub-releasen. Det ändras så här:

1. **`release`** (som i dag) publicerar imagen, men skapar GitHub-releasen som ett **utkast**, och bara om taggen inte har någon release än (`gh release view` först), så att en omkörning av ett fallerat arbetsflöde fortsätter med samma utkast. Använd `gh`, inte REST-anropet `releases/tags/{tag}`: det anropet returnerar inte utkast, medan `gh release view` och `gh release upload` även letar efter taggen bland utkast (via GraphQL, så de behöver `GH_TOKEN`, som steget som skapar releasen redan sätter). Bara svaret *release not found* betyder att releasen saknas; alla andra fel får jobbet att fallera i stället för att skapa ett andra utkast. Imagen väntar inte på Macen. Uppladdningar görs med `gh release upload --clobber`.
2. **`mac`**, ett nytt jobb på en macOS-runner, körs bredvid efter `ci`, med `fetch-depth: 0` eftersom versionsnumret räknar commits:
   1. bygger appen med `xcodebuild` i Release, med versionsnummer från taggen;
   2. signerar den med certifikatet från hemligheterna, importerat i en tillfällig nyckelring. Certifikatet är självsignerat och inte betrott där, så `codesign` väljer det med dess SHA-1-hash. `security find-identity -p codesigning <nyckelring>` utan `-v` visar det med hashen; `-v` döljer identiteter som inte är betrodda. Sparkles inbäddade hjälpprogram (Autoupdate, Updater.app och XPC-tjänsterna) signeras med samma identitet, inifrån och ut, före själva appen;
   3. zippar den med `ditto -c -k --keepParent` och signerar zip-filen med Sparkles `sign_update`;
   4. skriver `appcast.xml` med en `<item>` för den här versionen:
      - `sparkle:version` = `CFBundleVersion`;
      - `sparkle:shortVersionString` = taggen utan `v`;
      - `sparkle:minimumSystemVersion` = 27.0;
      - en `sparkle:releaseNotesLink` till GitHub-releasen;
      - en `<enclosure>` vars `url` är taggens egen fil, `releases/download/vX.Y.Z/PianoTunah.zip`, aldrig `latest`-adressen, med `sparkle:edSignature` och `length` från `sign_update`;
   5. sparar zip-filen och appcasten som artefakter i arbetsflödet.
3. **`publish`** behöver båda. Det laddar upp de två filerna till utkastet och publicerar det (`gh release edit --draft=false`, plus `--prerelease` för taggar med `-`).

Om Mac-jobbet fallerar förblir releasen ett utkast och körningen blir röd. `releases/latest` pekar då kvar på den förra releasen, som har sin appcast, så installerade appar får ingen 404 utan stannar på den version de har. Imagen publiceras i vilket fall som helst. Rätta bygget, eller bygg på din Mac, ladda upp de två filerna till utkastet för hand och publicera det.

Förhandstaggar (`-rc.1`) bygger också Mac-appen, så att en förhandsrelease kan provas genom att laddas ner. Dess appcast läses aldrig, eftersom `latest` hoppar över förhandsreleaser.

**Runner.** Jobbet använder GitHubs nyaste macOS-image och väljer dess nyaste Xcode. Om den Xcode inte har macOS 27-SDK:n än fallerar jobbet och regeln ovan gäller. Händer det mer än en gång: registrera din Mac som self-hosted runner för det här jobbet.

**Engångssteg på din Mac.**
- Sparkles `generate_keys` skapar EdDSA-nyckelparet.
- Skapa kodsigneringscertifikatet med `openssl`, giltigt i 10 år, och exportera det som .p12. Ett självsignerat certifikat från Nyckelhanteraren gäller ett år som standard. Ett nytt certifikat är en ny identitet, och macOS skulle fråga om mikrofonen igen. Sparkle kontrollerar själv uppdateringen med dess EdDSA-signatur, så ett nytt certifikat skulle inte stoppa uppdateringen; mikrofonbehörigheten är skälet att behålla det.
- Hemligheter: `SPARKLE_ED_PRIVATE_KEY`, `MAC_SIGNING_P12` och `MAC_SIGNING_PASSWORD`.

## Ordning och agenter

| Fas | Arbete | Parallellt |
|---|---|---|
| 0 | engine.js ur app.js, enhetstester, end-to-end-testerna gröna | 1 agent; den rör hela app.js |
| 1 | test/fixtures.mjs, skelettet till Swift-paketet, CI-jobbet i `swift:6` | 1 agent |
| 2 | Theory, Survey, Order, Format, DSP, Engine, Piano i Swift | tre vågor med 3, 2 och 2 agenter, en fil var, mot fixturerna |
| 3 | Ljud: ingång, ton, inspelning, enheter | 1 agent; måste köras på en Mac |
| 4 | Vyer och modeller | 3 agenter: ratt och utfällbara delar, klaviatur och kurva, paneler och inspektör |
| 5 | Lagring, import/export, menyer, Inställningar, texter | 1–2 agenter |
| 6 | Release-jobb, Sparkle, appcast | 1 agent; du skapar nycklarna och certifikatet en gång |

Fas 0–2 kan köras helt här på Linux. Från fas 3 byggs och provas appen i Xcode på din Mac. Kärnans tester körs fortfarande i CI.

## Beslut

1. **Distribution:** för eget bruk, installeras från GitHub Releases. Appen bevakar GitHub och uppdaterar sig själv när en ny version släpps ([ADR 0004](adr/0004-mac-app-updates-itself-from-github.sv.md)).
2. **Flera enheter:** behövs inte. Mac-appen används för sig, så det finns ingen synk ([ADR 0002](adr/0002-mac-app-stores-web-json-locally.sv.md)).
3. **Gränssnittets språk:** följ macOS.
4. **Lägsta version:** macOS 27, den aktuella.
