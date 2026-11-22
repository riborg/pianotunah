import PianoTunahCore
import SwiftUI

/// The survey beside the dial (web: #survey-panel): the scope, how far the
/// run has come, what to do with the key now, its readings, and Skip,
/// Measure again and Finish.
struct SurveyPanel: View {
    let survey: SurveyState
    let palette: Palette
    @Environment(TunerModel.self) private var tuner

    var body: some View {
        PanelBox(palette: palette) {
            FlowLayout(spacing: 12, lineSpacing: 8) {
                Text("Survey", tableName: "Panels")
                    .fontWeight(.bold)
                Picker(selection: Binding(get: { survey.scope }, set: { tuner.setSurveyScope($0) })) {
                    Text("All A, 8 keys", tableName: "Panels").tag(Survey.Scope.allA)
                    Text("All keys", tableName: "Panels").tag(Survey.Scope.allKeys)
                } label: {
                    Text("Scope", tableName: "Panels")
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .controlSize(.small)
                .fixedSize()
                Text(String(localized: "\(survey.done) of \(survey.total) keys", table: "Panels"))
                    .font(.system(size: 13, design: .monospaced))
                    .monospacedDigit()
                    .foregroundStyle(palette.muted.color)
            }
            PanelBar(fraction: survey.fraction, palette: palette)
            Text(stepText)
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(palette.ink.color)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityAddTraits(.updatesFrequently)
            FlowLayout {
                PanelChip(
                    text: String(localized: "Pitch \(survey.pitch)/\(survey.pitchNeeded)", table: "Panels"),
                    done: survey.pitch >= survey.pitchNeeded, palette: palette)
                bChip
            }
            Text("Measures the inharmonicity of the strings and gives a tuning curve for your piano. You do not tune anything and need no felt strip. **All A:** A0–A7, about a minute. **All keys:** every key; needed for overpull and to see drift since last time. Switching starts the survey over.", tableName: "Panels")
                .font(.system(size: 13))
                .foregroundStyle(palette.muted.color)
                .fixedSize(horizontal: false, vertical: true)
            FlowLayout {
                Button { tuner.skipSurveyKey() } label: { Text("Skip", tableName: "Panels") }
                Button { tuner.redoSurveyKey() } label: { Text("Measure again", tableName: "Panels") }
                Button { tuner.finishSurvey() } label: {
                    Text(LocalizedStringResource("survey.stop", defaultValue: "Finish", table: "Panels"))
                }
            }
            .buttonStyle(.bordered)
        }
    }

    private var stepText: String {
        let name = noteName(survey.key)
        switch survey.step {
        case .strike:
            return String(localized: "Strike \(name) firmly and let it ring.", table: "Panels")
        case .lost:
            return String(localized: "\(name) died away before the measurement was done. Strike it again.", table: "Panels")
        case .listening:
            return String(localized: "Listening to \(name) … let the note ring.", table: "Panels")
        case .wrong(let heard):
            let heard = noteName(heard)
            return String(localized: "That sounds like \(heard). Strike \(name), or press Skip.", table: "Panels")
        case .offPitch:
            let limit = Int(Survey.offsetLimit)
            return String(localized: "More than \(limit) cents from the keys measured so far. Is this \(name)? Strike it again, or press Skip.", table: "Panels")
        }
    }

    private var bChip: PanelChip {
        switch survey.b {
        case .known:
            PanelChip(text: String(localized: "Inharmonicity already measured", table: "Panels"), done: true, palette: palette)
        case .skipped:
            PanelChip(text: String(localized: "Inharmonicity: overtones too weak, skipped", table: "Panels"), done: true, palette: palette)
        case .reading(let count, let needed):
            PanelChip(
                text: String(localized: "Inharmonicity \(count)/\(needed)", table: "Panels"),
                done: count >= needed, palette: palette)
        }
    }
}
