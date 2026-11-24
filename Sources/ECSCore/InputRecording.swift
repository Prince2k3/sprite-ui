import Foundation

/// A deterministic FNV-1a 64-bit diagnostic of application-selected state bytes.
/// This is not a cryptographic hash or an automatic world determinism guarantee.
public struct InputRecordingChecksum: RawRepresentable, Hashable, Codable, Sendable, CustomStringConvertible {
    /// The complete unsigned checksum bits.
    public let rawValue: UInt64

    /// Wraps a previously computed checksum.
    public init(rawValue: UInt64) { self.rawValue = rawValue }

    /// Hashes bytes in order using FNV-1a with wrapping 64-bit multiplication.
    public init(data: Data) {
        var hash: UInt64 = 0xcbf29ce484222325
        for byte in data {
            hash ^= UInt64(byte)
            hash &*= 0x100000001b3
        }
        rawValue = hash
    }

    /// Sixteen lowercase hexadecimal digits, including leading zeroes.
    public var description: String {
        let hex = String(rawValue, radix: 16)
        return String(repeating: "0", count: 16 - hex.count) + hex
    }
}

/// Input for one archive-relative tick, independent of the world's lifetime tick.
public struct InputRecordingFrame: Codable, Equatable, Sendable {
    /// A one-based tick; archives require exactly 1...frame count in order.
    public let tick: UInt64
    /// The frozen held values and ordered transitions used by this tick.
    public let input: FixedInputSample
    /// Optional diagnostic computed after application rules complete the tick.
    public let checksum: InputRecordingChecksum?

    /// Creates a frame. Its archive validates tick order and input when admitted.
    public init(tick: UInt64, input: FixedInputSample, checksum: InputRecordingChecksum? = nil) {
        self.tick = tick
        self.input = input
        self.checksum = checksum
    }
}

/// A validation or capacity failure while reading or capturing fixed input.
public enum InputRecordingError: Error, Equatable, Sendable, LocalizedError {
    /// The bytes do not contain the required recording structure.
    case invalidFormat
    /// The archive uses an unsupported format version.
    case unsupportedVersion(Int)
    /// A tick is out of order, or a value has an invalid kind or normalized range.
    case invalidFrame
    /// The input buffer dropped transitions, so the tick cannot be recorded faithfully.
    case inputOverflow
    /// The recorder reached its configured capacity without discarding earlier frames.
    case frameLimitReached

    /// A human-readable explanation of the failure.
    public var errorDescription: String? {
        switch self {
        case .invalidFormat: "Invalid input recording format."
        case .unsupportedVersion(let version): "Unsupported input recording version: \(version)."
        case .invalidFrame: "Invalid input recording frame."
        case .inputOverflow: "Input transitions overflowed before recording."
        case .frameLimitReached: "Input recording frame limit reached."
        }
    }
}

/// An immutable version-one archive for replaying caller-owned fixed simulation rules.
/// Initial state is opaque provider-owned data and may be empty. Root resources and
/// native physics are not implicitly captured or made deterministic by this format.
public struct InputRecording: Codable, Equatable, Sendable {
    /// The archive's format version, currently one.
    public let version: Int
    /// The cadence used to interpret every recorded tick.
    public let configuration: FixedStepConfiguration
    /// Frozen state bytes supplied by the application before the first tick.
    public let initialState: Data
    /// Validated consecutive frames, starting at relative tick one.
    public let frames: [InputRecordingFrame]

    /// Validates every frame without changing input, event order, or state bytes.
    public init(configuration: FixedStepConfiguration, initialState: Data, frames: [InputRecordingFrame] = []) throws {
        for (index, frame) in frames.enumerated() {
            guard frame.tick == UInt64(index) + 1 else { throw InputRecordingError.invalidFrame }
            guard !frame.input.didOverflow else { throw InputRecordingError.inputOverflow }
            try frame.input.validate()
        }
        self.init(validatedConfiguration: configuration, initialState: initialState, frames: frames)
    }

    // Only the validating initializer and recorder's validated append path use this.
    fileprivate init(validatedConfiguration: FixedStepConfiguration, initialState: Data, frames: [InputRecordingFrame]) {
        version = 1
        configuration = validatedConfiguration
        self.initialState = initialState
        self.frames = frames
    }

    /// Simulation seconds represented by completed frames, excluding playback speed.
    public var duration: TimeInterval { Double(frames.count) * configuration.stepDuration }

    private enum CodingKeys: String, CodingKey { case version, configuration, initialState, frames }

    /// Decodes and validates the version and all frames, including for direct Codable use.
    public init(from decoder: any Decoder) throws {
        do {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            let version = try container.decode(Int.self, forKey: .version)
            guard version == 1 else { throw InputRecordingError.unsupportedVersion(version) }
            try self.init(configuration: container.decode(FixedStepConfiguration.self, forKey: .configuration),
                          initialState: container.decode(Data.self, forKey: .initialState),
                          frames: container.decode([InputRecordingFrame].self, forKey: .frames))
        } catch let error as InputRecordingError {
            throw error
        } catch {
            throw InputRecordingError.invalidFormat
        }
    }

    /// Reads JSON produced by ``jsonData(prettyPrinted:)`` and validates its contents.
    public init(data: Data) throws {
        do { self = try JSONDecoder().decode(Self.self, from: data) }
        catch let error as InputRecordingError { throw error }
        catch { throw InputRecordingError.invalidFormat }
    }

    /// Reads and validates an archive from a file, preserving file access errors.
    public init(contentsOf url: URL) throws {
        try self.init(data: Data(contentsOf: url))
    }

    /// JSON with sorted object keys and action entries for stable archive bytes.
    public func jsonData(prettyPrinted: Bool = false) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = prettyPrinted ? [.sortedKeys, .prettyPrinted] : [.sortedKeys]
        return try encoder.encode(self)
    }

    /// Atomically writes the archive as JSON.
    public func write(to url: URL) throws {
        try jsonData().write(to: url, options: .atomic)
    }
}

/// Collects validated fixed input without dropping or overwriting completed frames.
public struct InputRecorder: Sendable {
    private let configuration: FixedStepConfiguration
    private let initialState: Data
    /// The effective capacity after clamping to 1...1,000,000 frames.
    public let maximumFrames: Int
    private var frames: [InputRecordingFrame] = []

    /// Freezes initial state and configuration. Capacity is clamped to 1...1,000,000.
    public init(configuration: FixedStepConfiguration, initialState: Data, maximumFrames: Int = 36_000) {
        self.configuration = configuration
        self.initialState = initialState
        self.maximumFrames = min(max(maximumFrames, 1), 1_000_000)
    }

    /// Appends the next relative tick, or throws without changing the archive.
    /// Overflowed samples and invalid values are never silently repaired.
    public mutating func append(_ sample: FixedInputSample, checksum: InputRecordingChecksum? = nil) throws {
        guard !sample.didOverflow else { throw InputRecordingError.inputOverflow }
        try sample.validate()
        guard frames.count < maximumFrames else { throw InputRecordingError.frameLimitReached }
        frames.append(InputRecordingFrame(tick: UInt64(frames.count) + 1, input: sample, checksum: checksum))
    }

    /// An immutable value snapshot that remains unchanged by subsequent appends.
    public var recording: InputRecording {
        InputRecording(validatedConfiguration: configuration, initialState: initialState, frames: frames)
    }
}
