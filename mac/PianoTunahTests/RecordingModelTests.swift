import AppKit
import Foundation
import PianoTunahAudio
import Testing
@testable import PianoTunah

// RecordingModel without a microphone: a recording is put in `pending` as
// if it had just ended, and the quit alert and its save panel answer from
// here (`quitPrompts`).

@MainActor
private final class Prompts {
    var choice = RecordingModel.QuitChoice.stay
    /// What the save panel returns; nil is its Cancel.
    var url: URL?
    private(set) var asked = 0
    private(set) var suggested: [String] = []
    private(set) var reported: [any Error] = []

    func install(in model: RecordingModel) {
        model.quitPrompts = RecordingModel.QuitPrompts(
            ask: {
                self.asked += 1
                return self.choice
            },
            saveURL: { name in
                self.suggested.append(name)
                return self.url
            },
            report: { self.reported.append($0) })
    }
}

@MainActor
private func makeModel(pending: Bool = true) -> (RecordingModel, Prompts) {
    let model = RecordingModel(session: AudioSession(onFrame: { _ in }))
    if pending { model.pending = WAVFile(data: Data("RIFF".utf8), name: "pianotunah-20261123-090000.wav") }
    let prompts = Prompts()
    prompts.install(in: model)
    return (model, prompts)
}

private func temporaryDirectory() throws -> URL {
    let dir = FileManager.default.temporaryDirectory.appending(path: "PianoTunahTests-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
}

@MainActor @Suite struct QuitWithARecording {
    @Test func nothingToSaveQuitsWithoutAsking() {
        let (model, prompts) = makeModel(pending: false)
        #expect(model.confirmQuit() == .terminateNow)
        #expect(prompts.asked == 0)
    }

    @Test func cancelKeepsTheRecordingAndTheApp() {
        let (model, prompts) = makeModel()
        prompts.choice = .stay
        #expect(model.confirmQuit() == .terminateCancel)
        #expect(model.pending != nil)
        #expect(model.outcome == nil)
    }

    @Test func discardQuitsAndDropsTheRecording() {
        let (model, prompts) = makeModel()
        prompts.choice = .discard
        #expect(model.confirmQuit() == .terminateNow)
        #expect(model.pending == nil)
        #expect(model.outcome == .discarded)
    }

    // 7c53286: Save… cancelled the quit and saved nothing when no panel was
    // on screen, as for a recording that ended with Settings closed.
    @Test func saveWithNoPanelOnScreenOpensTheAlertsPanel() throws {
        let (model, prompts) = makeModel()
        #expect(!model.panelOnScreen)
        let dir = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appending(path: "take.wav")
        prompts.choice = .save
        prompts.url = url
        #expect(model.confirmQuit() == .terminateNow)
        #expect(prompts.suggested == ["pianotunah-20261123-090000.wav"])
        #expect(try Data(contentsOf: url) == Data("RIFF".utf8))
        #expect(model.pending == nil)
        #expect(model.outcome == .saved("take.wav"))
    }

    @Test func saveWithTheMainWindowsPanelUpGoesBackToIt() {
        let (model, prompts) = makeModel()
        model.saveFromMain = true
        prompts.choice = .save
        #expect(model.panelOnScreen)
        #expect(model.confirmQuit() == .terminateCancel)
        #expect(prompts.suggested.isEmpty)
        #expect(model.pending != nil)
    }

    @Test func saveWithTheSettingsPanelUpGoesBackToIt() {
        let (model, prompts) = makeModel()
        model.settingsOpen = true
        prompts.choice = .save
        #expect(model.panelOnScreen)
        #expect(model.confirmQuit() == .terminateCancel)
        #expect(prompts.suggested.isEmpty)
        #expect(model.pending != nil)
    }

    @Test func cancelInTheAlertsPanelKeepsTheRecording() {
        let (model, prompts) = makeModel()
        prompts.choice = .save
        prompts.url = nil
        #expect(model.confirmQuit() == .terminateCancel)
        #expect(prompts.suggested.count == 1)
        #expect(model.pending != nil)
        #expect(model.outcome == nil)
    }

    @Test func aFailedSaveIsReportedAndKeepsTheRecording() throws {
        let (model, prompts) = makeModel()
        let dir = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        prompts.choice = .save
        prompts.url = dir.appending(path: "missing/take.wav")
        #expect(model.confirmQuit() == .terminateCancel)
        #expect(prompts.reported.count == 1)
        #expect(model.pending != nil)
        #expect(model.outcome == nil)
    }
}

@MainActor @Suite struct WaitingRecording {
    @Test func theNoticeShowsOnlyWhenNoPanelOffersIt() {
        let (model, _) = makeModel()
        #expect(model.showsNotice)
        #expect(!model.panelOnScreen)
        model.settingsOpen = true
        #expect(!model.showsNotice)
        #expect(model.savesInSettings && model.panelOnScreen)
        model.settingsOpen = false
        model.saveFromMain = true
        #expect(!model.showsNotice)
        #expect(model.savesInMain && model.panelOnScreen)
    }

    @Test func cancelInAPanelDiscards() {
        let (model, _) = makeModel()
        model.saveFromMain = true
        model.cancelled()
        #expect(model.pending == nil)
        #expect(!model.saveFromMain)
        #expect(model.outcome == .discarded)
    }

    @Test func cancelWithNothingWaitingChangesNothing() {
        let (model, _) = makeModel(pending: false)
        model.cancelled()
        #expect(model.outcome == nil)
    }

    @Test func exportedSavesOrReportsTheFailure() {
        let (model, _) = makeModel()
        model.saveFromMain = true
        model.exported(.success(URL(filePath: "/tmp/take.wav")))
        #expect(model.pending == nil)
        #expect(!model.saveFromMain)
        #expect(model.outcome == .saved("take.wav"))

        let (failed, _) = makeModel()
        failed.exported(.failure(CocoaError(.fileWriteNoPermission)))
        #expect(failed.pending == nil)
        if case .saveFailed = failed.outcome {} else { Issue.record("outcome \(String(describing: failed.outcome))") }
    }
}

@MainActor @Test func fileNamesAsOnTheWeb() throws {
    let c = DateComponents(year: 2026, month: 3, day: 4, hour: 5, minute: 6, second: 7)
    let date = try #require(Calendar(identifier: .gregorian).date(from: c))
    #expect(RecordingModel.fileName(date) == "pianotunah-20260304-050607.wav")
}

@MainActor @Test func clockAsOnTheWeb() {
    #expect(RecordingModel.clock(0) == "0:00")
    #expect(RecordingModel.clock(59.9) == "0:59")
    #expect(RecordingModel.clock(61) == "1:01")
    #expect(RecordingModel.clock(600) == "10:00")
}
