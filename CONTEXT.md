# Piano Tunah

Tuning an acoustic piano by ear with help from a microphone: measure how the piano sounds, compute where each key should be, and show how far it is from there. Swedish UI words in brackets.

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
Three, or two up to a key in the bass and one below another; set per piano.

## Measuring

**Reading**:
One pitch estimate of the sounding key from a fraction of a second of sound.
_Avoid_: measurement (for a single estimate)

**Measurement** [mätning]:
The pitch saved for a key in the current pass, taken from several steady readings. The first one in a pass is Before [Före], the latest is Now [Nu].
_Avoid_: reading

**Partial** [delton]:
One of the frequencies a string sounds at once; partial 1 is the fundamental. In the bass a higher partial is measured instead of the weak fundamental.
_Avoid_: overtone, harmonic

**Inharmonicity (B)** [inharmonicitet]:
How far a string's partials lie above whole multiples of its fundamental, from the string's stiffness. Measured per key, interpolated between measured keys, or estimated from the piano's size.

**Survey** [kartläggning]:
Measuring the piano key by key before tuning, to learn its inharmonicity and where it stands. Nothing is tuned during a survey.
_Avoid_: mapping

**Scope** [omfattning]:
Which keys a survey asks for: All A (A0–A7) or All keys.
_Avoid_: plan, quick, full

**Run**:
One survey from start to finish: the keys measured or skipped so far. A run of All keys continues where the last one stopped.

**Pass** [omgång]:
One tuning of the piano, from New pass to the next. Ending a pass saves a summary to the history and clears the measurements; inharmonicity and settings are kept.
_Avoid_: session, run

## Target

**Reference** [referens]:
The frequency A4 is tuned to, such as 440 Hz. Can be set from the piano's current pitch to avoid raising it.
_Avoid_: pitch standard, concert pitch

**Temperament** [temperatur]:
How the twelve fifths in an octave are made narrower than pure. Equal temperament unless chosen otherwise.

**Stretch** [stretch]:
How much the octaves are widened beyond 2:1 so they sound beatless despite inharmonicity, chosen as an octave type per range of the keyboard.

**Target** [mål]:
The pitch a key should be tuned to, from the reference, temperament, stretch and the piano's inharmonicity. Shown in cents from equal temperament as the target curve.

**Overpull** [överdrag]:
Tuning past the target when raising a flat piano, as a percentage of how flat each key was, because the tension change makes tuned strings sink.

**Tolerance** [tolerans]:
How many cents from the target count as in tune.

## Tuner modes

**Auto** [auto]:
The app works out which key is sounding.

**Lock** [lås]:
The app measures only the selected key, for keys too far off for Auto to recognise.

## Tuning order

**Tuning order** [arbetsordning]:
The steps of a tuning by hand, from the pitch check to the last unison, followed key by key. Optional: other keys and modes can be used meanwhile.
_Avoid_: guide, wizard, mode

**Step** [steg]:
One part of the tuning order, such as the temperament or the bass. Most steps have tasks; some are only an instruction.

**Task**:
One key and what to do with it in a step: tune its free string, tune one string with a wedge, or tune the unison pure. Done after two strikes in a row within tolerance.

**Pitch raise** [grovstämning]:
A quick pass over every key with overpull, before the fine tuning, when the piano is 10 cents or more off.

**Felt strip** [filt]:
Mutes the outer strings of F3–A4 so one string per key sounds during the temperament.

**Wedge** [kil]:
Mutes strings outside the felt strip.

**Check** [kontroll]:
An interval played by ear to confirm a tuned key, shown with the beat rate the targets give.
