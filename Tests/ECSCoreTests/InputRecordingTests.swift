import Foundation
import ECSCore
import Testing

@Suite struct InputRecordingTests {
    private let fire = InputAction("fire")
    private let throttle = InputAction("throttle", kind: .axis)
    private let move = InputAction("move", kind: .axis2D)

    // A wire-only fixture bypasses the sample encoder's validation, so decoding
    // tests exercise malformed input instead of failing during fixture creation.
    private struct SampleWire: Encodable {
        struct Entry: Encodable {
            let action: InputAction
            let value: InputValue
        }
        let values: [Entry]
        var events: [InputActionEvent] = []
        var didOverflow = false
    }

    private func decodeWire(_ wire: SampleWire) throws -> FixedInputSample {
        let encoder = JSONEncoder()
        encoder.nonConformingFloatEncodingStrategy = .convertToString(
            positiveInfinity: "inf", negativeInfinity: "-inf", nan: "nan")
        let decoder = JSONDecoder()
        decoder.nonConformingFloatDecodingStrategy = .convertFromString(
            positiveInfinity: "inf", negativeInfinity: "-inf", nan: "nan")
        return try decoder.decode(FixedInputSample.self, from: encoder.encode(wire))
    }

    private func archive(frames: [InputRecordingFrame] = []) throws -> InputRecording {
        try InputRecording(configuration: .init(stepsPerSecond: 50), initialState: Data([0, 1, 255]), frames: frames)
    }

    private func changingArchive(_ edit: (inout [String: Any]) -> Void) throws -> Data {
        let data = try archive(frames: [.init(tick: 1, input: .init())]).jsonData()
        var object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        edit(&object)
        return try JSONSerialization.data(withJSONObject: object, options: .sortedKeys)
    }

    @Test func checksumMatchesPublishedFNV1aVectors() throws {
        #expect(InputRecordingChecksum(data: Data()).rawValue == 0xcbf29ce484222325)
        #expect(InputRecordingChecksum(data: Data("a".utf8)).rawValue == 0xaf63dc4c8601ec8c)
        let hello = InputRecordingChecksum(data: Data("hello".utf8))
        #expect(hello.rawValue == 0xa430d84680aabd0b)
        #expect(hello.description == "a430d84680aabd0b")
        #expect(InputRecordingChecksum(rawValue: 1).description == "0000000000000001")
        #expect(InputRecordingChecksum(rawValue: .max).description == "ffffffffffffffff")
        #expect(Set([hello, InputRecordingChecksum(rawValue: hello.rawValue)]).count == 1)
        let copy = try JSONDecoder().decode(InputRecordingChecksum.self, from: JSONEncoder().encode(hello))
        #expect(copy == hello)
        #expect(InputRecordingChecksum(data: Data([0, 1])) != InputRecordingChecksum(data: Data([1, 0])))
    }

    @Test func emptySampleUsesKindAppropriateNeutralValues() {
        let sample = FixedInputSample()
        #expect(sample.values.isEmpty && sample.events.isEmpty && !sample.didOverflow)
        #expect(sample.value(for: fire) == .button(false))
        #expect(sample.value(for: throttle) == .axis(0))
        #expect(sample.value(for: move) == .axis2D(.zero))
    }

    @Test func sampleRoundTripPreservesHeldValuesAndExactEventOrder() throws {
        let events: [InputActionEvent] = [
            .init(action: fire, value: .button(true), phase: .pressed),
            .init(action: move, value: .axis2D([0.6, 0.8]), phase: .changed),
            .init(action: fire, value: .button(false), phase: .released),
            .init(action: fire, value: .button(true), phase: .pressed),
            .init(action: fire, value: .button(false), phase: .cancelled)
        ]
        let sample = FixedInputSample(values: [fire: .button(false), throttle: .axis(-1), move: .axis2D([0.6, 0.8])],
                                      events: events)
        let copy = try JSONDecoder().decode(FixedInputSample.self, from: JSONEncoder().encode(sample))
        #expect(copy == sample)
        #expect(copy.events == events)
        #expect(copy.wasPressed(fire) && copy.wasReleased(fire))
        #expect(Set(copy.events).count == 4)
        let cancellation = FixedInputSample(events: [.init(action: fire, value: .button(false), phase: .cancelled)])
        #expect(!cancellation.wasReleased(fire))
    }

    @Test func archiveBytesIgnoreDictionaryInsertionOrderAndSortActionIdentity() throws {
        let variants = [InputAction("a", kind: .axis, pressThreshold: 0.25),
                        InputAction("a", kind: .axis, pressThreshold: 0.75),
                        InputAction("a"), InputAction("z")]
        let values: [InputValue] = [.axis(-0.5), .axis(0.5), .button(false), .button(true)]
        var forward: [InputAction: InputValue] = [:]
        var reverse: [InputAction: InputValue] = [:]
        for index in variants.indices { forward[variants[index]] = values[index] }
        for index in variants.indices.reversed() { reverse[variants[index]] = values[index] }
        let a = try archive(frames: [.init(tick: 1, input: .init(values: forward))])
        let b = try archive(frames: [.init(tick: 1, input: .init(values: reverse))])
        #expect(try a.jsonData() == b.jsonData())
        #expect(try a.jsonData(prettyPrinted: true) == b.jsonData(prettyPrinted: true))
        let object = try #require(JSONSerialization.jsonObject(with: a.jsonData()) as? [String: Any])
        let frames = try #require(object["frames"] as? [[String: Any]])
        let input = try #require(frames.first?["input"] as? [String: Any])
        let entries = try #require(input["values"] as? [[String: Any]])
        let actions = try entries.map { try #require($0["action"] as? [String: Any]) }
        #expect(actions.compactMap { $0["name"] as? String } == ["a", "a", "a", "z"])
        #expect(actions.compactMap { $0["kind"] as? String } == ["axis", "axis", "button", "button"])
        #expect(actions.compactMap { $0["pressThreshold"] as? Double } == [0.25, 0.75, 0.5, 0.5])
    }

    @Test func decoderRejectsDuplicateHeldActionsButKeepsRepeatedEvents() throws {
        let entry = SampleWire.Entry(action: fire, value: .button(true))
        #expect(throws: InputRecordingError.invalidFrame) {
            try decodeWire(.init(values: [entry, .init(action: fire, value: .button(false))]))
        }
        let event = InputActionEvent(action: fire, value: .button(true), phase: .pressed)
        let sample = try decodeWire(.init(values: [entry], events: [event, event]))
        #expect(sample.events == [event, event])
    }

    @Test func decoderAndRecorderRejectMismatchedValueKinds() throws {
        for (action, value) in [(fire, InputValue.axis(1)), (throttle, .button(true)), (move, .axis(0))] {
            #expect(throws: InputRecordingError.invalidFrame) {
                try decodeWire(.init(values: [.init(action: action, value: value)]))
            }
            let sample = FixedInputSample(values: [action: value])
            var recorder = InputRecorder(configuration: .init(), initialState: Data())
            #expect(throws: InputRecordingError.invalidFrame) { try recorder.append(sample) }
            #expect(recorder.recording.frames.isEmpty)
            #expect(throws: InputRecordingError.invalidFrame) {
                try InputRecording(configuration: .init(), initialState: Data(), frames: [.init(tick: 1, input: sample)])
            }
        }
    }

    @Test func decoderAndRecorderRejectNonfiniteAndOutOfRangeScalars() throws {
        let invalid: [Float] = [.nan, .infinity, -.infinity, -1.001, 1.001]
        for value in invalid {
            #expect(throws: InputRecordingError.invalidFrame) {
                try decodeWire(.init(values: [.init(action: throttle, value: .axis(value))]))
            }
            var recorder = InputRecorder(configuration: .init(), initialState: Data())
            #expect(throws: InputRecordingError.invalidFrame) {
                try recorder.append(.init(values: [throttle: .axis(value)]))
            }
        }
    }

    @Test func decoderAndRecorderRejectNonfiniteAndUnnormalizedVectors() throws {
        let invalid: [SIMD2<Float>] = [[.nan, 0], [0, .infinity], [-.infinity, 0], [1.001, 0], [0, -1.001], [1, 1]]
        for vector in invalid {
            #expect(throws: InputRecordingError.invalidFrame) {
                try decodeWire(.init(values: [.init(action: move, value: .axis2D(vector))]))
            }
            var recorder = InputRecorder(configuration: .init(), initialState: Data())
            #expect(throws: InputRecordingError.invalidFrame) {
                try recorder.append(.init(values: [move: .axis2D(vector)]))
            }
        }
        let diagonal = Float(1) / Float(2).squareRoot()
        let valid = try decodeWire(.init(values: [.init(action: move, value: .axis2D([diagonal, diagonal]))]))
        #expect(valid.value(for: move) == .axis2D([diagonal, diagonal]))
    }

    @Test func validationIncludesEventsAbsentFromHeldValues() throws {
        for event in [InputActionEvent(action: fire, value: .axis(0), phase: .pressed),
                      .init(action: throttle, value: .axis(.nan), phase: .changed),
                      .init(action: move, value: .axis2D([1, 1]), phase: .cancelled)] {
            #expect(throws: InputRecordingError.invalidFrame) { try decodeWire(.init(values: [], events: [event])) }
            var recorder = InputRecorder(configuration: .init(), initialState: Data())
            #expect(throws: InputRecordingError.invalidFrame) { try recorder.append(.init(events: [event])) }
        }
    }

    @Test func nonthrowingSampleInitializerDoesNotRepairInvalidInput() throws {
        let sample = FixedInputSample(values: [throttle: .axis(2)], didOverflow: true)
        #expect(sample.value(for: throttle) == .axis(2))
        #expect(sample.didOverflow)
        #expect(throws: InputRecordingError.invalidFrame) { try JSONEncoder().encode(sample) }
    }

    @Test func sampleCanPreserveOverflowDiagnosticButArchiveRejectsIt() throws {
        let sample = FixedInputSample(values: [fire: .button(true)], didOverflow: true)
        let copy = try JSONDecoder().decode(FixedInputSample.self, from: JSONEncoder().encode(sample))
        #expect(copy == sample)
        #expect(throws: InputRecordingError.inputOverflow) {
            try InputRecording(configuration: .init(), initialState: Data(), frames: [.init(tick: 1, input: copy)])
        }
        var recorder = InputRecorder(configuration: .init(), initialState: Data())
        #expect(throws: InputRecordingError.inputOverflow) { try recorder.append(copy) }
        #expect(recorder.recording.frames.isEmpty)
    }

    @Test func archiveRoundTripKeepsConfigurationStateChecksumsAndDuration() throws {
        let checksum = InputRecordingChecksum(rawValue: .max)
        let original = try archive(frames: [
            .init(tick: 1, input: .init(values: [fire: .button(true)]), checksum: checksum),
            .init(tick: 2, input: .init())
        ])
        #expect(original.version == 1)
        #expect(original.duration == 0.04)
        #expect(try InputRecording(data: original.jsonData()) == original)
        #expect(try InputRecording(data: original.jsonData(prettyPrinted: true)) == original)
        #expect(try JSONDecoder().decode(InputRecording.self, from: JSONEncoder().encode(original)) == original)
        #expect(original.frames[1].checksum == nil)
    }

    @Test func emptyStateAndEmptyArchiveAreValid() throws {
        let recording = try InputRecording(configuration: .init(), initialState: Data())
        #expect(recording.duration == 0)
        #expect(recording.frames.isEmpty && recording.initialState.isEmpty)
        #expect(try InputRecording(data: recording.jsonData()) == recording)
    }

    @Test func archiveRequiresExactlyConsecutiveRelativeTicks() throws {
        let sequences: [[UInt64]] = [[0], [2], [1, 1], [1, 3], [2, 1], [1, .max]]
        for ticks in sequences {
            #expect(throws: InputRecordingError.invalidFrame) {
                try archive(frames: ticks.map { .init(tick: $0, input: .init()) })
            }
        }
    }

    @Test func archiveRejectsUnsupportedVersionBeforeReadingFrames() throws {
        for version in [0, -1, 2, Int.max] {
            let data = try JSONSerialization.data(withJSONObject: ["version": version])
            #expect(throws: InputRecordingError.unsupportedVersion(version)) { try InputRecording(data: data) }
            #expect(throws: InputRecordingError.unsupportedVersion(version)) {
                try JSONDecoder().decode(InputRecording.self, from: data)
            }
        }
    }

    @Test func malformedArchiveHasTypedFormatError() throws {
        let malformed = [Data(), Data("no JSON".utf8), Data("[]".utf8), Data("{}".utf8),
                         try changingArchive { $0.removeValue(forKey: "configuration") },
                         try changingArchive { $0["initialState"] = "!not-base64!" },
                         try changingArchive { $0["frames"] = "wrong type" }]
        for data in malformed {
            #expect(throws: InputRecordingError.invalidFormat) { try InputRecording(data: data) }
        }
    }

    @Test func archiveDecoderCannotBypassTickOrOverflowValidation() throws {
        let badTick = try changingArchive { object in
            var frames = object["frames"] as! [[String: Any]]
            frames[0]["tick"] = 0
            object["frames"] = frames
        }
        #expect(throws: InputRecordingError.invalidFrame) { try InputRecording(data: badTick) }
        let overflow = try changingArchive { object in
            var frames = object["frames"] as! [[String: Any]]
            var input = frames[0]["input"] as! [String: Any]
            input["didOverflow"] = true
            frames[0]["input"] = input
            object["frames"] = frames
        }
        #expect(throws: InputRecordingError.inputOverflow) { try InputRecording(data: overflow) }
    }

    @Test func fileRoundTripAndMalformedFileUseTheSameValidation() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("input-recording-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        let recording = try archive(frames: [.init(tick: 1, input: .init())])
        try recording.write(to: url)
        #expect(try InputRecording(contentsOf: url) == recording)
        #expect(try Data(contentsOf: url) == recording.jsonData())
        try Data("{}".utf8).write(to: url)
        #expect(throws: InputRecordingError.invalidFormat) { try InputRecording(contentsOf: url) }
    }

    @Test func recorderAssignsRelativeTicksAndKeepsFrozenSnapshots() throws {
        var state = Data([1, 2, 3])
        var values: [InputAction: InputValue] = [fire: .button(true)]
        var events = [InputActionEvent(action: fire, value: .button(true), phase: .pressed)]
        let sample = FixedInputSample(values: values, events: events)
        var recorder = InputRecorder(configuration: .init(stepsPerSecond: 20), initialState: state)
        let empty = recorder.recording
        state[0] = 99
        values[fire] = .button(false)
        events.removeAll()
        let checksum = InputRecordingChecksum(data: Data([9]))
        try recorder.append(sample, checksum: checksum)
        let first = recorder.recording
        var independent = recorder
        try recorder.append(.init())
        try independent.append(.init(values: [throttle: .axis(0.5)]))
        #expect(empty.frames.isEmpty)
        #expect(first.frames.count == 1)
        #expect(first.frames[0].input.value(for: fire) == .button(true))
        #expect(first.frames[0].input.events.count == 1)
        #expect(first.frames[0].checksum == checksum)
        #expect(first.initialState == Data([1, 2, 3]))
        #expect(recorder.recording.frames.map(\.tick) == [1, 2])
        #expect(recorder.recording.duration == 0.1)
        #expect(independent.recording.frames[1].input.value(for: throttle) == .axis(0.5))
        #expect(recorder.recording.frames[1].input.values.isEmpty)
    }

    @Test func rejectedAppendsDoNotDropFramesOrAdvanceTicks() throws {
        var recorder = InputRecorder(configuration: .init(), initialState: Data(), maximumFrames: 2)
        try recorder.append(.init(values: [fire: .button(true)]))
        let before = recorder.recording
        #expect(throws: InputRecordingError.inputOverflow) { try recorder.append(.init(didOverflow: true)) }
        #expect(recorder.recording == before)
        #expect(throws: InputRecordingError.invalidFrame) { try recorder.append(.init(values: [move: .axis(0)])) }
        #expect(recorder.recording == before)
        try recorder.append(.init())
        let full = recorder.recording
        #expect(throws: InputRecordingError.frameLimitReached) { try recorder.append(.init()) }
        #expect(recorder.recording == full)
        #expect(full.frames.map(\.tick) == [1, 2])
    }

    @Test func recorderCapacityClampsAtBothBounds() throws {
        for requested in [Int.min, -1, 0, 1] {
            var recorder = InputRecorder(configuration: .init(), initialState: Data(), maximumFrames: requested)
            #expect(recorder.maximumFrames == 1)
            try recorder.append(.init())
            #expect(throws: InputRecordingError.frameLimitReached) { try recorder.append(.init()) }
            #expect(recorder.recording.frames.count == 1)
        }
        #expect(InputRecorder(configuration: .init(), initialState: Data()).maximumFrames == 36_000)
        for requested in [1_000_000, 1_000_001, Int.max] {
            #expect(InputRecorder(configuration: .init(), initialState: Data(), maximumFrames: requested).maximumFrames == 1_000_000)
        }
    }

    @MainActor @Test func bufferingStillConsumesEdgesOnceAndRetainsHeldValues() throws {
        let input = InputController(contexts: [.init(name: "test", bindings: [.init(fire, control: .key("space"))])])
        let buffer = FixedInputBuffer(input: input)
        var recorder = InputRecorder(configuration: .init(), initialState: Data())
        input.setValue(.button(true), for: .key("space"), device: .keyboard)
        try recorder.append(buffer.consume())
        try recorder.append(buffer.consume())
        #expect(recorder.recording.frames[0].input.events.map(\.phase) == [.pressed])
        #expect(recorder.recording.frames[1].input.events.isEmpty)
        #expect(recorder.recording.frames[1].input.value(for: fire) == .button(true))
        input.cancelAll()
        let cancelled = buffer.consume()
        #expect(cancelled.events.map(\.phase) == [.cancelled])
        #expect(cancelled.value(for: fire) == .button(false))
        #expect(!cancelled.wasPressed(fire) && !cancelled.wasReleased(fire))
        #expect(recorder.recording.frames[0].input.value(for: fire) == .button(true))
    }
}
