import PianoTunahAudio
import SwiftUI

/// The input to listen with (the web's `set-mic`), and the one in use with
/// its sample rate. The choice is kept by its Core Audio UID and applied to
/// the audio session at once (`TunerModel.useInput`).
struct MicrophoneSettings: View {
    @Environment(TunerModel.self) private var tuner
    @Environment(InputDevices.self) private var inputs
    @AppStorage(TunerModel.inputStorageKey) private var chosenUID: String?

    var body: some View {
        Form {
            Section {
                Picker(selection: $chosenUID) {
                    defaultLabel.tag(String?.none)
                    ForEach(inputs.devices) { device in
                        Text(verbatim: device.name).tag(String?.some(device.uid))
                    }
                    if let chosenUID, !isConnected(chosenUID) {
                        Text("Chosen microphone (not connected)", tableName: "AppSettings",
                             comment: "Microphone picker: the stored input is not plugged in.")
                            .tag(String?.some(chosenUID))
                    }
                } label: {
                    Text("Input", tableName: "AppSettings", comment: "Microphone picker label.")
                }
                if missing {
                    Label {
                        Text("The chosen microphone is not connected; using the system default.",
                             tableName: "AppSettings", comment: "Microphone: fallback note (web mic.missing).")
                    } icon: {
                        Image(systemName: "exclamationmark.triangle")
                    }
                    .foregroundStyle(.secondary)
                }
            }
            Section {
                status
            }
        }
        .formStyle(.grouped)
        .fixedSize(horizontal: false, vertical: true)
        .onChange(of: chosenUID) { _, uid in tuner.useInput(uid) }
    }

    private var defaultLabel: Text {
        if let uid = inputs.defaultUID, let name = inputs.devices.first(where: { $0.uid == uid })?.name {
            Text("System default (\(name))", tableName: "AppSettings",
                 comment: "Microphone picker: the system's default input, with its name.")
        } else {
            Text("System default", tableName: "AppSettings", comment: "Microphone picker: the system's default input.")
        }
    }

    private func isConnected(_ uid: String) -> Bool {
        inputs.devices.contains { $0.uid == uid }
    }

    /// The chosen input is not there, so the default is (or will be) used.
    private var missing: Bool {
        if let info = tuner.session.input { return info.usedFallback }
        return chosenUID.map { !isConnected($0) } ?? false
    }

    @ViewBuilder private var status: some View {
        let session = tuner.session
        if let info = session.input {
            LabeledContent {
                Text(verbatim: info.deviceName)
            } label: {
                Text("In use", tableName: "AppSettings", comment: "Microphone: the input listened to now.")
            }
            LabeledContent {
                Text("\(info.sampleRate, format: .number.precision(.fractionLength(0))) Hz", tableName: "AppSettings",
                     comment: "Microphone: a sample rate in hertz.")
                    .monospacedDigit()
            } label: {
                Text("Sample rate", tableName: "AppSettings", comment: "Microphone: the input's sample rate.")
            }
        } else {
            switch session.state {
            case .denied:
                Text("Microphone access is off. Allow Piano Tunah in System Settings › Privacy & Security › Microphone.",
                     tableName: "AppSettings", comment: "Microphone: the permission was denied.")
                Button {
                    tuner.openPrivacySettings()
                } label: {
                    Text("Open Privacy Settings", tableName: "AppSettings",
                         comment: "Microphone: button to the microphone pane of System Settings.")
                }
            case .failed:
                Text("The microphone did not start. It is tried again when an input is connected or the Mac wakes.",
                     tableName: "AppSettings", comment: "Microphone: the input failed.")
                Button {
                    session.restart()
                } label: {
                    Text("Try Again", tableName: "AppSettings", comment: "Microphone: restart a failed input.")
                }
            case .starting:
                Text("Starting the microphone…", tableName: "AppSettings",
                     comment: "Microphone: waiting for the permission or the input.")
            case .stopped, .running:
                Text("Start the microphone to see the input in use and its sample rate.", tableName: "AppSettings",
                     comment: "Microphone: shown while not listening.")
                Button {
                    tuner.startListening()
                } label: {
                    Text("Start Microphone", tableName: "AppSettings", comment: "Button: start listening.")
                }
            }
        }
    }
}
