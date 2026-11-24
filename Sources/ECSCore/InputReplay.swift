import Foundation
import Observation

/// A rejected replay operation or an invalid caller-owned fixed tick.
public enum InputReplayError: Error, Equatable, Sendable, LocalizedError {
    /// The weakly held world was destroyed.
    case worldUnavailable
    /// The current mode does not support this control.
    case invalidState
    /// A provider, system, or unfinished frame attempted a lifecycle mutation.
    case reentrantOperation
    /// The context is not this world's currently running fixed simulation tick.
    case invalidContext
    /// The world's fixed configuration differs from the recording metadata.
    case configurationChanged
    /// The owning system did not sample a consecutive lifetime tick.
    case skippedTick
    /// A prepared tick was interrupted or never marked ready to commit.
    case incompleteTick
    /// A speed is nonfinite or outside the inclusive 0.1...4 range.
    case invalidPlaybackSpeed
    /// The world cannot currently run one paused fixed tick.
    case stepUnavailable
    /// A checksummed archive was supplied without a checksum provider.
    case checksumUnavailable
    /// Another controller holds this world's recording or playback lease.
    case worldInUse

    /// A human-readable explanation of the rejected operation.
    public var errorDescription: String? {
        switch self {
        case .worldUnavailable: "The replay world is no longer available."
        case .invalidState: "This operation is unavailable in the current replay state."
        case .reentrantOperation: "Replay controls cannot change during a frame or another replay operation."
        case .invalidContext: "Replay input requires the owning world's current fixed simulation context."
        case .configurationChanged: "The fixed simulation clock changed during replay."
        case .skippedTick: "A fixed tick was skipped by the replay owner."
        case .incompleteTick: "The fixed tick was interrupted or was not finished by its owner."
        case .invalidPlaybackSpeed: "Playback speed must be finite and between 0.1 and 4."
        case .stepUnavailable: "The paused world could not advance one fixed tick."
        case .checksumUnavailable: "This recording requires a checksum provider."
        case .worldInUse: "Another replay controller already owns this world."
        }
    }
}

/// Replays application-owned fixed rules. Call `sample(for:)` before those rules
/// and `finishTick(_:)` after them. Finishing queues a commit: checksums and archive
/// changes occur after ALL fixed systems and transform capture finish successfully.
/// Native physics, actions, pixels, and entity IDs are not determinism guarantees.
/// This runtime object is intentionally not a Codable component or snapshot value.
@MainActor @Observable
public final class InputReplayController {
    /// The current input source and replay lifecycle.
    public enum State: String, Sendable {
        /// Samples the live input buffer without creating an archive.
        case live
        /// Captures completed custom fixed ticks into a new archive.
        case recording
        /// Supplies recorded input while the world advances normally.
        case playing
        /// Holds playback for an explicit play or single-step control.
        case paused
        /// All recorded frames completed; input stays suppressed until stop.
        case finished
        /// A completed tick produced a different selected-state checksum.
        case diverged
        /// A provider or tick contract failed; the world remains paused.
        case failed
    }

    /// The first mismatching checksum, expressed in archive-relative ticks.
    public struct Divergence: Equatable, Sendable {
        /// One-based archive-relative tick, never the world's lifetime tick.
        public let tick: UInt64
        /// The diagnostic saved after the original completed tick.
        public let expected: InputRecordingChecksum
        /// The diagnostic produced after the corresponding playback tick.
        public let actual: InputRecordingChecksum
    }

    /// The observable mode. Terminal playback states retain ownership until stop.
    public private(set) var state: State = .live
    /// The first checksum mismatch, cleared when starting a new session.
    public private(set) var divergence: Divergence?
    /// Preserves the original provider, recording, or controller error.
    public private(set) var lastError: (any Error)?
    /// Number of committed frames in the active recording or loaded archive.
    public private(set) var recordedFrameCount = 0
    /// Number of frames completed in this recording or playback session.
    public private(set) var frameIndex = 0
    /// Completed frames only. Reading this value produces an immutable archive.
    public var recording: InputRecording? { recorder?.recording ?? archive }

    /// Invalid assignments leave the speed unchanged and set `lastError`.
    /// Use `setPlaybackSpeed(_:)` when a throwing control is preferable.
    public var playbackSpeed: Double {
        get { storedPlaybackSpeed }
        set {
            do { try setPlaybackSpeed(newValue) }
            catch { lastError = error }
        }
    }

    @ObservationIgnored private weak var world: World?
    @ObservationIgnored private let input: InputController
    @ObservationIgnored private let buffer: FixedInputBuffer
    @ObservationIgnored private let maximumFrames: Int
    @ObservationIgnored private let captureState: @MainActor () throws -> Data
    @ObservationIgnored private let restoreState: @MainActor (Data) throws -> Void
    @ObservationIgnored private let checksum: (@MainActor () throws -> Data)?
    @ObservationIgnored private let suppressionOwner = UUID()
    @ObservationIgnored private var holdsSuppression = false
    private var recorder: InputRecorder?
    private var archive: InputRecording?
    private var storedPlaybackSpeed: Double = 1
    @ObservationIgnored private var configuration: FixedStepConfiguration?
    @ObservationIgnored private var clockEpoch: UInt64 = 0
    @ObservationIgnored private var lastCompletedTick: UInt64 = 0
    @ObservationIgnored private var pending: PendingTick?
    @ObservationIgnored private var cachedTick: UInt64?
    @ObservationIgnored private var cachedSample: FixedInputSample?
    @ObservationIgnored private var priorClock: ClockPreferences?
    @ObservationIgnored private var isMutating = false
    @ObservationIgnored private var isStepping = false
    @ObservationIgnored private var isCompleting = false

    private struct PendingTick {
        let tick: UInt64
        let epoch: UInt64
        let sample: FixedInputSample
        var ready = false
    }
    private struct ClockPreferences {
        let configuration: FixedStepConfiguration?
        let isPaused: Bool
        let timeScale: Double
    }

    /// Providers own the state format, including any application root resources.
    /// Capture and restore run outside world updates. Providers should capture the
    /// world weakly when this controller is retained by a world resource.
    public init(world: World, input: InputController, maximumFrames: Int = 36_000,
                captureState: @escaping @MainActor () throws -> Data,
                restoreState: @escaping @MainActor (Data) throws -> Void,
                checksum: (@MainActor () throws -> Data)? = nil) {
        self.world = world
        self.input = input
        self.buffer = FixedInputBuffer(input: input)
        self.maximumFrames = min(max(maximumFrames, 1), 1_000_000)
        self.captureState = captureState
        self.restoreState = restoreState
        self.checksum = checksum
    }

    isolated deinit {
        if world?.inputReplayOwner === self { world?.inputReplayOwner = nil }
        if holdsSuppression { input.setInputSuppressed(false, owner: suppressionOwner) }
    }

    /// Captures frozen provider state and fixed-rate metadata at a quiescent
    /// boundary. Existing lifetime ticks are retained; archive ticks start at one.
    /// Throws if another controller owns the world or capture fails.
    public func startRecording() throws {
        let world = try beginMutation()
        defer { isMutating = false }
        guard state == .live else { throw InputReplayError.invalidState }
        guard let configuration = world.fixedStep else { throw InputReplayError.configurationChanged }
        try acquireWorld(world)
        saveClock(world)
        let tick = world.fixedStepState.tick
        let epoch = world.fixedStepEpoch
        do {
            let initialState = try captureState()
            guard world.fixedStepState.tick == tick, world.fixedStepEpoch == epoch,
                  world.fixedStep == configuration else { throw InputReplayError.configurationChanged }
            recorder = InputRecorder(configuration: configuration, initialState: initialState,
                                     maximumFrames: maximumFrames)
            archive = nil
            resetSession(world, configuration: configuration)
            recordedFrameCount = 0
            state = .recording
        } catch {
            fail(error)
            throw error
        }
    }

    /// Restores provider state even for an empty archive, applies its fixed-rate
    /// metadata, and suppresses live input. Must run outside an unfinished frame.
    /// Empty archives finish immediately. Provider errors leave entities under the
    /// provider's control and pause the world; stop releases the session lease.
    public func startPlayback(_ recording: InputRecording, paused: Bool = false) throws {
        let world = try beginMutation()
        defer { isMutating = false }
        guard state == .live else { throw InputReplayError.invalidState }
        // Validate before providers can destructively restore state.
        _ = try InputRecording(configuration: recording.configuration, initialState: recording.initialState,
                               frames: recording.frames)
        guard checksum != nil || !recording.frames.contains(where: { $0.checksum != nil }) else {
            throw InputReplayError.checksumUnavailable
        }
        try acquireWorld(world)
        saveClock(world)
        do {
            world.isPaused = true
            holdsSuppression = true
            input.setInputSuppressed(true, owner: suppressionOwner)
            let tick = world.fixedStepState.tick
            try restoreState(recording.initialState)
            guard world.fixedStepState.tick == tick else { throw InputReplayError.skippedTick }
            world.fixedStep = recording.configuration
            world.timeScale = storedPlaybackSpeed
            world.resetFixedStepClock()
            archive = recording
            recorder = nil
            resetSession(world, configuration: recording.configuration)
            recordedFrameCount = recording.frames.count
            state = recording.frames.isEmpty ? .finished : (paused ? .paused : .playing)
            world.isPaused = state != .playing
            clockEpoch = world.fixedStepEpoch
        } catch {
            fail(error)
            throw error
        }
    }

    /// Resumes paused playback at the selected speed, between completed frames.
    public func play() throws {
        let world = try beginMutation()
        defer { isMutating = false }
        guard state == .paused else { throw InputReplayError.invalidState }
        try validateSession(world)
        world.timeScale = storedPlaybackSpeed
        world.isPaused = false
        clockEpoch = world.fixedStepEpoch
        state = .playing
    }

    /// Pauses playback at a quiescent boundary without changing archive bytes.
    public func pause() throws {
        let world = try beginMutation()
        defer { isMutating = false }
        guard state == .playing || state == .paused else { throw InputReplayError.invalidState }
        try validateSession(world)
        world.isPaused = true
        clockEpoch = world.fixedStepEpoch
        state = .paused
    }

    /// Validates a finite 0.1...4 multiplier. Active playback applies it to the
    /// world's time scale; fixed-rate metadata and input samples stay unchanged.
    public func setPlaybackSpeed(_ speed: Double) throws {
        let world = try beginMutation()
        defer { isMutating = false }
        guard speed.isFinite, (0.1...4).contains(speed) else { throw InputReplayError.invalidPlaybackSpeed }
        if state == .playing || state == .paused {
            try validateSession(world)
            world.timeScale = speed
            clockEpoch = world.fixedStepEpoch
        }
        storedPlaybackSpeed = speed
    }

    /// Runs one paused custom fixed tick at 1×, including later fixed systems.
    /// Does not advance variable systems or native physics, rewind lifetime ticks,
    /// or change the archive. Must run outside an unfinished frame or provider.
    public func step() throws {
        let world = try beginMutation()
        defer { isMutating = false; isStepping = false }
        guard state == .paused else { throw InputReplayError.invalidState }
        try validateSession(world)
        guard world.isPaused, world.root.isActive else { throw InputReplayError.stepUnavailable }
        // The world's single-step entry resets its clock before invoking systems.
        clockEpoch = world.fixedStepEpoch &+ 1
        isStepping = true
        guard world.stepFixedSimulation() else {
            clockEpoch = world.fixedStepEpoch
            throw InputReplayError.stepUnavailable
        }
        if state == .failed { throw lastError ?? InputReplayError.incompleteTick }
        guard pending == nil, lastCompletedTick == world.fixedStepState.tick else {
            let error = InputReplayError.incompleteTick
            fail(error)
            throw error
        }
    }

    /// Finalizes recording, restores clock preferences, and releases live input
    /// through its neutral gates. Playback does not restore the earlier live world.
    public func stop() throws {
        let world = try beginMutation()
        defer { isMutating = false }
        guard state != .live else { return }
        var validationError: (any Error)?
        if state == .recording || state == .playing || state == .paused {
            do { try validateSession(world) }
            catch { validationError = error }
        }
        if let recorder { archive = recorder.recording }
        recorder = nil
        pending = nil
        cachedTick = nil
        cachedSample = nil
        configuration = nil
        state = .live
        if let priorClock {
            world.fixedStep = priorClock.configuration
            world.timeScale = priorClock.timeScale
            world.isPaused = priorClock.isPaused
            world.resetFixedStepClock()
        }
        priorClock = nil
        if world.inputReplayOwner === self { world.inputReplayOwner = nil }
        if holdsSuppression {
            holdsSuppression = false
            input.setInputSuppressed(false, owner: suppressionOwner)
        } else {
            input.cancelAll()
        }
        buffer.reset()
        if let validationError { throw validationError }
    }

    /// Repeated calls in the same fixed tick return the same frozen sample.
    /// Only `.finished` returns neutral input after playback ends; paused,
    /// diverged, and failed sessions reject sampling outside an explicit step.
    public func sample(for context: UpdateContext) throws -> FixedInputSample {
        do {
            let world = try validateContext(context)
            guard !isCompleting, !isMutating || isStepping else { throw InputReplayError.reentrantOperation }
            if state == .finished { return FixedInputSample() }
            guard state == .live || state == .recording || state == .playing || (state == .paused && isStepping) else {
                throw InputReplayError.invalidState
            }
            if state != .live { try validateTickClock(world, atTickStart: true) }
            let tick = world.fixedStepState.tick
            if cachedTick == tick, let cachedSample { return cachedSample }
            guard pending == nil else { throw InputReplayError.incompleteTick }
            if state != .live {
                guard lastCompletedTick < UInt64.max, tick == lastCompletedTick + 1 else {
                    throw InputReplayError.skippedTick
                }
            }
            let sample: FixedInputSample
            if state == .playing || state == .paused {
                guard let archive, frameIndex < archive.frames.count else { throw InputReplayError.skippedTick }
                sample = archive.frames[frameIndex].input
            } else {
                sample = buffer.consume()
            }
            if state == .recording {
                guard !sample.didOverflow else { throw InputRecordingError.inputOverflow }
                try sample.validate()
                guard recorder != nil, recordedFrameCount < maximumFrames else {
                    throw InputRecordingError.frameLimitReached
                }
            }
            pending = PendingTick(tick: tick, epoch: world.fixedStepEpoch, sample: sample)
            cachedTick = tick
            cachedSample = sample
            world.fixedTickCompletions.append { [weak self] completed in
                self?.completeTick(tick: tick, completed: completed)
            }
            return sample
        } catch {
            if state == .recording || state == .playing || state == .paused { fail(error) }
            throw error
        }
    }

    /// Marks this owner's rules ready. The end-of-tick callback performs the
    /// actual checksum, append, comparison, and EOF pause after later systems.
    public func finishTick(_ context: UpdateContext) throws {
        do {
            let world = try validateContext(context)
            guard !isCompleting, !isMutating || isStepping else { throw InputReplayError.reentrantOperation }
            if state == .finished { return }
            guard state == .live || state == .recording || state == .playing || (state == .paused && isStepping) else {
                throw InputReplayError.invalidState
            }
            guard let pending, pending.tick == context.fixedTick, !pending.ready else {
                throw InputReplayError.incompleteTick
            }
            guard pending.epoch == world.fixedStepEpoch else { throw InputReplayError.incompleteTick }
            if state != .live { try validateTickClock(world) }
            self.pending?.ready = true
        } catch {
            if state == .recording || state == .playing || state == .paused { fail(error) }
            throw error
        }
    }

    private func completeTick(tick: UInt64, completed: Bool) {
        guard let pending, pending.tick == tick else { return }
        if state == .live {
            self.pending = nil
            return
        }
        guard state == .recording || state == .playing || state == .paused else { return }
        isCompleting = true
        defer { isCompleting = false }
        do {
            guard completed, pending.ready, let world,
                  world.fixedStepState.tick == tick, world.fixedStepEpoch == pending.epoch else {
                throw InputReplayError.incompleteTick
            }
            try validateTickClock(world)
            let actual = try checksum.map { InputRecordingChecksum(data: try $0()) }
            // Providers may synchronously change the world or reenter public APIs.
            guard state != .failed, world.fixedStepEpoch == pending.epoch,
                  world.root.isActive, world.fixedStep == configuration else {
                throw InputReplayError.incompleteTick
            }
            if state == .recording {
                try recorder?.append(pending.sample, checksum: actual)
                recordedFrameCount += 1
            } else {
                guard let archive, frameIndex < archive.frames.count else { throw InputReplayError.skippedTick }
                let frame = archive.frames[frameIndex]
                if let expected = frame.checksum {
                    guard let actual else { throw InputReplayError.checksumUnavailable }
                    if expected != actual {
                        divergence = Divergence(tick: frame.tick, expected: expected, actual: actual)
                        self.pending = nil
                        lastCompletedTick = tick
                        state = .diverged
                        world.isPaused = true
                        clockEpoch = world.fixedStepEpoch
                        return
                    }
                }
            }
            frameIndex += 1
            lastCompletedTick = tick
            self.pending = nil
            if state != .recording, frameIndex == archive?.frames.count {
                state = .finished
                world.isPaused = true
                clockEpoch = world.fixedStepEpoch
            }
        } catch { fail(error) }
    }

    private func beginMutation() throws -> World {
        guard !isMutating, !isCompleting else { throw InputReplayError.reentrantOperation }
        guard let world else { throw InputReplayError.worldUnavailable }
        guard !world.isRunningSystems, !world.isFixedUpdating, !world.isDebugStepping,
              world.activeFrameCompletion?.finished != false else { throw InputReplayError.reentrantOperation }
        isMutating = true
        return world
    }

    private func validateContext(_ context: UpdateContext) throws -> World {
        guard let world else { throw InputReplayError.worldUnavailable }
        guard context.world === world, context.phase == .fixedSimulation,
              world.isRunningSystems, world.isFixedUpdating, world.root.isActive,
              let configuration = world.fixedStep, let tick = context.fixedTick,
              tick == world.fixedStepState.tick, context.deltaTime == configuration.stepDuration else {
            throw InputReplayError.invalidContext
        }
        return world
    }

    private func validateTickClock(_ world: World, atTickStart: Bool = false) throws {
        guard world.fixedStep == configuration else {
            throw InputReplayError.configurationChanged
        }
        if world.fixedStepEpoch != clockEpoch {
            let tick = world.fixedStepState.tick
            let isBoundary = tick == lastCompletedTick
                || (atTickStart && lastCompletedTick < UInt64.max && tick == lastCompletedTick + 1)
            guard pending == nil, isBoundary else { throw InputReplayError.incompleteTick }
            // Host visibility, focus, and pause transitions may discard clock debt
            // between complete ticks. They do not change the archive's fixed rate.
            clockEpoch = world.fixedStepEpoch
        }
    }

    private func validateSession(_ world: World) throws {
        do {
            try validateTickClock(world)
            guard pending == nil else { throw InputReplayError.incompleteTick }
            guard lastCompletedTick == world.fixedStepState.tick else { throw InputReplayError.skippedTick }
        } catch {
            fail(error)
            throw error
        }
    }

    private func saveClock(_ world: World) {
        priorClock = ClockPreferences(configuration: world.fixedStep, isPaused: world.isPaused, timeScale: world.timeScale)
    }

    private func resetSession(_ world: World, configuration: FixedStepConfiguration) {
        self.configuration = configuration
        clockEpoch = world.fixedStepEpoch
        lastCompletedTick = world.fixedStepState.tick
        frameIndex = 0
        pending = nil
        cachedTick = nil
        cachedSample = nil
        divergence = nil
        lastError = nil
        buffer.reset()
    }

    private func fail(_ error: any Error) {
        lastError = error
        pending = nil
        cachedTick = nil
        cachedSample = nil
        state = .failed
        world?.isPaused = true
        buffer.reset()
    }

    private func acquireWorld(_ world: World) throws {
        guard world.inputReplayOwner == nil || world.inputReplayOwner === self else {
            throw InputReplayError.worldInUse
        }
        world.inputReplayOwner = self
    }
}
