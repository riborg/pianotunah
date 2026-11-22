import PianoTunahCore
import SwiftUI

/// The tuning order beside the dial (web: #order-panel): the step, how far
/// the order has come, the task and what to do next, how the latest strike
/// went, the intervals to check by ear, and the step's explanation.
struct OrderPanel: View {
    let order: OrderState
    /// The key the tuner is on.
    let key: Int
    /// Beside the dial, where the explanation has room to show in full.
    let wide: Bool
    let palette: Palette
    @Environment(TunerModel.self) private var tuner
    @Environment(\.locale) private var locale
    @State private var confirmingPass = false
    @State private var textOpen = false

    var body: some View {
        let texts = OrderTexts(order: order, decimal: DecimalSeparator(locale))
        PanelBox(palette: palette) {
            head
            PanelBar(fraction: order.progress, palette: palette)
            Text(texts.task)
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(palette.ink.color)
                .fixedSize(horizontal: false, vertical: true)
            buttons
            if let state = texts.state {
                Text(state)
                    .font(.system(size: 14))
                    .foregroundStyle((order.advice != nil ? palette.warn : palette.good).color)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if confirmingPass {
                confirmation
            }
            if !order.checks.isEmpty {
                FlowLayout {
                    ForEach(Array(order.checks.enumerated()), id: \.offset) { i, row in
                        let label = texts.check(row)
                        PanelChip(text: label.text, main: i == 0 && order.task?.from != nil, palette: palette)
                            .help(label.tooltip ?? "")
                    }
                }
            }
            explanation(texts)
        }
        .onChange(of: order.current.step) { _, step in
            if step != .finish { confirmingPass = false }
        }
    }

    private var head: some View {
        HStack(alignment: .top, spacing: 8) {
            FlowLayout(spacing: 12, lineSpacing: 8) {
                Text("Tuning order", tableName: "Panels")
                    .fontWeight(.bold)
                Picker(selection: Binding(get: { order.stepIndex }, set: { tuner.goOrderStep($0) })) {
                    ForEach(order.steps, id: \.index) { s in
                        Text(verbatim: "\(s.index + 1). \(OrderTexts.title(s))").tag(s.index)
                    }
                } label: {
                    Text("Step", tableName: "Panels")
                }
                .labelsHidden()
                .controlSize(.small)
                .fixedSize()
                if order.taskCount > 0 {
                    Text(String(localized: "key \(order.taskIndex + 1) of \(order.taskCount)", table: "Panels"))
                        .font(.system(size: 13, design: .monospaced))
                        .monospacedDigit()
                        .foregroundStyle(palette.muted.color)
                }
            }
            Spacer(minLength: 0)
            Button {
                tuner.setOrderOn(false)
            } label: {
                Image(systemName: "xmark")
            }
            .buttonStyle(.borderless)
            .help(Text("Close tuning order (O)", tableName: "Panels"))
            .accessibilityLabel(Text("Close tuning order", tableName: "Panels"))
        }
    }

    /// Back to the task's key, up to two actions for the step, and the way
    /// through the order (JS: the order-* buttons).
    private var buttons: some View {
        let t = order.task
        let step = order.current.step
        return FlowLayout {
            if let t, key != t.key {
                Button(String(localized: "Back to \(noteName(t.key))", table: "Panels")) { tuner.orderBack() }
                    .buttonStyle(.borderedProminent)
            }
            switch step {
            case .pitch:
                Button { tuner.surveyAllA() } label: { Text("Survey all A", tableName: "Panels") }
                    .buttonStyle(.borderedProminent)
                if order.canFitReference {
                    Button { tuner.fitReferenceToPiano() } label: { Text("Use the piano’s current pitch", tableName: "Panels") }
                        .buttonStyle(.bordered)
                }
            case .raise:
                let p = order.suggestedOverpull
                if p != 0 && order.overpull != p {
                    let percent = Int(p.rounded())
                    Button(String(localized: "Use \(percent)% overpull", table: "Panels")) { tuner.setOverpull(p) }
                        .buttonStyle(.borderedProminent)
                }
                Button { tuner.startFinePass() } label: { Text("Done: new pass for the fine tuning", tableName: "Panels") }
                    .buttonStyle(.bordered)
            case .finish:
                // The main action once no key is left to go over.
                if order.task == nil {
                    Button { confirmingPass = true } label: { Text("New pass", tableName: "Panels") }
                        .buttonStyle(.borderedProminent)
                } else {
                    Button { confirmingPass = true } label: { Text("New pass", tableName: "Panels") }
                        .buttonStyle(.bordered)
                }
            default:
                EmptyView()
            }
            Button { tuner.orderPrevious() } label: { Text("Previous", tableName: "Panels") }
                .buttonStyle(.bordered)
                .disabled(!order.hasPrevious)
            Button { tuner.orderNext() } label: {
                t != nil ? Text("Next key", tableName: "Panels") : Text("Next", tableName: "Panels")
            }
            .buttonStyle(.bordered)
            if t != nil {
                Button { tuner.orderSkip() } label: { Text("Next step", tableName: "Panels") }
                    .buttonStyle(.bordered)
            }
        }
    }

    /// The inline confirmation before a new pass.
    private var confirmation: some View {
        FlowLayout(spacing: 8, lineSpacing: 6) {
            Text("Save the pass to the history and start over?", tableName: "Panels")
                .font(.system(size: 13))
                .foregroundStyle(palette.ink.color)
            Button {
                confirmingPass = false
                tuner.newPass()
            } label: {
                Text("New pass", tableName: "Panels")
            }
            .buttonStyle(.borderedProminent)
            Button { confirmingPass = false } label: { Text("Cancel", tableName: "Panels") }
                .buttonStyle(.bordered)
        }
    }

    /// Under the dial the explanation shows two lines until it is opened, so
    /// the buttons stay close to the dial; beside it, all of it.
    @ViewBuilder
    private func explanation(_ texts: OrderTexts) -> some View {
        let open = wide || textOpen
        Text(texts.explanation)
            .font(.system(size: 13))
            .foregroundStyle(palette.muted.color)
            .lineLimit(open ? nil : 2)
            .fixedSize(horizontal: false, vertical: true)
        if !wide {
            Button {
                textOpen.toggle()
            } label: {
                textOpen ? Text("Show less", tableName: "Panels") : Text("Show more", tableName: "Panels")
            }
            .buttonStyle(.link)
            .font(.system(size: 13))
        }
    }
}

/// The order panel's texts, whole sentences built from the engine's
/// numbers (JS: taskText, stepParams, checkLabel and the order.* strings).
struct OrderTexts {
    let order: OrderState
    let decimal: DecimalSeparator

    // MARK: Steps

    /// A step's title, as in the step picker.
    static func title(_ s: OrderState.StepItem) -> String {
        let lo = s.from.map(noteName) ?? ""
        let hi = s.to.map(noteName) ?? ""
        switch s.step {
        case .pitch: return String(localized: "Check the pitch", table: "Panels")
        case .raise: return String(localized: "Pitch raise", table: "Panels")
        case .strip: return String(localized: "Felt strip \(lo)–\(hi)", table: "Panels")
        case .middle: return String(localized: "A4 and A3", table: "Panels")
        case .temperament: return String(localized: "Temperament \(lo)–\(hi)", table: "Panels")
        case .upper: return String(localized: "Octaves \(lo)–\(hi)", table: "Panels")
        case .treble: return String(localized: "Treble \(lo)–\(hi)", table: "Panels")
        case .pull: return String(localized: "Pull the strip \(lo)–\(hi)", table: "Panels")
        case .bass: return String(localized: "Bass \(lo)–\(hi)", table: "Panels")
        case .finish: return String(localized: LocalizedStringResource("order.finish", defaultValue: "Finish", table: "Panels"))
        }
    }

    private var lo: String { order.current.from.map(noteName) ?? "" }
    private var hi: String { order.current.to.map(noteName) ?? "" }

    /// What to do now: the task, or the step's instruction.
    var task: String {
        guard let t = order.task else {
            switch order.current.step {
            case .pitch: return String(localized: "Survey all A to see where the piano is.", table: "Panels")
            case .raise: return String(localized: "Pitch raise.", table: "Panels")
            case .strip: return String(localized: "Mute the outer strings of \(lo)–\(hi) with the felt strip.", table: "Panels")
            case .finish: return String(localized: "Every key measured in this pass is within tolerance.", table: "Panels")
            default: return Self.title(order.current)
            }
        }
        let name = noteName(t.key)
        let from = t.from.map(noteName) ?? ""
        let iv = t.from.map { Self.interval(abs(t.key - $0)) } ?? ""
        switch t.action {
        case .raise:
            return String(localized: "Raise \(name), all its strings.", table: "Panels")
        case .middle:
            return t.from != nil
                ? String(localized: "Tune \(name) from \(from) (\(iv)).", table: "Panels")
                : String(localized: "Tune \(name).", table: "Panels")
        case .one:
            return order.strings == 1
                ? String(localized: "Tune \(name) from \(from).", table: "Panels")
                : String(localized: "Wedge \(name) so one string sounds and tune it from \(from).", table: "Panels")
        case .unison:
            return order.strings == 2
                ? String(localized: "Pull the wedge and tune the second string of \(name) pure against the first.", table: "Panels")
                : String(localized: "Move the wedge so strings 1 and 2 of \(name) sound and tune 2 pure against 1; then pull it and tune 3 against both.", table: "Panels")
        case .pair:
            return order.strings == 2
                ? String(localized: "Tune both strings of \(name) pure and on pitch from \(from) (\(iv)). Move one string towards the target, then make it pure with the other.", table: "Panels")
                : String(localized: "With a wedge between \(name) and its neighbour: tune the two free strings pure and on pitch from \(from) (\(iv)). Move one string towards the target, then make it pure with the other.", table: "Panels")
        case .third:
            return String(localized: "Without the wedge: tune the third string of \(name) pure against the two.", table: "Panels")
        case .pull:
            return String(localized: "Pull the strip from \(name) and tune its outer strings pure against the middle one.", table: "Panels")
        case .recheck:
            let c = fmtC(order.recheckCents, decimal: decimal)
            return String(localized: "\(name) is \(c) cents off: tune it again.", table: "Panels")
        }
    }

    /// How the latest strike went: a clean unison off target, or one more
    /// firm strike to confirm (JS: renderOrderState). Nil for nothing.
    var state: String? {
        if let advice = order.advice {
            let c = num(order.adviceCents, decimal: decimal)
            let sharp = order.adviceCents > 0
            switch (advice, sharp) {
            case (.shift2, true):
                return String(localized: "Clean, but \(c) cents sharp. Moving one string makes it beat: move one string a little the way it should go, then make the pair clean again with the other. Repeat until it is on target.", table: "Panels")
            case (.shift2, false):
                return String(localized: "Clean, but \(c) cents flat. Moving one string makes it beat: move one string a little the way it should go, then make the pair clean again with the other. Repeat until it is on target.", table: "Panels")
            case (.shift3, true):
                return String(localized: "Clean, but \(c) cents sharp. Moving one string makes it beat: mute an outer string, move one string of the pair a little the way it should go and make the pair clean with the other, then take the mute out and tune the third string to them. Repeat until it is on target.", table: "Panels")
            case (.shift3, false):
                return String(localized: "Clean, but \(c) cents flat. Moving one string makes it beat: mute an outer string, move one string of the pair a little the way it should go and make the pair clean with the other, then take the mute out and tune the third string to them. Repeat until it is on target.", table: "Panels")
            }
        }
        return order.confirmed ? String(localized: "In tune. Strike firmly once more to check that it holds.", table: "Panels") : nil
    }

    /// The step's explanation, then where the piano is (the first two
    /// steps) and how a task is confirmed.
    var explanation: String {
        var sentences = [stepText]
        let step = order.current.step
        if step == .pitch || step == .raise { sentences.append(pitchAdvice) }
        if let t = order.task, t.action != .raise {
            sentences.append(String(localized: "Set the pin so the string stays where it is. The order moves on after two firm strikes in a row within tolerance.", table: "Panels"))
        }
        return sentences.joined(separator: " ")
    }

    private var stepText: String {
        switch order.current.step {
        case .pitch:
            return String(localized: "Set the reference first, at A4 = … Hz above the dial: 440 Hz, or 442 for playing with an orchestra. The survey measures A0–A7, since the treble and bass are often further off than A4.", table: "Panels")
        case .raise:
            return String(localized: "Only when the piano is 10 cents or more off. A quick pass over every key and all its strings, no strip, from the middle up to the top and then down to the bottom, within a few cents. Overpull tunes each key past the target so the piano settles near it. More than 25 cents flat on an old piano, 50 on a newer one: two pitch raises. Old strings can break; raise gradually. The fine tuning can follow the same day.", table: "Panels")
        case .strip:
            return String(localized: "Only the middle string of each key may sound. On an upright, hold the damper pedal down while putting in the strip or a wedge, so the dampers are not bent. The strip must sit clear of where the hammers strike: push a few hammers forward and check. Press Next when it is in.", table: "Panels")
        case .middle:
            return String(localized: "A4 to the target, then A3 as an octave below it. The tenth F3–A4 should beat as fast as the third F3–A3 (a 4:2 octave) or slightly faster; if the third is faster, A3 is too high. F3 is not tuned yet, but the comparison holds.", table: "Panels")
        case .temperament:
            return String(localized: "Fourths are slightly wide and fifths slightly narrow, at the rates shown. Thirds beat faster the higher they lie; compare each new interval with the one of the same kind below it. A row such as F♯3–B♭3 < G3–B3 < A♭3–C4 says G3–B3 should beat between the two, with the percentages each step adds. If fourths and fifths are tuned too pure, F3–A3 beats too fast.", table: "Panels")
        case .upper:
            return String(localized: "Keep the strip in. Each key as an octave from the temperament, checked with the third and tenth (M3–M10) and with the fourth and fifth.", table: "Panels")
        case .treble:
            return order.dsu
                ? String(localized: "Two keys at a time: a wedge between them mutes one string of each; hold the keys down while it goes in, so the dampers are not bent. Tune the two free strings of each key pure and on pitch as an octave from below, then pull the wedge and tune the third string. The pair counts only when it is on pitch and not beating twice a second or faster; listen for slower beats yourself. High up: short, firm strikes, listen right after the attack and check against keys two or three octaves down.", table: "Panels")
                : String(localized: "A wedge between strings 2 and 3 of the key leaves string 1; hold the key down while it goes in, so the damper is not bent. Tune it as an octave from below, then the other strings pure against it. High up: short, firm strikes, listen right after the attack, and check against two or three octaves down. If a unison at the top is hard to hear, pluck the strings one after the other.", table: "Panels")
        case .pull:
            return String(localized: "One key at a time from \(lo) down to \(hi): the outer strings pure against the middle one.", table: "Panels")
        case .bass:
            return order.dsu
                ? String(localized: "Two keys at a time from \(lo) down: a wedge between them mutes one string of each (keys held down while it goes in). Tune the two free strings pure and on pitch as an octave from above, then the third without the wedge. Keys with two strings need no wedge; a single string has no unison. Longer strikes; let the note ring. In the deep bass the twelfth and the double octave tell more than the octave, and the beats get slower further down.", table: "Panels")
                : String(localized: "Two keys at a time from \(lo) down: wedge so one string sounds (key held down while the wedge goes in), tune both as octaves from above, then the other strings. Longer strikes; let the note ring. In the deep bass the twelfth and double octave tell more than the octave, and the beats get slower further down. Keys with one string have no unison; set the string counts under Piano.", table: "Panels")
        case .finish:
            return String(localized: "Firm test blows across the keyboard, then play through the circle of fifths and listen. The keys listed are the ones outside tolerance when this step began.", table: "Panels")
        }
    }

    /// Where the piano is, for the first two steps (JS: pitchAdvice).
    private var pitchAdvice: String {
        guard let a = order.pitch else { return String(localized: "Not measured yet.", table: "Panels") }
        let c = fmtC(a.m, 0, decimal: decimal)
        return a.off
            ? String(localized: "The middle is \(c) cents from the target: do a pitch raise first, or keep the piano’s current pitch. On an old piano with fragile strings, keeping it can be the safer choice.", table: "Panels")
            : String(localized: "The middle is \(c) cents from the target: no pitch raise needed, go on to the felt strip.", table: "Panels")
    }

    // MARK: Checks

    /// An interval's name by its size in semitones.
    static func interval(_ semis: Int) -> String {
        switch semis {
        case 3: String(localized: "minor third", table: "Panels")
        case 4: String(localized: "major third", table: "Panels")
        case 5: String(localized: "fourth", table: "Panels")
        case 7: String(localized: "fifth", table: "Panels")
        case 9: String(localized: "major sixth", table: "Panels")
        case 12: String(localized: "octave", table: "Panels")
        case 16: String(localized: "tenth", table: "Panels")
        case 19: String(localized: "twelfth", table: "Panels")
        case 24: String(localized: "double octave", table: "Panels")
        case 28: String(localized: "seventeenth", table: "Panels")
        default: String(semis)
        }
    }

    /// A check row as a chip, and for a third or sixth with tuned neighbours
    /// its window: slower < this < faster, with how much faster each step
    /// beats; the tooltip says it in sentences (JS: checkLabel).
    func check(_ r: TuningOrder.CheckRow) -> (text: String, tooltip: String?) {
        let keys = Self.keys(r.lo, r.hi)
        var name = Self.interval(r.semis)
        if r.semis == 12 { name += " \(r.partials.lower):\(r.partials.upper)" }
        let text = "\(keys) \(name) \(rate(r.beat))"
        guard r.below != nil || r.above != nil else { return (text, nil) }
        var steps: [String] = []
        var tooltip: [String] = []
        var label = text
        if let b = r.below {
            let x = Self.keys(b.lo, b.hi)
            steps.append(rise(b.beat, r.beat))
            let n = rise(b.beat, r.beat, signed: false)
            tooltip.append(String(localized: "\(keys) beats \(n) faster than \(x).", table: "Panels"))
            label = "\(x) < " + label
        }
        if let a = r.above {
            let x = Self.keys(a.lo, a.hi)
            steps.append(rise(r.beat, a.beat))
            let n = rise(r.beat, a.beat, signed: false)
            tooltip.append(String(localized: "\(x) beats \(n) faster than \(keys).", table: "Panels"))
            label += " < \(x)"
        }
        return ("\(label) (\(steps.joined(separator: ", ")))", tooltip.joined(separator: " "))
    }

    private static func keys(_ lo: Int, _ hi: Int) -> String {
        "\(noteName(lo))–\(noteName(hi))"
    }

    /// Beats per second, wide or narrow, or beatless (JS: rateText).
    private func rate(_ beat: Double) -> String {
        let a = abs(beat)
        if a < 0.05 { return String(localized: "beatless", table: "Panels") }
        let n = num(a, a < 10 ? 1 : 0, decimal: decimal)
        return beat > 0
            ? String(localized: "\(n)/s wide", table: "Panels")
            : String(localized: "\(n)/s narrow", table: "Panels")
    }

    /// How much faster `b` beats than `a`, in per cent; signed for the chip,
    /// plain for the tooltip (JS: rise).
    private func rise(_ a: Double, _ b: Double, signed: Bool = true) -> String {
        let x = (abs(b) / abs(a) - 1) * 100
        let n = (signed ? (x < 0 ? "−" : "+") : "") + num(x, 0, decimal: decimal)
        return String(localized: "\(n)%", table: "Panels")
    }
}
