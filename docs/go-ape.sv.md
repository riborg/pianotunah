# Go A.P.E.-systemet (Mark Cerisano)

En beskrivning av Mark Cerisanos metod för stämning efter gehör, skriven innan Piano Tunah implementerar något av den. [English](go-ape.md).

Underlaget togs fram 2026-11-18 och bygger bara på öppna källor. Cerisanos böcker och skolans lektioner för medlemmar kostar pengar. Dokumentet beskriver därför metoden så som han har publicerat den i tidskriftsartiklar, på sina webbplatser och på skolans öppna sidor om varje moment. Där texten säger **Slutsats** är det vår tolkning, inte hans.

## Källor

Hänvisningarna inom hakparentes pekar på tabellen. Alla källor är Cerisanos egna utom [POD] och [PW].

| Ref | Källa |
|---|---|
| [PTJ15] | "Tuning Accurate Equal Temperament and Ideal F3-F4 and A3-A4 Octave Sizes Using Rapid-Beating Intervals", *Piano Technicians Journal* (PTJ) 58:6, juni 2015. [PDF](https://howtotunepianos.com/wp-content/uploads/2020/02/PTJ-Beat-Speed-Windows-Equal-Temperament-For-Public.pdf) |
| [PTJ15b] | "An Advanced Method to Analyze Non-Speaking Length Tension and Develop Improved Stability Techniques", PTJ, juli 2015. [PDF](https://howtotunepianos.com/wp-content/uploads/2020/02/PTJ-Stability-for-public.pdf) |
| [PTJ16] | "Unison Drift", PTJ 59:3, mars 2016. [PDF](https://howtotunepianos.com/wp-content/uploads/2020/02/PTJ-Unison-Drift-For-Public.pdf) |
| [PTJ17] | "Aural Stretch Using Beat Speed Windows", PTJ 60:11, november 2017. [PDF](https://howtotunepianos.com/wp-content/uploads/2020/02/PTJ-Stretch-for-public.pdf) |
| [SEPTG] | Seminarium för Southeastern PTG, 29 oktober 2020, med stegen som videokapitel. [Sida](https://howtotunepianos.com/septg/) |
| [INTRO] | "Introduction to the Go A.P.E. Aural Piano Tuning System", 2021. [Sida](https://howtotunepianos.com/introduction-to-the-go-a-p-e-aural-piano-tuning-system/) |
| [LEARN] | "Learn More About the Go A.P.E. Aural Piano Tuning System", 2020. [Sida](https://howtotunepianos.com/learn-more-about-the-go-a-p-e-aural-piano-tuning-system/) |
| [ACC] | "How Accurate is Your Temperament Sequence?", 2019. [Sida](https://howtotunepianos.com/how-accurate-is-your-temperament-sequence/) |
| [TR022] | Temperament Report 022, 2020. [Sida](https://howtotunepianos.com/temperament-report-022/) |
| [ERR] | "Error in the Go APE Sequence", odaterad. [Sida](https://howtotunepianos.com/error-in-the-go-ape-sequence/) |
| [IPTS] | International Piano Technicians School, sidor om varje moment. [Översikt](https://internationalpianotechniciansschool.com/units/). Enskilda sidor länkas där de används. |
| [POD] | Piano Tech Radio Hour, intervju med Cerisano, 24 maj 2024. [Sida](https://share.transistor.fm/s/4cda6276) |
| [PW] | Trådar på forumet Piano World. Bara sökmotorernas sammanfattningar gick att läsa; se [Vad andra säger](#vad-andra-säger). |

## Namn och idé

A.P.E. står för Accuracy, Precision and Efficiency, alltså noggrannhet, precision och effektivitet [LEARN] [PTJ17]. De flesta av hans sidor använder adjektiven, "Accurate, Precise, and Efficient". År 2016 hette det "Going APE". Sedan 2025 kallar han det också "Mark Cerisano Tuning System" ([sida om PTG-seminariet](https://howtotunepianos.com/ptg-seminar/)).

Metoden har tre delar [INTRO]:

1. **Svävningsfönster** (beat speed windows). Varje ny ton ger ett intervall som ska sväva med en hastighet mellan två intervall som redan är stämda, ett långsammare och ett snabbare.
2. **Dubbelsträngsunison (DSU).** Du bedömer tonhöjden på två strängar som är rena mot varandra. Paret flyttas genom att du först flyttar den ena strängen och sedan den andra.
3. **Spänningsanalys av den icke klingande stränglängden.** En teknik för stabila stämskruvar och strängar [PTJ15b].

Det som skiljer metoden från en traditionell temperering med kvarter och kvinter:

- **Snabba intervall bestämmer tonhöjden.** Terser och sexter, som svävar snabbt, avgör var varje ton hamnar. Kvarter och kvinter, som svävar långsamt, används bara som kontroller [PTJ15].
- **Varje ton halverar ett fönster.** Det nya intervallet svävar precis mitt emellan de två runt det. Fönstren krymper allt eftersom tempereringen fylls i, från steg på 25 % mellan stora terser i följd ner till ungefär 6 % per halvton [PTJ15].
- **Den rättar sig själv.** Varje fönster prövar också de toner det byggdes av. En ton som har glidit märks därför innan andra toner stäms från den [PTJ17].
- **Ordningen beror på pianot.** Först bedömer du efter gehör hur mycket pianots oktaver skiljer sig mellan 4:2- och 6:3-provet. Det väljer en av tre ordningar [PTJ15].
- **Stretchen kommer från rena breda intervall.** Ovanför tempereringen görs duodecimor, 19:or och trippeloktaver rena, inte oktaver av en fast typ [PTJ17].
- **En omgång.** Artikeln från 2015 lovar en liksvävande temperering som "may not need any refining after only one pass" [PTJ15]. Senare källor tar delvis tillbaka det; se [Ändringar och motsägelser](#ändringar-och-motsägelser).

## Begrepp

Cerisanos ord, och hur de förhåller sig till Piano Tunahs ordlista i [CONTEXT.md](../CONTEXT.md).

- **Fönster** (window). Tre intervall skrivna `X < Y < Z`: stäm tonen så att Y svävar mitt emellan X (långsammare) och Z (snabbare), med "an even ratio" [PTJ15]. I Piano Tunah är en kontroll ett intervall med sin svävning. Ett fönster binder ihop tre intervall och skulle behöva en egen term.
- **Likhet** (equality). Två intervall skrivna `X = Y` som ska sväva lika fort.
- **RBI och SBI.** Snabbt svävande intervall (stora och små terser, stora sexter) och långsamt svävande intervall (kvarter, kvinter).
- **Skelett** (skeleton). De stora terserna i följd F3–A3–C♯4–F4–A4. Det undre skelettet är F3–A3, A3–C♯4, C♯4–F4; det övre är A3–C♯4, C♯4–F4, F4–A4. Kallas också "Jack's Stack" efter Jack Stebbins ([sida](https://howtotunepianos.com/setting-f3-a3/)).
- **Kontrollton** (check note). En ton under intervallet som prövas, som används för att jämföra två intervall som båda börjar på den. För en oktav N1–N2 med kontrolltonen CN jämför 4:2-provet CN–N1 (stor ters) med CN–N2 (stor decima) [PTJ17].
- **Oktavspridning** (octave spread). Skillnaden i cent mellan en ren 4:2-oktav och en ren 6:3-oktav på just det här pianot. Den kommer från inharmoniciteten. Klasser: *liten* under 0,5 cent, *mellan* 0,5–1,1 cent, *stor* över 1,1 cent [PTJ15]. Han kallar dem också small, medium och large *scale*. Piano Tunah använder redan *liten* om pianots storlek, så klasserna behöver andra namn i appen.
- **Uppställning, saknade länkar, avslutning** (set-up, missing links, wrap-up). Tempereringens tre faser [PTJ15].
- **Stege** (ladder). En rad intervall som ska stiga jämnt, som kontroll efter en fas [PTJ15].
- **Modifierad liksvävning** (modified equal beating). En senare ändring som låter D♯4 och E4 ligga över mitten av sina fönster [ACC] [TR022].
- **Öppen unison** (open unison). Alla strängar i en tangent stäms innan nästa tangent [PTJ16].
- **Omgång.** Cerisanos "one pass" betyder att tempereringen inte gås igenom en andra gång. I Piano Tunah är en omgång en hel stämning, så dokumentationen måste hålla isär de två.

## Arbetsgången

### 1. A4

- **2015:** A4 från en stämgaffel, kontrollerad med F2: intervallet F2–stämgaffel och F2–A4 ska sväva lika [PTJ15].
- **Från 2020:** A4 med en elektronisk stämapparat och DSU, till 440 Hz ±1 cent. Dämpa den högra strängen, gör paret rent, läs av apparaten, flytta en sträng så mycket som felet är, gör paret rent igen och upprepa. Börja minst 4 cent lågt. Stäm sedan den tredje strängen ([IPTS moment 2](https://internationalpianotechniciansschool.com/tuning-a4-video-submission/)).

### 2. De två referensoktaverna och oktavspridningen

Tempereringsoktaven är F3–F4. A3–A4 stäms först som en andra referens [PTJ15]. C♯3–E3 används som kontrolltoner. De stäms inte, men de måste vara rena och sväva i en användbar takt mot tonen de prövar: 4–7 svävningar per sekund i [PTJ17], 4–5 i [IPTS moment 3](https://internationalpianotechniciansschool.com/tune-a3a4-as-a-pure-42/).

Två prov bestämmer en oktavs storlek [PTJ17] [IPTS moment 6](https://internationalpianotechniciansschool.com/skeleton/):

| Prov | A3–A4 | F3–F4 | Rent när |
|---|---|---|---|
| 4:2 | F3–A3 mot F3–A4 | C♯3–F3 mot C♯3–F4 | den stora tersen och decimen svävar lika |
| 6:3 | A3–C4 mot C4–A4 | F3–G♯3 mot G♯3–F4 | den lilla tersen och stora sexten svävar lika |

Skillnader under 3,6 % hörs som lika [PTJ15]. Så klassar du pianot [PTJ15]:

1. Stäm en ren 4:2. Är 6:3 också ren och låter oktaven svävningsfri är spridningen **liten**.
2. Är 6:3 mycket trång och låter oktaven svävningsfri är spridningen **stor**.
3. Annars stämmer du en något vid 4:2 med en något trång 6:3. Låter det svävningsfritt är spridningen **mellan**.

Oktaver som är vidare vid 6:3 än vid 4:2 ("reversed"), eller F- och A-oktaver i olika klasser, är "beyond this paper" [PTJ15]. De öppna källorna säger inte vad man gör med dem.

### 3. Uppställning

`X < Y < Z` betyder att Y svävar mitt emellan X och Z [PTJ15] [SEPTG] [IPTS].

| Ordning | Ton | Hur |
|---|---|---|
| 1 | A3 | A3–A4 svävningsfri |
| 2 | F3 | F3–A3 med ungefär 7 svävningar per sekund. "Its accuracy is not critical." Liksvävande temperatur ger 6,9. |
| 3 | F4 | F3–F4 som ren oktav |
| 4 | C♯4 | F3–A3, A3–C♯4, C♯4–F4 stiger med samma kvot |
| 5 | F4 igen | A3–C♯4, C♯4–F4, F4–A4 stiger med samma kvot |
| 6 | F3 igen | F3–F4 svävningsfri, storlek som i steg 2 |
| 7 | — | F3–A3, A3–C♯4, C♯4–F4, F4–A4 stiger jämnt, ungefär 25 % per steg |
| 8 | D4 | F3–A3 < F3–D4 < A3–C♯4, kontrollerad med kvarten A3–D4 |

### 4. Saknade länkar: F♯3 och A♯3

Klassen från steg 2 väljer ordningen [PTJ15] [IPTS].

**Liten spridning**, används också när klassen är okänd ([IPTS moment 8](https://internationalpianotechniciansschool.com/units/)):

| Ton | Fönster | Kontroll |
|---|---|---|
| F♯3 | A3–C♯4 < F♯3–A3 < C♯4–F4 | F♯3–C♯4 |
| A♯3 | C♯4–F4 < A♯3–C♯4 < F4–A4 | F3–A♯3 = A♯3–F4 |

**Stor spridning:**

| Ton | Likhet | Kontroll |
|---|---|---|
| F♯3 | F♯3–A3 = C♯4–F4 | F♯3–C♯4 |
| A♯3 | A♯3–C♯4 = F4–A4 | F3–A♯3 = A♯3–F4 |

**Mellan spridning**, i ordningen G♯3, C4, A♯3, F♯3 ([IPTS](https://internationalpianotechniciansschool.com/tuning-fs3-and-as3-medium-scale/)):

| Ton | Fönster | Kontroll |
|---|---|---|
| G♯3 | A3–C♯4 < F3–G♯3 < C♯4–F4 | G♯3–C♯4 |
| C4 | C♯4–F4 < A3–C4 < F4–A4 | F3–C4, C4–F4 |
| A♯3 | A3–C♯4 < A♯3–D4 < F3–G♯3 | F3–A♯3 = A♯3–F4 |
| F♯3 | F3–A3 < F♯3–A♯3 < F3–D4 | F♯3–C♯4 |

Varför klasserna skiljer sig: utan inharmonicitet svävar en liten ters som en viss stor ters högre upp, till exempel F♯3–A3 som B3–D♯4. Inharmoniciteten bryter den likheten, och spridningen säger hur mycket [PTJ15]. I tabellerna paras den lilla tersen med en högre och snabbare stor ters ju större spridningen är.

**Slutsats:** texten från 2015 säger att inharmoniciteten får den lilla tersen att sväva långsammare. Tabellerna säger motsatsen. Piano Tunahs modell för inharmonicitet stämmer med tabellerna. Den lilla tersen F3–G♯3 svävar närmast C4–E4 på ett 120 cm högt pianino (inom 1,1 %) och närmast B3–D♯4 på en 180 cm lång flygel (inom 1,0 %). Det är tabellerna som ska implementeras.

### 5. Avslutning, samma för alla klasser

| Ton | Fönster | Kontroll |
|---|---|---|
| D♯4 | F♯3–A♯3 < F♯3–D♯4 < A♯3–D4 | A♯3–D♯4 |
| B3 | A3–C♯4 < B3–D♯4 < C♯4–F4 | F♯3–B3 |
| G3 | F3–A3 < G3–B3 < A3–C♯4 | G3–D4 |
| E4 | G3–B3 < G3–E4 < B3–D♯4 | A3–E4, E4–A4 |
| C4 | B3–D♯4 < C4–E4 < C♯4–F4 | F3–C4, C4–F4 |
| G♯3 | G3–B3 < G♯3–C4 < A3–C♯4 | G♯3–D♯4, G♯3–C♯4 |

Källor: [PTJ15] fig. 5, [IPTS moment 9](https://internationalpianotechniciansschool.com/tuning-g3b3d4/), [IPTS moment 10](https://internationalpianotechniciansschool.com/tuning-the-4th-augmented-chord/). I mellanklassen är C4 och G♯3 redan stämda, och fönstren kontrollerar dem bara. Artikeln från 2015 har några tryckfel här: D♯4-fönstret slutar på "A♯3–C♯4" där skolans sida har A♯3–D4, och B3-kontrollen lyder "B3–F♯4", utanför tempereringen. Tabellen använder de intervall som troligen avses.

### 6. Stegar, efterkontroll och den senare rättelsen

Stegar bekräftar en fas [PTJ15]:

- Liten och stor spridning, efter G3: F3–A3 < G3–B3 < A3–C♯4 < B3–D♯4 < C♯4–F4.
- Mellan spridning, efter F♯3: tretton intervall från F3–A3 till F4–A4, i den ordning som står i [PTJ15].

Har ett fönster stängts, till exempel om det inte finns plats för C4 mellan B3–D♯4 och C♯4–F4, kontrollerar du varje ton i fönstret "the way it was tuned" innan du går vidare [TR022]. Den vanliga genomgången med många kontrollintervall kallar han "obsolete". Till sist spelar du alla kvarter och kvinter och kontrollerar på samma sätt de som sticker ut ([IPTS moment 11](https://internationalpianotechniciansschool.com/temperament/)).

Likheterna bakom några av fönstren är fel med 1,87 % även utan inharmonicitet [PTJ15], och felet växer på vägen. [ERR] anger att E4, C4 och G♯3 hamnar ungefär 6 % fel. Från 2019 låter den "modifierade" ordningen D♯4 och E4 luta mot den snabbare sidan av sina fönster [ACC] [TR022]. Hur mycket är inte offentligt.

### 7. Diskant

[PTJ17] gäller pianon vars mellersta oktaver låter bäst som ren 4:2 och ren 6:3. Varje avsnitt har ett fönster med en kontrollton i eller under tempereringen. I varje fönster skiljer sig det långsamma och det snabba intervallet med ungefär 12 %, och ett fönster kan vara "as small as 0.5 cents".

| Avsnitt | Fönster | Gör rent |
|---|---|---|
| F♯4–B4 | P4-fönster: M3 = M10 < M6 | 4:2-oktav |
| C5–E5 | P5-fönster: M6 = M17 > M10 | duodecima |
| F5–B5 | Utvidgat P4-fönster: M3 = M10 < M17 = M6 | duodecima |
| C6–E6 | 6:2 P5-fönster, lägger till en liten ters under kontrolltonen | 19:e (två oktaver och en kvint) |
| F6–B6 | 8:4-fönster, lägger till en liten sext under | trippeloktav, också undecima och en 8:6-kvart |
| C7–C8 | inga kontrolltoner, "too fast to hear" | oktav, undecima, duodecima, 19:e och trippeloktav, lyssnade direkt |

Exempel för F♯4: D3–F♯3 = D3–F♯4 < D3–B3. Exempel för C6: G♯3–C4 = G♯3–C5 < G♯3–C6 = G♯3–F4 = F3–G♯3.

På pianon som behöver trånga 6:3-oktaver i mitten väljer du vid 19:an: antingen mer stretch så att den blir ren och de andra intervallen vida, eller en trång 19:e och rena undecimor, duodecimor och trippeloktaver [PTJ17].

Skolan använder lite andra gränser: F♯4–A4, A♯4–B4 (också en ren undecima), C5–D5, D♯5–E5, F5–B5, C6–E6, F6–A6, A♯6–C8 [IPTS].

### 8. Bas

"The bass is tuned using the 8:4 Window" [PTJ17]. Håller man alla stora intervall rena kan oktaven bli lidande, och då "compromise and choice must occur". Skolan räknar upp intervallen att pröva från E3 ner till första tangenten med två strängar: en 8:6-kvart, en 6:3-oktav, undecima, duodecima, 19:e och trippeloktav ([IPTS moment 20](https://internationalpianotechniciansschool.com/unit-21-bass-section-1/)). Tangenter med en sträng stäms så att oktaven får en ren svävning av den lägsta tonens grundton, eller ren mot en hög delton om en sådan svävar. Du väljer efter gehör ([IPTS moment 21](https://internationalpianotechniciansschool.com/bass-single-strings/)).

### 9. Unisoner och dämpning

- **DSU:** dämpa en sträng, gör paret rent, flytta en sträng så mycket som behövs, gör paret rent med den andra, ta bort dämpningen och stäm den tredje strängen ([video](https://www.youtube.com/watch?v=8j7yWRq8F8s)).
- **Shimming:** för att flytta en färdig unison så lite som 0,3 cent dämpar du en sträng, trycker på en stämskruv precis så mycket att klangfärgen ändras utan att det börjar sväva, trycker likadant på den andra och sist på den tredje. "Add the third string before making any judgment" [PTJ16].
- **Öppna unisoner:** ett kor kan hamna upp till 2 cent över eller under sin första sträng, och åt vilket håll går inte att förutse. Därför gör han varje tangent färdig med alla strängar innan han går vidare, med gummikilar. Han skriver att "a mute strip, even just for the temperament, may not be efficient" [PTJ16]. Skolan kräver öppna unisoner utan dämpning i tempereringen ([IPTS](https://internationalpianotechniciansschool.com/units/)).

### 10. Grovstämning och stabilitet

Fönstren "can be used to tune minor pitch raises with one pass without needing as much overpull as other methods" [PTJ17]. Hans videor visar uppdragningar på 10, 24 och 30 cent i en omgång. Han publicerar inga värden för överdrag.

För stabilitet lämnar han spänningen i den icke klingande stränglängden "near the top of the tension band" [PTJ15b] och undviker "damaging test blows" [LEARN]. Skolan låter ändå eleverna slå "three times very loudly" för att visa att en ton står ([IPTS moment 1](https://internationalpianotechniciansschool.com/a4-dsu/)).

## Siffror

| Vad | Värde | Källa |
|---|---|---|
| F3–A3 vid start | 7 svävningar per sekund (6,9 i liksvävande temperatur) | [PTJ15] |
| Ökning per halvton | 5,95 % | [PTJ15] |
| Ökning mellan terser i följd | 25 % | [PTJ15] |
| Skillnad som örat märker | 3 % för snabba intervall, 6 % för långsamma (hans studie med sex personer) | [PTJ15] |
| Hörs som lika | under 3,6 % | [PTJ15] |
| Klasser för oktavspridning | under 0,5, 0,5–1,1, över 1,1 cent | [PTJ15] |
| Kontrolltonens svävning | 4–7 per sekund | [PTJ17] |
| Långsamt och snabbt i diskantens fönster | ungefär 12 % isär | [PTJ17] |
| Fel i likheterna mellan terser och sexter | 1,87 % | [PTJ15] |
| A4 | 440 Hz ±1 cent | [IPTS moment 2] |
| Unisonens drift | upp till ungefär 2 cent åt något håll | [PTJ16] |
| Hans bedömning av en temperering | terserna stiger 0–12 % per halvton, kvarterna svävar 0,5–1,5 per sekund | [TR022] |

Han anger ingen tid per stämning. "Efficient" vilar på en enda omgång och färre flyttar av dämparna.

## Ändringar och motsägelser

- **A4:** stämgaffel 2015, elektronisk stämapparat från 2020.
- **En omgång:** påståendet från 2015 om att ingen efterkontroll behövs står mot den senare felsidan [ERR] och den modifierade ordningen [ACC]. Hans egen simulering ger den ursprungliga ordningen 75 % och den modifierade 100 % [ACC]. Kalkylbladet bakom är borttaget.
- **Gränser i diskanten:** artikeln från 2017 och skolan skiljer sig (se avsnitt 7).
- **Upplösning med DSU:** 0,5 cent i [INTRO], 0,3 cent i [LEARN] och [PTJ16].
- **Kraftiga provslag:** undviks enligt [LEARN], krävs i skolans moment.
- **Odefinierade namn:** "Venn Tuning", "Common Finish", "Surrogate M3", "One Check" och "Killer Octave" finns bara som videokapitel eller titlar.

## Vad andra säger

Nästan ingen annan har skrivit om metoden. Intervjun [POD] bekräftar namnet, ett föredrag på PTG:s konvent 2015 och två planerade lektioner 2024, men beskriver inga steg. Diskussionen finns på forumet Piano World, som spärrar automatisk läsning. Punkterna nedan kommer därför från sökmotorernas sammanfattningar, inte från trådarna själva:

- I en tråd från 2013 menar en skribent, enligt sammanfattningen, att metoden inte får dubbeloktaven och duodecimen att sväva lika, men att skillnaden är liten. En annan ifrågasätter hur ny metoden är ([tråd](https://forums.pianoworld.com/ubbthreads.php/ubb/printthread/Board/3/main/140101/type/thread.html)).
- Sammanfattningen av en tråd från 2016 tyder på att hans stämningar var mindre jämna när de mättes än när de lyssnades på. Vi kunde inte läsa tråden och se vem som sa vad ([tråd](https://forum.pianoworld.com/ubbthreads.php/topics/2598445/Beat_Speed_Windows_Temperament.html)).
- Sammanfattningarna beskriver hans oktaver som en kompromiss mellan 4:2 och 6:3. Enligt artikeln från 2015 stämmer det bara för mellanklassen.

Cerisano skriver själv att skelettet av terser i följd inte är nytt [PTJ15]. Det han kallar nytt är halveringen av fönster och valet av ordning efter oktavspridningen. Hans gränser för vad örat hör kommer från hans egen studie med sex personer, och vi har inte hittat någon som har upprepat den. Ingen källa jämför hans metod med andra publicerade tempereringsordningar.

## Hur metoden passar Piano Tunah

Avsnittet är vår analys, gjord genom att köra `web/static/js/theory.js` med appens modell för inharmonicitet.

**Det appen redan kan.** Den mäter inharmoniciteten per tangent och kan därför räkna ut oktavspridningen i stället för att stämmaren bedömer den efter gehör. Med bara modellen blir spridningen 2,9 cent på ett 100 cm högt pianino, 1,5 cent på ett 140 cm högt pianino eller en 150 cm lång flygel, 1,2 cent på en 180 cm lång flygel och 0,8 cent på en 275 cm lång flygel. Enligt hans gränser hamnar nästan alla pianon i den stora klassen, och bara konsertflygeln i mellanklassen. Appen räknar också ut svävningen för terser, sexter, decimor och septimdecimor med inharmoniciteten inräknad, så den kan visa hur varje fönster ska låta på just det pianot.

**Det som saknas**, det största först:

1. **Fönster och likheter.** Arbetsordningen visar kontrollerna som enskilda intervall med sina svävningar. A.P.E. behöver två eller tre intervall visade tillsammans, med målet mellan dem eller lika med dem.
2. **En andra tempereringsordning.** Dagens tempereringssteg är F3–E4 med kvarter och kvinter. A.P.E. behöver F3–F4 med terser, tre varianter efter D4 och uppgifter som går tillbaka till F3 och F4.
3. **En blandad oktav.** Mellanklassen vill ha en något vid 4:2 med en något trång 6:3. Appen har bara oktavtyperna 2:1, 4:2, 6:3 och 8:4.
4. **Stretch från rena breda intervall.** Appen bygger målen som en kedja av oktaver och för diskanten mot 2:1 ovanför C6. Med normal stretch ligger duodecimorna inom ungefär 1 cent från rena upp till C7. 19:orna är 1,1–1,4 cent trånga i C6–E6 och trippeloktaverna 0,7–2,2 cent trånga i F6–B6. Nära C8 är de 7–10 cent trånga. A.P.E. gör dem rena, så dess diskant blir vidare än appens. Appen saknar också liten sext, undecima, 19:e och trippeloktav som kontrollintervall.

**Det som krockar med appen som den är:**

- **Filtremsa.** Appens arbetsordning dämpar F3–A4 med en filtremsa. A.P.E. stämmer öppna unisoner med kilar eller DSU.
- **Två anslag.** Appen räknar en uppgift som klar efter två anslag i rad inom toleransen. Cerisano undviker kraftiga provslag.
- **Ord.** "Liten" och "stor" används redan om pianots storlek. "Omgång" betyder något annat. "Kontrollton" ligger nära appens kontroll.

## Öppna frågor

Frågor för oss innan vi implementerar:

- Ska A.P.E. bli en andra arbetsordning bredvid den nuvarande, eller ersätta tempereringssteget?
- Ska appen välja klass från uppmätt inharmonicitet, eller ska stämmaren bedöma den efter gehör så som Cerisano lär ut? Appens siffror lägger nästan alla pianon i den stora klassen.
- Ska appens stretch följa A.P.E. i diskanten (rena 19:or och trippeloktaver), eller ska fönstren bara visas som kontroller mot dagens mål?
- Ska "mitt emellan" betyda det geometriska medelvärdet av de två svävningarna? **Slutsats:** ja, eftersom han mäter skillnader som kvoter [PTJ15].
- Hur mycket ska D♯4 och E4 luta i den modifierade ordningen? Det är inte offentligt.

Frågor som källorna inte besvarar:

- Vad man gör med omvända oktaver, eller med F- och A-oktaver i olika klasser.
- Om den nuvarande "Go APE Sequence" i hans betalda material är ordningen från 2015 med den senare lutningen, eller om den skiljer sig mer.
- Vad trådarna på Piano World säger i sin helhet.
