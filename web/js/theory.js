// Stämteori: tangentnumrering, temperaturer, inharmonicitet och stretch.
//
// Tangent k = 1..88, där 1 = A0, 49 = A4 och 88 = C8.
// Alla avvikelser anges i cent relativt teoretisk liksvävande temperatur
// räknat från referensfrekvensen för A4.

export const KEY_COUNT = 88;
export const A4 = 49;

const PC = 1200 * Math.log2(531441 / 524288); // pytagoreiskt komma ≈ 23,46 cent
const SC = 1200 * Math.log2(81 / 80); // syntoniskt komma ≈ 21,51 cent
const SCHISMA = PC - SC; // ≈ 1,95 cent
const PURE_FIFTH = 1200 * Math.log2(3 / 2); // ≈ 701,96 cent

const NAMES = ['C', 'C♯', 'D', 'E♭', 'E', 'F', 'F♯', 'G', 'A♭', 'A', 'B♭', 'B'];

export const pitchClass = (k) => (k + 8) % 12; // 0 = C, 9 = A
export const octave = (k) => Math.floor((k + 8) / 12);
export const isBlack = (k) => [1, 3, 6, 8, 10].includes(pitchClass(k));
export const pcName = (pc) => NAMES[pc];
export const noteName = (k) => pcName(pitchClass(k)) + octave(k);

// ---------------------------------------------------------------------------
// Temperaturer
//
// En temperatur beskrivs som hur mycket var och en av de tolv kvinterna i
// kvintcirkeln avviker från ren kvint (cent). Index i går från tonen 7·i mod 12
// till nästa: C–G, G–D, D–A, A–E, E–B, B–F♯, F♯–C♯, C♯–G♯, G♯–E♭, E♭–B♭, B♭–F, F–C.
// Summan måste bli −PC för att cirkeln ska slutas; en post som är null
// (vargkvinten) får det som blir över.

function fifths(map, fill = 0) {
  const a = new Array(12).fill(fill);
  for (const [i, v] of Object.entries(map)) a[i] = v;
  return a;
}

export const TEMPERAMENTS = {
  et: {
    name: 'Liksvävande',
    desc: 'Alla kvinter minskas lika mycket (1/12 pytagoreiskt komma). Standard för moderna pianon; alla tonarter låter lika.',
    fifths: fifths({}, -PC / 12),
  },
  werckmeister3: {
    name: 'Werckmeister III (1691)',
    desc: 'Fyra kvinter (C–G, G–D, D–A, B–F♯) minskas 1/4 PC, resten rena. Tonarter med få förtecken låter renare.',
    fifths: fifths({ 0: -PC / 4, 1: -PC / 4, 2: -PC / 4, 5: -PC / 4 }),
  },
  kirnberger3: {
    name: 'Kirnberger III (1779)',
    desc: 'C–G–D–A–E minskas 1/4 syntoniskt komma (ren stor ters C–E), F♯–C♯ minskas ett schisma.',
    fifths: fifths({ 0: -SC / 4, 1: -SC / 4, 2: -SC / 4, 3: -SC / 4, 6: -SCHISMA }),
  },
  vallotti: {
    name: 'Vallotti (1700-tal)',
    desc: 'Sex kvinter F–C–G–D–A–E–B minskas 1/6 PC, övriga sex är rena. Mild välpasserad temperatur.',
    fifths: fifths({ 11: -PC / 6, 0: -PC / 6, 1: -PC / 6, 2: -PC / 6, 3: -PC / 6, 4: -PC / 6 }),
  },
  young2: {
    name: 'Young II (1799)',
    desc: 'Som Vallotti men förskjuten en kvint: C–G–D–A–E–B–F♯ minskas 1/6 PC.',
    fifths: fifths({ 0: -PC / 6, 1: -PC / 6, 2: -PC / 6, 3: -PC / 6, 4: -PC / 6, 5: -PC / 6 }),
  },
  meantone4: {
    name: 'Medeltonstemperatur 1/4 komma',
    desc: 'Rena stora terser i de vanliga tonarterna. Vargkvint G♯–E♭ gör avlägsna tonarter oanvändbara.',
    fifths: fifths({ 8: null }, -SC / 4),
  },
  meantone6: {
    name: 'Medeltonstemperatur 1/6 komma',
    desc: 'Mildare medelton (Silbermann). Vargkvinten G♯–E♭ är mindre men finns kvar.',
    fifths: fifths({ 8: null }, -SC / 6),
  },
};

function closeCircle(f) {
  const known = f.filter((v) => v !== null).reduce((s, v) => s + v, 0);
  return f.map((v) => (v === null ? -PC - known : v));
}

// Avvikelse från liksvävande per tonklass (0 = C … 11 = B), normaliserat så
// att A alltid är 0 och referensfrekvensen alltså gäller A4.
// root transponerar temperaturen så att den utgår från en annan grundton än C.
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

// Kvintavvikelser för visning: kvint i (från tonklass 7·i) i cent mot ren kvint.
export function temperamentFifths(id) {
  return closeCircle((TEMPERAMENTS[id] || TEMPERAMENTS.et).fifths);
}

// ---------------------------------------------------------------------------
// Inharmonicitet
//
// En styv sträng har deltoner f_n = n·f0·√(1 + B·n²). B beror på strängens
// diameter, längd, spänning och styvhet. Modellen nedan är en grov
// genomsnittskurva: B växer exponentiellt mot diskanten (korta, tjocka strängar
// i förhållande till längden) och lite mot basen (korta spunna strängar).
// Uppmätta värden ersätter modellen när de finns.

export const PIANO_TYPES = {
  concert: { name: 'Konsertflygel (≈ 2,7 m)', treble: 0.8, bass: 0.6 },
  grand: { name: 'Flygel (≈ 1,8 m)', treble: 1, bass: 1 },
  upright: { name: 'Piano (≈ 120 cm)', treble: 1.3, bass: 2 },
  spinet: { name: 'Litet piano (≈ 100 cm)', treble: 1.6, bass: 3 },
};

export function modelB(k, type) {
  const t = PIANO_TYPES[type] || PIANO_TYPES.grand;
  const treble = 0.00035 * 10 ** (((k - A4) * 0.46) / 12);
  const bass = 0.00008 * 10 ** ((25 - k) * 0.025);
  return t.treble * treble + t.bass * bass;
}

// B för alla tangenter. Uppmätta värden används som korrektionsfaktorer mot
// modellen, interpolerade logaritmiskt mellan mätpunkterna.
export function bCurve(type, measured = {}) {
  const pts = Object.entries(measured)
    .map(([k, b]) => [Number(k), Math.log(b / modelB(Number(k), type))])
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
    out[k] = modelB(k, type) * Math.exp(r);
  }
  return out;
}

// Deltonsfaktor: delton n ligger g(B, n)·n gånger grundtonen (delton 1).
export const partialFactor = (B, n) => Math.sqrt((1 + B * n * n) / (1 + B));
export const partialFreq = (f1, B, n) => n * f1 * partialFactor(B, n);

// ---------------------------------------------------------------------------
// Stretch
//
// En oktav "p:q" betyder att delton p i den undre tonen och delton q i den övre
// görs svävningsfria. 2:1 ger den smalaste oktaven, 4:2, 6:3 och 8:4 allt
// bredare. Ju högre deltoner som matchas, desto mer stretch.

export const OCTAVE_TYPES = { '2:1': [2, 1], '4:2': [4, 2], '6:3': [6, 3], '8:4': [8, 4] };

// Hur många cent bredare än 1200 oktaven blir med given oktavtyp.
export function octaveStretch(Blow, Bup, type) {
  const [pl, pu] = OCTAVE_TYPES[type] || OCTAVE_TYPES['4:2'];
  return 1200 * Math.log2(partialFactor(Blow, pl) / partialFactor(Bup, pu));
}

export const STRETCH_PRESETS = {
  none: { name: 'Ingen (teoretisk liksvävande)', desc: 'Exakt 1200 cent per oktav. Låter för smalt på ett riktigt piano, användbart som jämförelse.' },
  light: { name: 'Lätt', mid: '2:1', treble: '2:1', bass: '4:2', desc: 'Rena 2:1-oktaver i diskanten och 4:2 i basen. Bra för små pianon och mjuk klang.' },
  normal: { name: 'Normal', mid: '4:2', treble: '4:2', bass: '6:3', desc: 'Den vanligaste kompromissen: 4:2 i mitten och diskanten, 6:3 i basen.' },
  wide: { name: 'Bred (konsert)', mid: '4:2', treble: '4:2', bass: '8:4', extraTreble: 5, desc: 'Mer stretch för stora flyglar och konsertbruk: 8:4 i basen och extra höjd i diskanten.' },
  railsback: { name: 'Railsback-kurva', desc: 'Fast genomsnittskurva efter Railsbacks mätningar (≈ −25 cent på A0, +30 cent på C8). Använder inte inharmonicitet.' },
  custom: { name: 'Egen', desc: 'Välj oktavtyp för bas, mitt och diskant själv.' },
};

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
  pianoType: 'upright',
  overpull: 0,
  tolerance: 1,
};

// Temperaturoktaven A3–A4 (tangent 37–49) stäms först. Därifrån byggs
// oktaverna uppåt och nedåt, en i taget, med vald oktavtyp.
const T_LOW = A4 - 12;

export function computeTargets(settings, measuredB = {}) {
  const s = { ...DEFAULT_SETTINGS, ...settings };
  const B = bCurve(s.pianoType, measuredB);
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
    for (let k = A4 + 1; k <= KEY_COUNT; k++) S[k] = S[k - 12] + octaveStretch(B[k - 12], B[k], p.treble);
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

// Vilken delton som mäts som standard. I basen är grundtonen svag (och
// laptopmikrofoner hör dåligt under ~100 Hz), så där mäts en högre delton.
export function defaultPartial(k) {
  if (k <= 14) return 6;
  if (k <= 26) return 4;
  if (k <= 38) return 2;
  return 1;
}

export const centsBetween = (f, ref) => 1200 * Math.log2(f / ref);
