// Tuning theory: key numbering, temperaments, inharmonicity and stretch.
//
// Key k = 1..88, where 1 = A0, 49 = A4 and 88 = C8.
// All deviations are in cents relative to theoretical equal temperament from
// the reference frequency for A4.

export const KEY_COUNT = 88;
export const A4 = 49;

const PC = 1200 * Math.log2(531441 / 524288); // Pythagorean comma ≈ 23.46 cents
const SC = 1200 * Math.log2(81 / 80); // syntonic comma ≈ 21.51 cents
const SCHISMA = PC - SC; // ≈ 1.95 cents
const PURE_FIFTH = 1200 * Math.log2(3 / 2); // ≈ 701.96 cents

const NAMES = ['C', 'C♯', 'D', 'E♭', 'E', 'F', 'F♯', 'G', 'A♭', 'A', 'B♭', 'B'];

export const pitchClass = (k) => (k + 8) % 12; // 0 = C, 9 = A
export const octave = (k) => Math.floor((k + 8) / 12);
export const isBlack = (k) => [1, 3, 6, 8, 10].includes(pitchClass(k));
export const pcName = (pc) => NAMES[pc];
export const noteName = (k) => pcName(pitchClass(k)) + octave(k);

// ---------------------------------------------------------------------------
// Temperaments
//
// A temperament is given as how much each of the twelve fifths in the circle
// of fifths deviates from a pure fifth (cents). Index i goes from the note
// 7·i mod 12 to the next: C–G, G–D, D–A, A–E, E–B, B–F♯, F♯–C♯, C♯–G♯, G♯–E♭,
// E♭–B♭, B♭–F, F–C. The sum must be −PC for the circle to close; an entry that
// is null (the wolf fifth) gets what is left over.

function fifths(map, fill = 0) {
  const a = new Array(12).fill(fill);
  for (const [i, v] of Object.entries(map)) a[i] = v;
  return a;
}

export const TEMPERAMENTS = {
  et: { fifths: fifths({}, -PC / 12) },
  werckmeister3: { fifths: fifths({ 0: -PC / 4, 1: -PC / 4, 2: -PC / 4, 5: -PC / 4 }) },
  kirnberger3: { fifths: fifths({ 0: -SC / 4, 1: -SC / 4, 2: -SC / 4, 3: -SC / 4, 6: -SCHISMA }) },
  vallotti: { fifths: fifths({ 11: -PC / 6, 0: -PC / 6, 1: -PC / 6, 2: -PC / 6, 3: -PC / 6, 4: -PC / 6 }) },
  young2: { fifths: fifths({ 0: -PC / 6, 1: -PC / 6, 2: -PC / 6, 3: -PC / 6, 4: -PC / 6, 5: -PC / 6 }) },
  meantone4: { fifths: fifths({ 8: null }, -SC / 4) },
  meantone6: { fifths: fifths({ 8: null }, -SC / 6) },
};

function closeCircle(f) {
  const known = f.filter((v) => v !== null).reduce((s, v) => s + v, 0);
  return f.map((v) => (v === null ? -PC - known : v));
}

// Deviation from equal temperament per pitch class (0 = C … 11 = B),
// normalised so A is always 0 and the reference frequency applies to A4.
// root transposes the temperament to start from another note than C.
export function temperamentOffsets(id, root = 0) {
  const t = TEMPERAMENTS[id] || TEMPERAMENTS.et;
  const f = closeCircle(t.fifths);
  const pos = new Array(12).fill(0);
  let cents = 0;
  let pc = 0;
  for (let i = 0; i < 11; i++) {
    cents += PURE_FIFTH + f[i];
    pc = (pc + 7) % 12;
    pos[pc] = cents;
  }
  const off = pos.map((c, p) => {
    let d = (((c - p * 100) % 1200) + 1200) % 1200;
    if (d > 600) d -= 1200;
    return d;
  });
  const rotated = off.map((_, p) => off[(p - root + 12) % 12]);
  const a = rotated[9];
  return rotated.map((d) => d - a);
}

// ---------------------------------------------------------------------------
// Inharmonicity
//
// A stiff string has partials f_n = n·f0·√(1 + B·n²). B depends on the string's
// diameter, length, tension and stiffness. The model below is a rough average
// curve: B grows exponentially towards the treble (short strings, thick for
// their length) and slightly towards the bass (short wound strings).
// Measured values replace the model where they exist.

// The instrument is described by kind (upright/grand), size in cm (the
// upright's height or the grand's length) and number of keys. The size gives
// treble and bass factors relative to a 180 cm reference grand; short strings
// give higher B, most of all in the bass. Linear between the points.
export const PIANO_KINDS = {
  upright: { min: 90, max: 150, def: 120 },
  grand: { min: 140, max: 310, def: 180 },
};

const SIZE_FACTORS = {
  // [cm, treble factor, bass factor]
  upright: [[100, 1.6, 3], [120, 1.3, 2], [140, 1.1, 1.4]],
  grand: [[150, 1.15, 1.4], [180, 1, 1], [275, 0.8, 0.6]],
};

function sizeFactors(kind, cm) {
  const pts = SIZE_FACTORS[kind] || SIZE_FACTORS.upright;
  if (cm <= pts[0][0]) return [pts[0][1], pts[0][2]];
  for (let i = 1; i < pts.length; i++) {
    if (cm <= pts[i][0]) {
      const [c0, t0, b0] = pts[i - 1];
      const [c1, t1, b1] = pts[i];
      const f = (cm - c0) / (c1 - c0);
      return [t0 + (t1 - t0) * f, b0 + (b1 - b0) * f];
    }
  }
  const last = pts[pts.length - 1];
  return [last[1], last[2]];
}

// Rough size class for display (a key into the language files).
export function sizeClass(kind, cm) {
  if (kind === 'grand') return cm < 170 ? 'babyGrand' : cm < 220 ? 'parlourGrand' : 'concertGrand';
  return cm < 110 ? 'smallUpright' : cm < 125 ? 'midUpright' : 'tallUpright';
}

const instrumentOf = (s) => ({
  kind: s.pianoKind in PIANO_KINDS ? s.pianoKind : 'upright',
  cm: Number(s.sizeCm) || PIANO_KINDS[s.pianoKind]?.def || 120,
});

function modelB(k, inst) {
  const [t, b] = sizeFactors(inst.kind, inst.cm);
  const treble = 0.00035 * 10 ** (((k - A4) * 0.46) / 12);
  const bass = 0.00008 * 10 ** ((25 - k) * 0.025);
  return t * treble + b * bass;
}

// Older saved tunings had a fixed instrument choice (pianoType).
const LEGACY_TYPES = {
  concert: ['grand', 274, 88],
  grand: ['grand', 180, 88],
  upright: ['upright', 120, 88],
  spinet: ['upright', 100, 88],
  old85: ['upright', 120, 85],
};

export function migrateSettings(s = {}) {
  if (!s.pianoType || s.pianoKind) return s;
  const [pianoKind, sizeCm, keyCount] = LEGACY_TYPES[s.pianoType] || LEGACY_TYPES.upright;
  const { pianoType, ...rest } = s;
  return { ...rest, pianoKind, sizeCm, keyCount };
}

// B for every key. Measured values act as correction factors on the model,
// interpolated logarithmically between the measured keys.
function bCurve(inst, measured = {}) {
  const pts = Object.entries(measured)
    .map(([k, b]) => [Number(k), Math.log(b / modelB(Number(k), inst))])
    .filter(([k, r]) => k >= 1 && k <= KEY_COUNT && Number.isFinite(r))
    .sort((a, b) => a[0] - b[0]);
  const out = new Float64Array(KEY_COUNT + 1);
  for (let k = 1; k <= KEY_COUNT; k++) {
    let r = 0;
    if (pts.length) {
      if (k <= pts[0][0]) r = pts[0][1];
      else if (k >= pts[pts.length - 1][0]) r = pts[pts.length - 1][1];
      else {
        for (let i = 1; i < pts.length; i++) {
          if (k <= pts[i][0]) {
            const [k0, r0] = pts[i - 1];
            const [k1, r1] = pts[i];
            r = r0 + ((r1 - r0) * (k - k0)) / (k1 - k0);
            break;
          }
        }
      }
    }
    out[k] = modelB(k, inst) * Math.exp(r);
  }
  return out;
}

// Partial factor: partial n lies at g(B, n)·n times the fundamental (partial 1).
export const partialFactor = (B, n) => Math.sqrt((1 + B * n * n) / (1 + B));
export const partialFreq = (f1, B, n) => n * f1 * partialFactor(B, n);

// ---------------------------------------------------------------------------
// Stretch
//
// An octave "p:q" means partial p of the lower note and partial q of the upper
// note are made beatless. 2:1 gives the narrowest octave, 4:2, 6:3 and 8:4
// progressively wider. The higher the matched partials, the more stretch.

export const OCTAVE_TYPES = { '2:1': [2, 1], '4:2': [4, 2], '6:3': [6, 3], '8:4': [8, 4] };

// How many cents wider than 1200 the octave becomes with a given octave type.
export function octaveStretch(Blow, Bup, type) {
  const [pl, pu] = OCTAVE_TYPES[type] || OCTAVE_TYPES['4:2'];
  return 1200 * Math.log2(partialFactor(Blow, pl) / partialFactor(Bup, pu));
}

export const STRETCH_PRESETS = {
  none: {},
  light: { mid: '2:1', treble: '2:1', bass: '4:2' },
  normal: { mid: '4:2', treble: '4:2', bass: '6:3' },
  wide: { mid: '4:2', treble: '4:2', bass: '8:4', extraTreble: 5 },
  railsback: {},
  custom: {},
};

// Overpull for a pitch raise, in percent of how flat the piano is. Tuned
// strings drop as the load on the plate and soundboard grows while the rest
// are pulled up. 25% is the usual rule of thumb; below 10 cents the drop is
// within what a fine tuning absorbs.
export function recommendedOverpull(cents) {
  return cents <= -10 ? 25 : 0;
}

export const DEFAULT_SETTINGS = {
  refA4: 440,
  temperament: 'et',
  root: 0,
  stretch: 'normal',
  midOctave: '4:2',
  trebleOctave: '4:2',
  bassOctave: '6:3',
  extraTreble: 0,
  extraBass: 0,
  pianoKind: 'upright',
  sizeCm: 120,
  keyCount: 88, // 88 (A0–C8) or 85 (A0–A7, older pianos)
  overpull: 0,
  tolerance: 1,
};

// The temperament octave A3–A4 (keys 37–49) is tuned first. From there the
// octaves are built up and down, one at a time, with the chosen octave type.
const T_LOW = A4 - 12;

// Above C6 the higher partials of the upper note are weak and die quickly,
// and with the treble's large B a wide octave type adds up fast (a 4:2 octave
// A6–A7 was 35 cents wide on a 120 cm upright). The octaves move to 2:1 over
// C6–C8, blended rather than switched so the curve has no step.
const TOP_FROM = 64; // C6
const topShare = (k) => Math.min(1, Math.max(0, (k - TOP_FROM) / 24));

export function computeTargets(settings, measuredB = {}) {
  const s = { ...DEFAULT_SETTINGS, ...settings };
  const B = bCurve(instrumentOf(s), measuredB);
  const S = new Float64Array(KEY_COUNT + 1);
  let extraTreble = Number(s.extraTreble) || 0;
  const extraBass = Number(s.extraBass) || 0;

  if (s.stretch === 'railsback') {
    for (let k = 1; k <= KEY_COUNT; k++) {
      if (k > A4) S[k] = 30 * ((k - A4) / (KEY_COUNT - A4)) ** 3;
      else if (k < A4) S[k] = -25 * ((A4 - k) / (A4 - 1)) ** 2.5;
    }
  } else if (s.stretch !== 'none') {
    const p =
      s.stretch === 'custom'
        ? { mid: s.midOctave, treble: s.trebleOctave, bass: s.bassOctave }
        : STRETCH_PRESETS[s.stretch] || STRETCH_PRESETS.normal;
    extraTreble += p.extraTreble || 0;
    S[T_LOW] = -octaveStretch(B[T_LOW], B[A4], p.mid);
    for (let k = T_LOW + 1; k < A4; k++) S[k] = (S[T_LOW] * (A4 - k)) / 12;
    for (let k = A4 + 1; k <= KEY_COUNT; k++) {
      const w = topShare(k);
      S[k] = S[k - 12] + (1 - w) * octaveStretch(B[k - 12], B[k], p.treble) + w * octaveStretch(B[k - 12], B[k], '2:1');
    }
    for (let k = T_LOW - 1; k >= 1; k--) S[k] = S[k + 12] - octaveStretch(B[k], B[k + 12], p.bass);
  }
  for (let k = 1; k <= KEY_COUNT; k++) {
    if (k > A4) S[k] += extraTreble * ((k - A4) / (KEY_COUNT - A4)) ** 2;
    if (k < A4) S[k] -= extraBass * ((A4 - k) / (A4 - 1)) ** 2;
  }

  const temper = temperamentOffsets(s.temperament, Number(s.root) || 0);
  const cents = new Float64Array(KEY_COUNT + 1);
  const freq = new Float64Array(KEY_COUNT + 1);
  for (let k = 1; k <= KEY_COUNT; k++) {
    cents[k] = S[k] + temper[pitchClass(k)];
    freq[k] = s.refA4 * 2 ** ((k - A4) / 12 + cents[k] / 1200);
  }
  return { B, stretch: S, temper, cents, freq };
}

// Which partial is measured by default. In the bass the fundamental is weak
// (and laptop microphones hear little below ~100 Hz), so a higher partial is
// measured there.
export function defaultPartial(k) {
  if (k <= 14) return 6;
  if (k <= 26) return 4;
  if (k <= 38) return 2;
  return 1;
}

export const centsBetween = (f, ref) => 1200 * Math.log2(f / ref);
