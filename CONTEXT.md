# Piano Tunah

Piano Tunah is for tuning an acoustic piano by ear with help from a microphone. It measures how the piano sounds, computes where each key should be, and shows how far each key is from there. The Swedish UI words are in square brackets.

## Piano

**Piano** [piano]:
One instrument as the app keeps it: its name, kind, size, settings, measurements, current pass and history.
_Avoid_: tuning (for the saved record)

**Key** [tangent]:
One of the piano's 85 or 88 keys, numbered 1 (A0) upwards. Counts and progress are always in keys.
_Avoid_: note (for a count)

**Note** [ton]:
The name of a key's pitch, such as A4 or B♭1, or the sound a key makes.
_Avoid_: key (for the name)

**Unison** [unison]:
The two or three strings struck by one key. When they disagree the note beats.

**Strings per key** [strängar per tangent]:
Three strings, except in the bass: keys up to one chosen key have two, and keys up to a second, lower key have one. Each piano has its own setting.

## Measuring

**Reading**:
One pitch estimate of the sounding key from a fraction of a second of sound.
_Avoid_: measurement (for a single estimate)

**Measurement** [mätning]:
The pitch the app saves for a key in the current pass, taken from several steady readings. The first one in a pass is Before [Före] and the latest is Now [Nu].
_Avoid_: reading

**Partial** [delton]:
One of the frequencies a string sounds at once; partial 1 is the fundamental. In the bass the app measures a higher partial instead of the weak fundamental.
_Avoid_: overtone, harmonic

**Inharmonicity (B)** [inharmonicitet]:
How far a string's partials lie above whole multiples of its fundamental, caused by the string's stiffness. The app measures it per key, interpolates it between measured keys, or estimates it from the piano's size.

**Survey** [kartläggning]:
Measuring the piano key by key before tuning, to learn its inharmonicity and current pitch. No tuning happens during a survey.
_Avoid_: mapping

**Scope** [omfattning]:
Which keys a survey asks for: All A (A0–A7) or All keys.
_Avoid_: plan, quick, full

**Run**:
One survey from start to finish. It records the keys measured or skipped so far. A run of All keys continues where the last one stopped.

**Pass** [omgång]:
One tuning of the piano, from New pass to the next. Ending a pass saves a summary to the history and clears the measurements but keeps inharmonicity and settings.
_Avoid_: session, run

## Target

**Reference** [referens]:
The frequency A4 is tuned to, such as 440 Hz. You can set it from the piano's current pitch to avoid raising that pitch.
_Avoid_: pitch standard, concert pitch

**Temperament** [temperatur]:
How the twelve fifths in an octave are made narrower than pure. Equal temperament is the default.

**Stretch** [stretch]:
How much the octaves are widened beyond 2:1 so they sound beatless despite inharmonicity. You choose it as an octave type for each range of the keyboard.

**Target** [mål]:
The pitch a key should be tuned to, computed from the reference, temperament, stretch and the piano's inharmonicity. The app shows it in cents from equal temperament as the target curve.

**Overpull** [överdrag]:
Tuning past the target when raising a flat piano, because the tension change makes tuned strings sink. The amount is a percentage of how flat each key was.

**Tolerance** [tolerans]:
How many cents from the target count as in tune.

## Tuner modes

**Auto** [auto]:
A mode where the app works out which key is sounding.

**Lock** [lås]:
A mode where the app measures only the selected key, for keys too far off for Auto to recognise.

## Tuning order

**Tuning order** [arbetsordning]:
The steps of a tuning by hand, from the pitch check to the last unison. You follow it key by key. It is optional, and you can use other keys and modes meanwhile.
_Avoid_: guide, wizard, mode

**Step** [steg]:
One part of the tuning order, such as the temperament or the bass. Most steps have tasks; some are only an instruction.

**Task**:
One key and what to do with it in a step: tune its free string, tune one string with a wedge, tune two strings pure and on pitch together or the third string against them, or tune the unison pure. A task is done after two strikes in a row within tolerance.

**Pitch raise** [grovstämning]:
A quick pass over every key with overpull, before the fine tuning, when the piano is 10 cents or more off.

**Felt strip** [filt]:
A strip of felt that mutes the outer strings of F3–A4 so one string per key sounds during the temperament.

**Wedge** [kil]:
A mute for strings outside the felt strip. It goes inside one key, or between two keys so it mutes one string of each.

**Double string unison (DSU)** [dubbelsträngsunison]:
A per-piano choice under Unisons [Unisoner], instead of One string first [En sträng först]. Outside the felt strip you tune each key's two free strings pure and on pitch together, then the third string against them.

**Check** [kontroll]:
An interval you play by ear to confirm a tuned key. The app shows it with the beat rate the targets give.

**Window** [fönster]:
A check that is a third or sixth with the key being tuned, shown between the nearest tuned intervals of the same size below and above it: slower < this < faster, with how much faster each step beats. From Mark Cerisano's beat speed windows.
_Avoid_: range, bracket
