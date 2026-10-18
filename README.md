# Piano Tunah

Webbapp för att stämma ett 88-tangenters piano med laptopens mikrofon. Den mäter strängarnas inharmonicitet, räknar fram en stretchad målkurva och sparar stämningar på servern så att du kan återkomma och stämma igen.

## Funktioner

- **Mätning:** tangenten hittas automatiskt eller låses manuellt. I basen mäts en högre delton (6, 4 eller 2), eftersom grundtonen där är svag och en laptopmikrofon hör dåligt under ~100 Hz. Frekvensen räknas fram med FFT plus fasskillnad mellan två fönster, vilket ger hundradels cent.
- **Kartläggning** (idé från Entropy Piano Tuner): du går igenom pianot tangent för tangent. Appen mäter B (inharmonicitet) och nuvarande tonhöjd och hoppar sedan vidare. Målkurvan räknas därefter från pianots egna värden.
- **Stretch:** oktavtyper 2:1, 4:2, 6:3 och 8:4 (separat för bas, mitt och diskant) samt förval och en fast Railsback-kurva. Extra stretch kan läggas på i diskant och bas.
- **Temperaturer:** liksvävande, Werckmeister III, Kirnberger III, Vallotti, Young II och medelton 1/4 och 1/6 komma. Grundtonen går att flytta.
- **Referens A4:** justerbar i steg om 0,1 Hz med förval (415–444 Hz). Appen kan också anpassa referensen till ett gammalt nedstämt pianos nuvarande tonhöjd.
- **Överdrag** för uppdragning av pianon som ligger långt under målet.
- **Visning:** klaviatur som markerar aktuell tangent och status, stroboskop, ett svävningsspektrogram med färgskalan grönt → gult → orange → rött, en svävningsremsa, deltonsavvikelser, stämkurva och tabell.
- **Lagring:** stämningar sparas som JSON i `data/` och kan exporteras och importeras. Varje stämnings omgångar loggas i en historik.

## Teori i korthet

Delton *n* i en styv sträng: f_n = n·f₀·√(1 + B·n²). En oktav p:q tar den övre tonens grundton från den undre tonens delton p (q = p/2). Temperaturoktaven A3–A4 stäms först, och sedan byggs oktaverna uppåt och nedåt. Se `web/js/theory.js`.

## Drift

```sh
docker compose up -d --build
```

Imagen är byggd `FROM scratch` (~7 MB) med en statisk Go-binär där webbfilerna är inbäddade. Containern kör read-only som uid 1000 med alla capabilities borttagna. Data ligger i `./data`.

Routen `pianotunah.example.com` går via Traefik med `ip-allowlist`, alltså bara från LAN. Mikrofonen kräver https, vilket Traefik står för.

| Variabel   | Standard | |
|------------|----------|-|
| `ADDR`     | `:8080`  | lyssningsadress |
| `DATA_DIR` | `/data`  | katalog för sparade stämningar |

API: `GET /api/tunings`, `GET|PUT|DELETE /api/tunings/{id}`, `GET /healthz`.
