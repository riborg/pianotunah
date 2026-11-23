import Foundation
import Testing
@testable import PianoTunah

// The notice under the dial: a sticky one (a survey's result) stays until
// closed, and a passing one (a warning) covers it only while it shows.

@MainActor
private func makeTuner() throws -> (TunerModel, URL) {
    let dir = FileManager.default.temporaryDirectory.appending(path: "PianoTunahTests-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return (TunerModel(library: PianoLibrary(directory: dir)), dir)
}

private let result = TunerModel.Notice(text: "Survey done", kind: .ok, sticky: true)
private let warning = TunerModel.Notice(text: "Strike it again", kind: .warn)

/// Waits up to 2 s for `condition`, letting the model's timer run.
@MainActor
private func eventually(_ condition: () -> Bool) async throws -> Bool {
    for _ in 0..<200 {
        if condition() { return true }
        try await Task.sleep(for: .milliseconds(10))
    }
    return condition()
}

@MainActor @Suite struct Notices {
    @Test func aPassingNoticeGoes() async throws {
        let (tuner, dir) = try makeTuner()
        defer { try? FileManager.default.removeItem(at: dir) }
        tuner.post(warning, seconds: 0.05)
        #expect(tuner.notice == warning)
        #expect(try await eventually { tuner.notice == nil })
    }

    @Test func theSurveysResultComesBackAfterAWarning() async throws {
        let (tuner, dir) = try makeTuner()
        defer { try? FileManager.default.removeItem(at: dir) }
        tuner.post(result)
        tuner.post(warning, seconds: 0.05)
        #expect(tuner.notice == warning)
        #expect(try await eventually { tuner.notice == result })
    }

    @Test func itComesBackAfterSeveralWarnings() async throws {
        let (tuner, dir) = try makeTuner()
        defer { try? FileManager.default.removeItem(at: dir) }
        tuner.post(result)
        tuner.post(warning, seconds: 10)
        let second = TunerModel.Notice(text: "Reference set", kind: .ok)
        tuner.post(second, seconds: 0.05)
        #expect(tuner.notice == second)
        #expect(try await eventually { tuner.notice == result })
    }

    @Test func closingAWarningShowsTheResultAgain() throws {
        let (tuner, dir) = try makeTuner()
        defer { try? FileManager.default.removeItem(at: dir) }
        tuner.post(result)
        tuner.post(warning, seconds: 10)
        tuner.closeNotice()
        #expect(tuner.notice == result)
        tuner.closeNotice()
        #expect(tuner.notice == nil)
    }

    @Test func aNewResultReplacesTheOld() async throws {
        let (tuner, dir) = try makeTuner()
        defer { try? FileManager.default.removeItem(at: dir) }
        tuner.post(result)
        tuner.post(warning, seconds: 10)
        let newer = TunerModel.Notice(text: "Survey of all A done", kind: .ok, sticky: true)
        tuner.post(newer)
        tuner.post(warning, seconds: 0.05)
        #expect(try await eventually { tuner.notice == newer })
        tuner.closeNotice()
        #expect(tuner.notice == nil)
    }

    @Test func anotherPianoClearsEverything() throws {
        let (tuner, dir) = try makeTuner()
        defer { try? FileManager.default.removeItem(at: dir) }
        tuner.post(result)
        tuner.post(warning, seconds: 10)
        tuner.clearNotice()
        #expect(tuner.notice == nil)
        tuner.closeNotice()
        #expect(tuner.notice == nil)
    }
}
