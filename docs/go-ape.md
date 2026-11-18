# The Go A.P.E. system (Mark Cerisano)

A description of Mark Cerisano's aural tuning method, written before Piano Tunah implements any of it. [Svenska](go-ape.sv.md).

The research was done on 2026-11-18 from public sources only. Cerisano's books and his school's member lessons are paid, so this document has the method as he has published it in journal articles, on his websites and on his school's public unit pages. Where the text says **Inference**, the conclusion is ours, not his.

## Sources

The references in square brackets point to this table. All of them are Cerisano's own except [POD] and [PW].

| Ref | Source |
|---|---|
| [PTJ15] | "Tuning Accurate Equal Temperament and Ideal F3-F4 and A3-A4 Octave Sizes Using Rapid-Beating Intervals", *Piano Technicians Journal* (PTJ) 58:6, June 2015. [PDF](https://howtotunepianos.com/wp-content/uploads/2020/02/PTJ-Beat-Speed-Windows-Equal-Temperament-For-Public.pdf) |
| [PTJ15b] | "An Advanced Method to Analyze Non-Speaking Length Tension and Develop Improved Stability Techniques", PTJ, July 2015. [PDF](https://howtotunepianos.com/wp-content/uploads/2020/02/PTJ-Stability-for-public.pdf) |
| [PTJ16] | "Unison Drift", PTJ 59:3, March 2016. [PDF](https://howtotunepianos.com/wp-content/uploads/2020/02/PTJ-Unison-Drift-For-Public.pdf) |
| [PTJ17] | "Aural Stretch Using Beat Speed Windows", PTJ 60:11, November 2017. [PDF](https://howtotunepianos.com/wp-content/uploads/2020/02/PTJ-Stretch-for-public.pdf) |
| [SEPTG] | Seminar for the Southeastern PTG, 29 October 2020, with the steps as video chapters. [Page](https://howtotunepianos.com/septg/) |
| [INTRO] | "Introduction to the Go A.P.E. Aural Piano Tuning System", 2021. [Page](https://howtotunepianos.com/introduction-to-the-go-a-p-e-aural-piano-tuning-system/) |
| [LEARN] | "Learn More About the Go A.P.E. Aural Piano Tuning System", 2020. [Page](https://howtotunepianos.com/learn-more-about-the-go-a-p-e-aural-piano-tuning-system/) |
| [ACC] | "How Accurate is Your Temperament Sequence?", 2019. [Page](https://howtotunepianos.com/how-accurate-is-your-temperament-sequence/) |
| [TR022] | Temperament Report 022, 2020. [Page](https://howtotunepianos.com/temperament-report-022/) |
| [ERR] | "Error in the Go APE Sequence", undated. [Page](https://howtotunepianos.com/error-in-the-go-ape-sequence/) |
| [IPTS] | International Piano Technicians School, unit pages. [Index](https://internationalpianotechniciansschool.com/units/). Single units are linked where cited. |
| [POD] | Piano Tech Radio Hour, interview with Cerisano, 24 May 2024. [Page](https://share.transistor.fm/s/4cda6276) |
| [PW] | Piano World forum threads. Only search-engine summaries could be read; see [What others say](#what-others-say). |

## Name and idea

A.P.E. stands for Accuracy, Precision and Efficiency [LEARN] [PTJ17]. Most of his pages use the adjectives, "Accurate, Precise, and Efficient". It was "Going APE" in 2016. Since 2025 he also calls it the "Mark Cerisano Tuning System" ([PTG seminar page](https://howtotunepianos.com/ptg-seminar/)).

The method has three parts [INTRO]:

1. **Beat speed windows.** Each new note makes an interval that must beat at a speed between two intervals already tuned, one slower and one faster.
2. **Double string unison (DSU).** You judge pitch on two strings tuned pure together, and move the pair by moving one string first and then the other.
3. **Non-speaking length tension analysis.** A technique for stable tuning pins and strings [PTJ15b].

What sets it apart from a traditional temperament by fourths and fifths:

- **Fast intervals set the pitch.** Thirds and sixths, which beat fast, decide where each note goes. Fourths and fifths, which beat slowly, are only checks [PTJ15].
- **Each note is bisected.** The new interval beats exactly halfway between the two around it. The windows shrink as the temperament fills in, from 25 % steps between stacked major thirds to about 6 % per semitone [PTJ15].
- **It corrects itself.** Each window also tests the notes it was built from, so a note that has drifted shows up before other notes are tuned from it [PTJ17].
- **The sequence depends on the piano.** You first judge by ear how much the piano's octaves differ between the 4:2 and 6:3 tests. That picks one of three sequences [PTJ15].
- **The stretch comes from pure wide intervals.** Above the temperament, twelfths, nineteenths and triple octaves are made pure, not octaves of a fixed type [PTJ17].
- **One pass.** The 2015 article promises an equal temperament "that may not need any refining after only one pass" [PTJ15]. Later sources qualify this; see [Changes and contradictions](#changes-and-contradictions).

## Terms

Cerisano's words, and how they relate to Piano Tunah's glossary in [CONTEXT.md](../CONTEXT.md).

- **Window.** Three intervals written `X < Y < Z`: tune the note so that Y beats halfway between X (slower) and Z (faster), "an even ratio" [PTJ15]. In Piano Tunah a Check is one interval with its beat rate. A window relates three intervals, so it would need its own term.
- **Equality.** Two intervals written `X = Y` that should beat at the same rate.
- **RBI and SBI.** Rapid-beating intervals (major and minor thirds, major sixths) and slow-beating intervals (fourths, fifths).
- **Skeleton.** The stacked major thirds F3–A3–C♯4–F4–A4. The lower skeleton is F3–A3, A3–C♯4, C♯4–F4; the upper skeleton is A3–C♯4, C♯4–F4, F4–A4. Also called "Jack's Stack" after Jack Stebbins ([page](https://howtotunepianos.com/setting-f3-a3/)).
- **Check note.** A note below the interval being tested, used to compare two intervals that share it. For an octave N1–N2 with check note CN, the 4:2 test compares CN–N1 (major third) with CN–N2 (major tenth) [PTJ17].
- **Octave spread.** The difference in cents between a pure 4:2 and a pure 6:3 octave on this piano. It comes from inharmonicity. Classes: *small* under 0.5 cents, *medium* 0.5–1.1 cents, *large* over 1.1 cents [PTJ15]. He also calls them small, medium and large *scale*. Piano Tunah already uses *small* for the piano's size, so the classes need other names in the app.
- **Set-up, missing links, wrap-up.** The three phases of the temperament [PTJ15].
- **Ladder.** A row of intervals that should rise evenly, used as a check after a phase [PTJ15].
- **Modified equal beating.** A later change that lets D♯4 and E4 lie above the middle of their windows [ACC] [TR022].
- **Open unison.** All strings of a key are tuned before the next key [PTJ16].
- **Pass.** Cerisano's "one pass" means no second round over the temperament. In Piano Tunah a Pass is a whole tuning, so the docs must keep the two apart.

## The procedure

### 1. A4

- **2015:** A4 from a tuning fork, checked with F2: the F2–fork interval and F2–A4 should beat alike [PTJ15].
- **From 2020:** A4 with an electronic tuning device and DSU, to 440 Hz ±1 cent. Mute the right string, make the pair pure, read the device, move one string by the error, make the pair pure again, repeat. Start at least 4 cents flat. Then add the third string ([IPTS unit 2](https://internationalpianotechniciansschool.com/tuning-a4-video-submission/)).

### 2. The two reference octaves and the octave spread

The temperament octave is F3–F4. A3–A4 is tuned first as a second reference [PTJ15]. C♯3–E3 serve as check notes. They are not tuned, but they must be clean and beat at a usable speed against the note they test: 4–7 beats per second in [PTJ17], 4–5 in [IPTS unit 3](https://internationalpianotechniciansschool.com/tune-a3a4-as-a-pure-42/).

Two tests size an octave [PTJ17] [IPTS unit 6](https://internationalpianotechniciansschool.com/skeleton/):

| Test | A3–A4 | F3–F4 | Pure when |
|---|---|---|---|
| 4:2 | F3–A3 vs F3–A4 | C♯3–F3 vs C♯3–F4 | the major third and tenth beat alike |
| 6:3 | A3–C4 vs C4–A4 | F3–G♯3 vs G♯3–F4 | the minor third and major sixth beat alike |

Differences under 3.6 % sound equal [PTJ15]. To class the piano [PTJ15]:

1. Tune a pure 4:2. If the 6:3 is also pure and the octave sounds beatless, the spread is **small**.
2. If the 6:3 is very narrow and the octave sounds beatless, the spread is **large**.
3. Otherwise tune a slightly wide 4:2 with a slightly narrow 6:3. If that sounds beatless, the spread is **medium**.

Octaves that are wider at 6:3 than at 4:2 ("reversed"), or F and A octaves in different classes, are "beyond this paper" [PTJ15]. The public sources do not say what to do with them.

### 3. Set-up

`X < Y < Z` means Y beats halfway between X and Z [PTJ15] [SEPTG] [IPTS].

| Order | Note | How |
|---|---|---|
| 1 | A3 | A3–A4 beatless |
| 2 | F3 | F3–A3 at about 7 beats per second. "Its accuracy is not critical." Equal temperament gives 6.9. |
| 3 | F4 | F3–F4 as a clean octave |
| 4 | C♯4 | F3–A3, A3–C♯4, C♯4–F4 rise by the same ratio |
| 5 | F4 again | A3–C♯4, C♯4–F4, F4–A4 rise by the same ratio |
| 6 | F3 again | F3–F4 beatless, sized as in step 2 |
| 7 | — | F3–A3, A3–C♯4, C♯4–F4, F4–A4 rise evenly, about 25 % each |
| 8 | D4 | F3–A3 < F3–D4 < A3–C♯4, checked with the fourth A3–D4 |

### 4. Missing links: F♯3 and A♯3

The class from step 2 picks the sequence [PTJ15] [IPTS].

**Small spread**, also used when the class is unknown ([IPTS unit 8](https://internationalpianotechniciansschool.com/units/)):

| Note | Window | Check |
|---|---|---|
| F♯3 | A3–C♯4 < F♯3–A3 < C♯4–F4 | F♯3–C♯4 |
| A♯3 | C♯4–F4 < A♯3–C♯4 < F4–A4 | F3–A♯3 = A♯3–F4 |

**Large spread:**

| Note | Equality | Check |
|---|---|---|
| F♯3 | F♯3–A3 = C♯4–F4 | F♯3–C♯4 |
| A♯3 | A♯3–C♯4 = F4–A4 | F3–A♯3 = A♯3–F4 |

**Medium spread**, in the order G♯3, C4, A♯3, F♯3 ([IPTS](https://internationalpianotechniciansschool.com/tuning-fs3-and-as3-medium-scale/)):

| Note | Window | Check |
|---|---|---|
| G♯3 | A3–C♯4 < F3–G♯3 < C♯4–F4 | G♯3–C♯4 |
| C4 | C♯4–F4 < A3–C4 < F4–A4 | F3–C4, C4–F4 |
| A♯3 | A3–C♯4 < A♯3–D4 < F3–G♯3 | F3–A♯3 = A♯3–F4 |
| F♯3 | F3–A3 < F♯3–A♯3 < F3–D4 | F♯3–C♯4 |

Why the classes differ: without inharmonicity, a minor third beats like a particular major third higher up, for example F♯3–A3 like B3–D♯4. Inharmonicity breaks that equality, and the spread says how far [PTJ15]. In the tables, a larger spread pairs the minor third with a higher, faster major third.

**Inference:** the 2015 prose says inharmonicity makes the minor third beat slower. The tables say the opposite. Piano Tunah's inharmonicity model agrees with the tables. The minor third F3–G♯3 beats closest to C4–E4 on a 120 cm upright (within 1.1 %) and to B3–D♯4 on a 180 cm grand (within 1.0 %). The tables are the ones to implement.

### 5. Wrap-up, the same for all classes

| Note | Window | Check |
|---|---|---|
| D♯4 | F♯3–A♯3 < F♯3–D♯4 < A♯3–D4 | A♯3–D♯4 |
| B3 | A3–C♯4 < B3–D♯4 < C♯4–F4 | F♯3–B3 |
| G3 | F3–A3 < G3–B3 < A3–C♯4 | G3–D4 |
| E4 | G3–B3 < G3–E4 < B3–D♯4 | A3–E4, E4–A4 |
| C4 | B3–D♯4 < C4–E4 < C♯4–F4 | F3–C4, C4–F4 |
| G♯3 | G3–B3 < G♯3–C4 < A3–C♯4 | G♯3–D♯4, G♯3–C♯4 |

Sources: [PTJ15] fig. 5, [IPTS unit 9](https://internationalpianotechniciansschool.com/tuning-g3b3d4/), [IPTS unit 10](https://internationalpianotechniciansschool.com/tuning-the-4th-augmented-chord/). For the medium class, C4 and G♯3 are already tuned and the windows only check them. The 2015 article has a few misprints here: the D♯4 window ends in "A♯3–C♯4", where the IPTS unit has A♯3–D4, and the B3 check reads "B3–F♯4", outside the temperament. The table uses the likely intended intervals.

### 6. Ladders, refinement and the later correction

Ladders confirm a phase [PTJ15]:

- Small and large, after G3: F3–A3 < G3–B3 < A3–C♯4 < B3–D♯4 < C♯4–F4.
- Medium, after F♯3: thirteen intervals from F3–A3 to F4–A4, in the order given in [PTJ15].

If a window has closed, for example no room left for C4 between B3–D♯4 and C♯4–F4, you check each note of the window "the way it was tuned" before moving on [TR022]. He calls the usual round of many interval checks "obsolete". At the end you play all fourths and fifths and re-check any that "sticks out" the same way ([IPTS unit 11](https://internationalpianotechniciansschool.com/temperament/)).

The equalities behind some windows are off by 1.87 % even without inharmonicity [PTJ15], and the error adds up. [ERR] names E4, C4 and G♯3 as about 6 % off. From 2019 the "modified" sequence lets D♯4 and E4 lean towards the faster side of their windows [ACC] [TR022]. How far is not public.

### 7. Treble

[PTJ17] covers pianos whose middle octaves sound best as pure 4:2 and pure 6:3. Each section has a window with a check note in or below the temperament. In every window the slow and fast intervals differ by about 12 %, and a window can be "as small as 0.5 cents".

| Section | Window | Makes pure |
|---|---|---|
| F♯4–B4 | P4 window: M3 = M10 < M6 | 4:2 octave |
| C5–E5 | P5 window: M6 = M17 > M10 | twelfth |
| F5–B5 | Expanded P4 window: M3 = M10 < M17 = M6 | twelfth |
| C6–E6 | 6:2 P5 window, adds a minor third below the check note | nineteenth |
| F6–B6 | 8:4 window, adds a minor sixth below | triple octave, also the eleventh and an 8:6 fourth |
| C7–C8 | no check notes, "too fast to hear" | octave, eleventh, twelfth, nineteenth and triple octave, listened to directly |

Example for F♯4: D3–F♯3 = D3–F♯4 < D3–B3. Example for C6: G♯3–C4 = G♯3–C5 < G♯3–C6 = G♯3–F4 = F3–G♯3.

On pianos that need narrow 6:3 octaves in the middle, you choose at the nineteenth: either stretch more so it is pure and the other intervals are wide, or keep it narrow and the eleventh, twelfth and triple octave pure [PTJ17].

His school uses slightly different boundaries: F♯4–A4, A♯4–B4 (also a pure eleventh), C5–D5, D♯5–E5, F5–B5, C6–E6, F6–A6, A♯6–C8 [IPTS].

### 8. Bass

"The bass is tuned using the 8:4 Window" [PTJ17]. Keeping every large interval pure may make the octave suffer, and then "compromise and choice must occur". His school lists the intervals to test from E3 down to the first two-string key: an 8:6 fourth, a 6:3 octave, the eleventh, twelfth, nineteenth and triple octave ([IPTS unit 20](https://internationalpianotechniciansschool.com/unit-21-bass-section-1/)). For single strings you tune the octave to a clean beat of the lowest note's fundamental, or to a high partial if one beats, and choose by ear ([IPTS unit 21](https://internationalpianotechniciansschool.com/bass-single-strings/)).

### 9. Unisons and mutes

- **DSU:** mute one string, make the pair pure, move one string by the desired amount, make the pair pure with the other, remove the mute and tune the third string ([video](https://www.youtube.com/watch?v=8j7yWRq8F8s)).
- **Shimming:** to move a finished unison by as little as 0.3 cents, mute one string, push one pin just enough to change the tone colour without making a beat, push the other the same way, then the third. "Add the third string before making any judgment" [PTJ16].
- **Open unisons:** a trichord can end up as much as 2 cents above or below its first string, unpredictably. So he finishes each key with all its strings before moving on, with wedge mutes, and writes that "a mute strip, even just for the temperament, may not be efficient" [PTJ16]. His school requires open unisons without mutes in the temperament ([IPTS](https://internationalpianotechniciansschool.com/units/)).

### 10. Pitch raise and stability

The windows "can be used to tune minor pitch raises with one pass without needing as much overpull as other methods" [PTJ17]. His videos show raises of 10, 24 and 30 cents in one pass. No overpull amounts are published.

For stability he leaves the string tension in the non-speaking length "near the top of the tension band" [PTJ15b] and avoids "damaging test blows" [LEARN]. His school still has students strike "three times very loudly" to prove a note is stable ([IPTS unit 1](https://internationalpianotechniciansschool.com/a4-dsu/)).

## Numbers

| What | Value | Source |
|---|---|---|
| F3–A3 at the start | 7 beats per second (6.9 in equal temperament) | [PTJ15] |
| Rise per semitone | 5.95 % | [PTJ15] |
| Rise between stacked thirds | 25 % | [PTJ15] |
| Difference the ear notices | 3 % for fast intervals, 6 % for slow (his study of six people) | [PTJ15] |
| Heard as equal | under 3.6 % | [PTJ15] |
| Octave spread classes | under 0.5, 0.5–1.1, over 1.1 cents | [PTJ15] |
| Check note speed | 4–7 beats per second | [PTJ17] |
| Slow and fast in treble windows | about 12 % apart | [PTJ17] |
| Error in the third/sixth equalities | 1.87 % | [PTJ15] |
| A4 | 440 Hz ±1 cent | [IPTS unit 2] |
| Unison drift | up to about 2 cents either way | [PTJ16] |
| His scoring of a temperament | thirds rise 0–12 % per semitone, fourths beat 0.5–1.5 per second | [TR022] |

He publishes no time per tuning. "Efficient" rests on one pass and fewer mute moves.

## Changes and contradictions

- **A4:** tuning fork in 2015, electronic tuning device from 2020.
- **One pass:** the 2015 claim of no refinement against the later error page [ERR] and the modified sequence [ACC]. His own simulation scores the plain sequence 75 % and the modified one 100 % [ACC]. The spreadsheet behind it is deleted.
- **Treble boundaries:** the 2017 article and the school differ (see section 7).
- **DSU resolution:** 0.5 cents in [INTRO], 0.3 cents in [LEARN] and [PTJ16].
- **Test blows:** avoided in [LEARN], required in the school's units.
- **Undefined names:** "Venn Tuning", "Common Finish", "Surrogate M3", "One Check" and "Killer Octave" appear only as video chapters or titles.

## What others say

Hardly anyone else has written about the method. The interview [POD] confirms the name, a talk at the 2015 PTG convention and two classes planned for 2024, but describes no steps. The discussion is on the Piano World forum, which blocks automated reading, so the points below come from search summaries, not from the threads themselves:

- In a 2013 thread, according to the summary, one poster finds that the method does not make the double octave and the twelfth beat equally, though the difference is small, and another questions how new it is ([thread](https://forums.pianoworld.com/ubbthreads.php/ubb/printthread/Board/3/main/140101/type/thread.html)).
- The summary of a 2016 thread suggests that his tunings measured less evenly than they sounded. We could not read the thread to see who said what ([thread](https://forum.pianoworld.com/ubbthreads.php/topics/2598445/Beat_Speed_Windows_Temperament.html)).
- Summaries describe his octaves as a "compromise between 4:2 and 6:3". The 2015 article makes that true only for the medium class.

Cerisano says himself that the stacked-thirds skeleton is not new [PTJ15]. What he claims as new is the bisection and the choice of sequence from the octave spread. His perception thresholds come from his own study of six people, and we found no one who has repeated it. No source compares his method with other published sequences.

## Fit with Piano Tunah

This section is our analysis, made by running `web/js/theory.js` with the app's inharmonicity model.

**What the app can already do.** It measures inharmonicity per key, so it can compute the octave spread instead of letting the tuner judge it by ear. With the model alone the spread is 2.9 cents on a 100 cm upright, 1.5 cents on a 140 cm upright or 150 cm grand, 1.2 cents on a 180 cm grand and 0.8 cents on a 275 cm grand. By his limits almost every piano is in the large class, and only the concert grand is medium. The app also computes beat rates for thirds, sixths, tenths and seventeenths with inharmonicity included, so it can show what each window should sound like on this piano.

**What is missing**, largest first:

1. **Windows and equalities.** The tuning order shows checks as single intervals with their beat rates. A.P.E. needs two or three intervals shown together, with the target placed between them or equal to them.
2. **A second temperament sequence.** The current temperament step is F3–E4 by fourths and fifths. A.P.E. needs F3–F4 by thirds, three variants after D4, and tasks that go back to F3 and F4.
3. **A blended octave.** The medium class wants a slightly wide 4:2 with a slightly narrow 6:3. The app has the octave types 2:1, 4:2, 6:3 and 8:4 only.
4. **Stretch from pure wide intervals.** The app builds targets as a chain of octaves and moves the treble towards 2:1 above C6. With the normal stretch, twelfths are within about 1 cent of pure up to C7. Nineteenths are 1.1–1.4 cents narrow in C6–E6, and triple octaves 0.7–2.2 cents narrow in F6–B6. Near C8 they are 7–10 cents narrow. A.P.E. makes them pure, so its treble is wider than the app's. The app also lacks the minor sixth, eleventh, nineteenth and triple octave as check intervals.

**What conflicts with the app as it is:**

- **Felt strip.** The app's tuning order mutes F3–A4 with a felt strip. A.P.E. tunes open unisons with wedges or DSU.
- **Two strikes.** The app counts a task as done after two strikes in a row within tolerance. Cerisano avoids hard test blows.
- **Words.** "Small" and "large" are already the app's words for piano size. "Pass" means something else. "Check note" sits close to the app's Check.

## Open questions

Questions for us before implementing:

- Should A.P.E. be a second tuning order next to the current one, or replace the temperament step?
- Should the app choose the class from measured inharmonicity, or should the tuner judge it by ear as Cerisano teaches? The app's numbers put nearly every piano in the large class.
- Should the app's stretch follow A.P.E. in the treble (pure nineteenths and triple octaves), or only show the windows as checks against today's targets?
- Should "halfway" mean the geometric mean of the two rates? **Inference:** yes, since he measures differences as ratios [PTJ15].
- How far should D♯4 and E4 lean in the modified sequence? It is not public.

Questions the sources do not answer:

- What to do with reversed octaves, or with F and A octaves in different classes.
- Whether the current "Go APE Sequence" in his paid material equals the 2015 sequence with the later lean, or differs further.
- What the Piano World threads say in full.
