import PianoTunahAudio
import SwiftUI

/// Recording what the microphone hears to a WAV file (the web's `btn-rec`):
/// start and stop, the time so far against the limit, why a recording was
/// cut short, and what became of the latest one. The save panel is
/// `SettingsView`'s.
struct RecordingSettings: View {
    @Environment(TunerModel.self) private var tuner
    @Environment(RecordingModel.self) private var recording

    var body: some View {
        Form {
            Section {
                HStack {
                    Button {
                        recording.toggle()
                    } label: {
                        if recording.isRecording {
                            Label {
                                Text("Stop and Save", tableName: "AppSettings",
                                     comment: "Recording: end the recording and open the save panel.")
                            } icon: {
                                Image(systemName: "stop.fill")
                            }
                        } else {
                            Label {
                                Text("Record", tableName: "AppSettings", comment: "Recording: start recording.")
                            } icon: {
                                Image(systemName: "record.circle")
                            }
                        }
                    }
                    .disabled(!recording.isRecording && !recording.canStart)
                    Spacer()
                    Text(verbatim: "\(RecordingModel.clock(recording.seconds)) / \(RecordingModel.clock(RecordingModel.maxSeconds))")
                        .monospacedDigit()
                        .foregroundStyle(recording.isRecording ? HierarchicalShapeStyle.primary : .secondary)
                }
                Text("Saves what the microphone hears, unprocessed, as a WAV file: about 11 MB per minute at 48 kHz, at most \(Int(RecordingModel.maxSeconds / 60)) minutes.",
                     tableName: "AppSettings", comment: "Recording: what it does; the argument is the limit in minutes.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            if !tuner.isListening {
                Section {
                    Text("Start the microphone to record.", tableName: "AppSettings",
                         comment: "Recording: shown while not listening.")
                    Button {
                        tuner.startListening()
                    } label: {
                        Text("Start Microphone", tableName: "AppSettings", comment: "Button: start listening.")
                    }
                }
            }
            if !recording.isRecording, recording.outcome != nil || cut != nil {
                Section {
                    if let cut {
                        cutText(cut)
                    }
                    if let outcome = recording.outcome {
                        outcomeText(outcome)
                    }
                }
            }
        }
        .formStyle(.grouped)
        .fixedSize(horizontal: false, vertical: true)
    }

    /// Why the latest recording stopped early. Not shown once a new one was
    /// refused: the old warning would read as the reason.
    private var cut: AudioSession.RecordingCut? {
        recording.outcome == .notStarted ? nil : tuner.session.recordingCut
    }

    private func cutText(_ cut: AudioSession.RecordingCut) -> some View {
        Label {
            switch cut {
            case .inputRestarted:
                Text("The recording stopped early: the microphone started again, after a change of input or sleep. A recording never spans two starts.",
                     tableName: "AppSettings", comment: "Recording: cut short by a restart of the input.")
            case .inputFailed:
                Text("The recording stopped early: the microphone stopped.",
                     tableName: "AppSettings", comment: "Recording: cut short because the input failed.")
            }
        } icon: {
            Image(systemName: "exclamationmark.triangle")
        }
    }

    @ViewBuilder private func outcomeText(_ outcome: RecordingModel.Outcome) -> some View {
        switch outcome {
        case .saved(let name):
            Label {
                Text("Recording saved: \(name)", tableName: "AppSettings",
                     comment: "Recording: saved under this file name (web rec.saved).")
            } icon: {
                Image(systemName: "checkmark.circle")
            }
        case .discarded:
            Text("The recording was not saved.", tableName: "AppSettings",
                 comment: "Recording: the save panel was cancelled.")
        case .notStarted:
            failure(Text("The recording did not start. Try again once the microphone is running.", tableName: "AppSettings",
                         comment: "Recording: the audio session refused to start a recording."))
        case .empty:
            failure(Text("Nothing was recorded.", tableName: "AppSettings",
                         comment: "Recording: the recorder had no recording to save."))
        case .saveFailed(let reason):
            failure(Text("Could not save the recording: \(reason)", tableName: "AppSettings",
                         comment: "Recording: writing the WAV file failed; the argument is the system's reason."))
        }
    }

    private func failure(_ text: Text) -> some View {
        Label {
            text
        } icon: {
            Image(systemName: "xmark.octagon")
        }
    }
}
