import Foundation
import Testing

@Test func everyFixtureDecodes() throws {
    let files = try Fixtures.allFiles()
    #expect(files.contains("jsround.json"))
    #expect(files.filter { $0.hasSuffix(".json") }.count >= 16)
    for file in files {
        if file.hasSuffix(".json") {
            let value = try Fixtures.json(file)
            #expect(value.object?.isEmpty == false, "\(file) is not a JSON object")
        } else if file.hasSuffix(".f32") {
            let samples = try Fixtures.f32(file)
            #expect(!samples.isEmpty && samples.allSatisfy(\.isFinite), "\(file)")
            #expect(samples.allSatisfy { abs($0) < 16 }, "\(file) does not look like Float32 sound")
        } else {
            Issue.record("unexpected fixture \(file)")
        }
    }
}

@Test func soundFilesMatchDspJson() throws {
    let dsp = try Fixtures.json("dsp.json")
    let referenced = (dsp["sounds"].array ?? []) + (dsp["beatMeter"].array ?? [])
    #expect(referenced.count >= 10)
    for entry in referenced {
        let file = try #require(entry["file"].string)
        let samples = try Fixtures.f32("dsp/" + file)
        #expect(samples.count == entry["length"].int, "\(file)")
    }
    let names = Set(referenced.compactMap { $0["file"].string })
    let onDisk = Set(try Fixtures.allFiles().filter { $0.hasPrefix("dsp/") }.map { String($0.dropFirst(4)) })
    #expect(names == onDisk, "every sound in dsp/ is described in dsp.json")
}

@Test func numbersDecodeExactly() throws {
    let cases = try #require(try Fixtures.json("jsround.json")["cases"].array)
    let xs = cases.compactMap { $0["x"].double }
    #expect(xs.contains(0.49999999999999994))
    #expect(xs.contains(Double.leastNonzeroMagnitude))
    #expect(xs.contains(Double.greatestFiniteMagnitude))
    #expect(xs.contains { $0 == 0 && $0.sign == .minus })
    #expect(xs.contains { $0.isNaN })
}

@Test func pianoDocumentsDecode() throws {
    for which in ["a", "b", "c"] {
        let input = try Fixtures.json("piano/\(which).input.json")
        let expected = try Fixtures.json("piano/\(which).normalized.json")
        #expect(input["id"].string == expected["normalized"]["id"].string)
        #expect(expected["normalized"]["settings"]["unisons"].string != nil)
    }
}
