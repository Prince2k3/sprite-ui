import Foundation
import Observation

/// Portable presentation of a control. Symbols use SF Symbols names when available.
public struct InputControlPresentation: Hashable, Sendable {
    public let label: String
    public let symbolName: String?
    public init(label: String, symbolName: String? = nil) {
        self.label = label; self.symbolName = symbolName
    }
}

/// A connected producer and its current system-provided control presentations.
/// Controller identities last for a connection, and should not be saved to disk.
public struct InputDeviceInfo: Hashable, Sendable, Identifiable {
    public let id: InputDevice
    public var name: String
    public var presentations: [InputControl: InputControlPresentation]
    public var supportsHaptics: Bool
    public var hasRemappedElements: Bool
    public init(id: InputDevice, name: String,
                presentations: [InputControl: InputControlPresentation] = [:],
                supportsHaptics: Bool = false, hasRemappedElements: Bool = false) {
        self.id = id; self.name = name; self.presentations = presentations
        self.supportsHaptics = supportsHaptics; self.hasRemappedElements = hasRemappedElements
    }
}

/// A prompt resolved from a player's effective action bindings and owned devices.
public struct InputPrompt: Hashable, Sendable {
    public let action: InputAction
    public let control: InputControl
    public let device: InputDevice
    public let label: String
    public let symbolName: String?
}

/// A short controller haptic. Values are finite, normalized, and limited to two
/// seconds. Acceptance means the backend scheduled it, not that hardware vibrated.
public struct ControllerFeedback: Hashable, Codable, Sendable {
    public let intensity: Float
    public let sharpness: Float
    public let duration: TimeInterval
    public init(intensity: Float = 0.5, sharpness: Float = 0.5, duration: TimeInterval = 0.1) {
        self.intensity = intensity.isFinite ? min(max(intensity, 0), 1) : 0
        self.sharpness = sharpness.isFinite ? min(max(sharpness, 0), 1) : 0.5
        self.duration = duration.isFinite ? min(max(duration, 0.01), 2) : 0.1
    }
    public static let selection = Self(intensity: 0.2, sharpness: 0.8, duration: 0.04)
    public static let impact = Self(intensity: 0.7, sharpness: 0.7, duration: 0.12)
    public static let success = Self(intensity: 0.45, sharpness: 0.6, duration: 0.18)
    public static let failure = Self(intensity: 0.8, sharpness: 0.2, duration: 0.25)
    private enum CodingKeys: String, CodingKey { case intensity, sharpness, duration }
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(intensity: try c.decode(Float.self, forKey: .intensity),
                  sharpness: try c.decode(Float.self, forKey: .sharpness),
                  duration: try c.decode(TimeInterval.self, forKey: .duration))
    }
}

public enum InputFeedbackResult: String, Codable, Sendable {
    case accepted, unsupported, unavailable, failed
}

/// Backend hook for capability-checked feedback. Applications normally call
/// `PlayerInputSession.playFeedback(_:on:)` instead of implementing a provider.
@MainActor public protocol InputFeedbackProvider: AnyObject {
    func play(_ feedback: ControllerFeedback, on device: InputDevice) -> InputFeedbackResult
    func stop(for device: InputDevice)
}

/// Device lifecycle and ownership transitions. Retain an observation token to
/// receive events; callbacks run synchronously on the main actor.
public enum InputDeviceEvent: Sendable {
    case connected(InputDeviceInfo)
    case updated(InputDeviceInfo)
    case disconnected(InputDeviceInfo)
    case assignmentChanged(device: InputDevice, previousPlayer: UUID?, player: UUID?)
    case activeDeviceChanged(player: UUID, device: InputDevice?)
}

@MainActor public final class InputDeviceSubscription {
    fileprivate var isCancelled = false
    public func cancel() { isCancelled = true }
}

public enum PlayerInputError: Error, Equatable {
    case unknownDevice, foreignPlayer
}

/// One local player's runtime input. Sessions, ownership, held state and haptic
/// engines are intentionally separate from serializable action maps and worlds.
@MainActor @Observable public final class PlayerInputSession: Identifiable {
    public let id = UUID()
    public var name: String
    public let input: InputController
    fileprivate weak var hub: PlayerInputHub?
    fileprivate var activeID: InputDevice?
    @ObservationIgnored private var hubSuppressionOwners: Set<UUID> = []
    public var isEnabled: Bool {
        get { input.isEnabled }
        set { input.isEnabled = newValue }
    }
    public var devices: [InputDeviceInfo] { hub?.devices.filter { hub?.owner(of: $0.id) === self } ?? [] }
    public var activeDevice: InputDeviceInfo? { devices.first { $0.id == activeID } }

    fileprivate init(name: String, contexts: [InputActionMap], hub: PlayerInputHub) {
        self.name = name; self.input = InputController(contexts: contexts); self.hub = hub
        input.onCancellation = { [weak self] in
            guard let self else { return }
            self.hub?.sessionCancelled(self)
            self.stopFeedback()
        }
        input.onDeviceCancellation = { [weak self] device in
            guard let self, let hub = self.hub, hub.owner(of: device) === self else { return }
            hub.cancelled(device: device, for: self)
            hub.feedbackProvider?.stop(for: device)
        }
    }

    fileprivate func setHubInputSuppressed(_ suppressed: Bool, owner: UUID) {
        // Record ownership before cancellation can reenter the hub or remove us.
        let changed = suppressed ? hubSuppressionOwners.insert(owner).inserted : hubSuppressionOwners.remove(owner) != nil
        guard changed else { return }
        input.setInputSuppressed(suppressed, owner: owner)
    }

    fileprivate func releaseHubInputSuppression() {
        let owners = hubSuppressionOwners
        hubSuppressionOwners.removeAll()
        for owner in owners { input.setInputSuppressed(false, owner: owner) }
    }

    /// Uses the last meaningful assigned device when it can express this action,
    /// then falls back to another owned device. Shadowed bindings are excluded.
    public func prompt(for action: InputAction) -> InputPrompt? {
        let bindings = input.bindings(for: action)
        let owned = devices.sorted {
            if ($0.id == activeID) != ($1.id == activeID) { return $0.id == activeID }
            return $0.id.sortKey < $1.id.sortKey
        }
        for device in owned {
            for binding in bindings where Self.matches(binding.control, device: device) {
                let presentation = device.presentations[binding.control] ?? Self.fallback(binding.control)
                return .init(action: action, control: binding.control, device: device.id,
                             label: presentation.label, symbolName: presentation.symbolName)
            }
        }
        return nil
    }

    /// Defaults to the last meaningful device. Keyboard/touch activity never
    /// silently vibrates a different controller. An explicit device must be owned.
    @discardableResult public func playFeedback(_ feedback: ControllerFeedback,
                                                on device: InputDevice? = nil) -> InputFeedbackResult {
        guard let hub, !hub.cancelling, hub.acceptsInput, input.acceptsInput,
              let selected = device ?? activeID, hub.owner(of: selected) === self,
              let info = devices.first(where: { $0.id == selected }) else { return .unavailable }
        guard case .controller = selected, info.supportsHaptics else { return .unsupported }
        return hub.feedbackProvider?.play(feedback, on: selected) ?? .unavailable
    }

    public func stopFeedback() {
        guard let hub else { return }
        for device in devices { hub.feedbackProvider?.stop(for: device.id) }
    }

    private static func matches(_ control: InputControl, device: InputDeviceInfo) -> Bool {
        switch (control, device.id) {
        case (.key, .keyboard), (.pointerButton, .pointer): true
        case (.gamepadButton, .controller), (.gamepadAxis, .controller), (.virtual, .virtual):
            device.presentations.isEmpty || device.presentations[control] != nil
        default: false
        }
    }
    private static func fallback(_ control: InputControl) -> InputControlPresentation {
        switch control {
        case .key(let key):
            let names = ["space": "Space", "return": "Return", "escape": "Escape", "up": "Up", "down": "Down", "left": "Left", "right": "Right", "tab": "Tab"]
            return .init(label: names[key] ?? key.uppercased())
        case .pointerButton(let button): return .init(label: button == 0 ? "Primary click" : "Mouse \(button + 1)")
        case .gamepadButton(let button): return .init(label: button.rawValue)
        case .gamepadAxis(let axis): return .init(label: axis.rawValue)
        case .virtual(let name): return .init(label: name)
        }
    }
}

/// Assigns each device exclusively to one local player. Keyboard and pointer
/// initially describe coalesced view sources, not physical-hardware discovery.
/// New controllers are unassigned; applications choose their joining policy.
@MainActor @Observable public final class PlayerInputHub {
    public private(set) var players: [PlayerInputSession] = []
    public var devices: [InputDeviceInfo] { infos.values.sorted { $0.id.sortKey < $1.id.sortKey } }
    public var isEnabled = true {
        didSet { if oldValue != isEnabled { cancelAll() } }
    }
    private var infos: [InputDevice: InputDeviceInfo] = [
        .keyboard: .init(id: .keyboard, name: "Keyboard"), .pointer: .init(id: .pointer, name: "Pointer")
    ]
    private var owners: [InputDevice: UUID] = [:]
    @ObservationIgnored private var raw: [InputDevice: [InputControl: InputValue]] = [:]
    @ObservationIgnored private var gates: [InputDevice: [InputControl: InputController]] = [:]
    @ObservationIgnored private var needsBaseline: Set<InputDevice> = []
    @ObservationIgnored private var revisions: [InputDevice: UInt64] = [:]
    @ObservationIgnored private var usage: [InputDevice: UInt64] = [:]
    @ObservationIgnored private var clock: UInt64 = 0
    @ObservationIgnored fileprivate var cancelling = false
    @ObservationIgnored private var backendOwner: UUID?
    @ObservationIgnored private var suppressionOwners: Set<UUID> = []
    @ObservationIgnored fileprivate var feedbackProvider: (any InputFeedbackProvider)?
    @ObservationIgnored private var handlers: [Handler] = []
    private struct Handler {
        weak var token: InputDeviceSubscription?
        let call: @MainActor (InputDeviceEvent) -> Void
    }

    public init() {}

    isolated deinit {
        for player in players {
            player.hub = nil; player.activeID = nil
            player.releaseHubInputSuppression()
        }
    }

    fileprivate var acceptsInput: Bool { isEnabled && suppressionOwners.isEmpty }

    @discardableResult public func addPlayer(named name: String, contexts: [InputActionMap] = []) -> PlayerInputSession {
        let player = PlayerInputSession(name: name, contexts: contexts, hub: self)
        for owner in suppressionOwners { player.setHubInputSuppressed(true, owner: owner) }
        players.append(player)
        return player
    }
    public func removePlayer(_ player: PlayerInputSession) {
        guard player.hub === self, players.contains(where: { $0 === player }) else { return }
        // Remove before callbacks so a cancellation cannot reassign to this player.
        players.removeAll { $0 === player }
        for device in owners.keys.sorted(by: { $0.sortKey < $1.sortKey }) where owners[device] == player.id {
            changeOwner(device, to: nil, previous: player)
        }
        player.input.cancelAll()
        player.releaseHubInputSuppression()
        player.hub = nil; player.activeID = nil
    }
    public func owner(of device: InputDevice) -> PlayerInputSession? {
        players.first { $0.id == owners[device] }
    }
    public func assign(_ device: InputDevice, to player: PlayerInputSession) throws {
        guard infos[device] != nil else { throw PlayerInputError.unknownDevice }
        guard player.hub === self, players.contains(where: { $0 === player }) else { throw PlayerInputError.foreignPlayer }
        guard !cancelling, owners[device] != player.id else { return }
        changeOwner(device, to: player, previous: owner(of: device))
    }
    public func unassign(_ device: InputDevice) {
        guard owners[device] != nil else { return }
        changeOwner(device, to: nil, previous: owner(of: device))
    }
    /// Adds or updates a producer. Metadata changes (including system remapping)
    /// update prompts without cancelling actions or altering ownership.
    public func connect(_ info: InputDeviceInfo) {
        guard infos[info.id] != info else { return }
        let existed = infos.updateValue(info, forKey: info.id) != nil
        if !existed, case .controller = info.id { needsBaseline.insert(info.id) }
        emit(existed ? .updated(info) : .connected(info)) { self.infos[info.id] == info }
    }
    public func disconnect(_ device: InputDevice) {
        guard let info = infos.removeValue(forKey: device) else { return }
        let previous = owner(of: device)
        changeOwner(device, to: nil, previous: previous)
        // Reentrant observers may have connected a new producer with this identity.
        guard infos[device] == nil else { return }
        raw[device] = nil; gates[device] = nil; needsBaseline.remove(device); usage[device] = nil
        emit(.disconnected(info)) { self.infos[device] == nil }
    }
    /// Supplies a partial atomic device snapshot. Unassigned snapshots are kept
    /// solely to establish a safe neutral baseline when ownership changes.
    public func submit(_ values: [(InputControl, InputValue)], device: InputDevice) {
        guard infos[device] != nil else { return }
        // Any newer snapshot supersedes a pending one, including a release
        // supplied reentrantly by an active-device observer.
        revisions[device, default: 0] &+= 1
        let previous = raw[device] ?? [:]
        var latest: [InputControl: InputValue] = [:]
        for (control, value) in values { latest[control.canonical] = Self.sanitized(value) }
        let normalized = latest.sorted { String(describing: $0.key) < String(describing: $1.key) }
        for (control, value) in normalized { raw[device, default: [:]][control] = value }
        let player = owner(of: device)
        if needsBaseline.remove(device) != nil {
            captureGates(device, using: player?.input)
        }
        guard !cancelling, acceptsInput, let player, player.input.acceptsInput else {
            captureGates(device, using: player?.input)
            return
        }
        let revision = revisions[device, default: 0]
        var routed: [(InputControl, InputValue)] = []
        var meaningful = false
        for (control, value) in normalized {
            if let oldBindings = gates[device]?[control] {
                guard oldBindings.isNeutral(value, for: control), player.input.isNeutral(value, for: control) else {
                    routed.append((control, .axis(0))); continue
                }
                gates[device]?[control] = nil
            }
            routed.append((control, value))
            if previous[control] != value, player.input.hasEffectiveBinding(for: control),
               !player.input.isNeutral(value, for: control) { meaningful = true }
        }
        if meaningful {
            clock &+= 1; usage[device] = clock
            setActive(device, for: player)
        }
        guard revisions[device, default: 0] == revision, owner(of: device) === player,
              player.input.acceptsInput, acceptsInput else { return }
        player.input.setValues(routed, device: device)
    }
    /// Suspends held actions and feedback while preserving assignments. Held
    /// controls must return to neutral before the next meaningful input.
    public func cancelAll() {
        guard !cancelling else { return }
        cancelling = true
        defer { cancelling = false }
        for device in infos.keys {
            if case .controller = device { needsBaseline.insert(device) }
        }
        for device in raw.keys {
            revisions[device, default: 0] &+= 1
            captureGates(device, using: owner(of: device)?.input)
        }
        for player in players { player.stopFeedback(); player.input.cancelAll() }
    }
    public func observe(_ handler: @escaping @MainActor (InputDeviceEvent) -> Void) -> InputDeviceSubscription {
        let token = InputDeviceSubscription(); handlers.append(.init(token: token, call: handler)); return token
    }
    /// Applies an independent suppression lease to current and future players.
    /// Devices, assignments, backend ownership and enabled preferences survive;
    /// cancellation retains neutral gates and stops the players' feedback.
    @_spi(Backend) public func setInputSuppressed(_ suppressed: Bool, owner: UUID) {
        let changed = suppressed ? suppressionOwners.insert(owner).inserted : suppressionOwners.remove(owner) != nil
        guard changed else { return }
        for player in players where player.hub === self {
            // Cancellation observers may add or release leases reentrantly.
            // Re-read the current lease before touching each remaining player.
            player.setHubInputSuppressed(suppressionOwners.contains(owner), owner: owner)
        }
    }

    /// One native host may drive a hub at a time. Adapters retain their provider
    /// until detach; a rejected attachment must leave the current host alone.
    @_spi(Backend) public func attachBackend(owner: UUID, feedbackProvider: any InputFeedbackProvider) -> Bool {
        guard backendOwner == nil || backendOwner == owner else { return false }
        backendOwner = owner; self.feedbackProvider = feedbackProvider; return true
    }
    @_spi(Backend) public func detachBackend(owner: UUID) {
        guard backendOwner == owner else { return }
        cancelAll(); feedbackProvider = nil; backendOwner = nil
    }

    private func changeOwner(_ device: InputDevice, to next: PlayerInputSession?, previous: PlayerInputSession?) {
        let oldID = owners[device]
        revisions[device, default: 0] &+= 1
        let revision = revisions[device]!
        captureGates(device, using: previous?.input)
        captureGates(device, using: next?.input)
        owners[device] = next?.id; usage[device] = nil
        feedbackProvider?.stop(for: device)
        previous?.input.removeDevice(device)
        if let previous, previous.activeID == device, owner(of: device) !== previous {
            selectFallback(for: previous)
        }
        guard revisions[device] == revision else { return }
        emit(.assignmentChanged(device: device, previousPlayer: oldID, player: next?.id)) {
            self.revisions[device] == revision
        }
    }
    private func captureGates(_ device: InputDevice, using input: InputController?) {
        guard let input else { return }
        let snapshot = InputController(contexts: input.contexts)
        for (control, value) in raw[device] ?? [:]
        where snapshot.hasEffectiveBinding(for: control) && !snapshot.isNeutral(value, for: control) {
            if gates[device]?[control] == nil { gates[device, default: [:]][control] = snapshot }
        }
    }
    fileprivate func sessionCancelled(_ player: PlayerInputSession) {
        for device in devices where owners[device.id] == player.id {
            cancelled(device: device.id, for: player)
        }
    }
    fileprivate func cancelled(device: InputDevice, for player: PlayerInputSession) {
        revisions[device, default: 0] &+= 1
        captureGates(device, using: player.input)
        if case .controller = device { needsBaseline.insert(device) }
    }
    private func selectFallback(for player: PlayerInputSession) {
        let device = devices.filter { owners[$0.id] == player.id && usage[$0.id] != nil }
            .max { usage[$0.id, default: 0] < usage[$1.id, default: 0] }?.id
        setActive(device, for: player)
    }
    private func setActive(_ device: InputDevice?, for player: PlayerInputSession) {
        guard player.activeID != device else { return }
        player.activeID = device
        emit(.activeDeviceChanged(player: player.id, device: device)) { player.hub === self && player.activeID == device }
    }
    private func emit(_ event: InputDeviceEvent, valid: () -> Bool = { true }) {
        handlers.removeAll { $0.token == nil || $0.token!.isCancelled }
        for handler in handlers where handler.token?.isCancelled == false {
            guard valid() else { break }
            handler.call(event)
        }
    }
    private static func sanitized(_ value: InputValue) -> InputValue {
        switch value {
        case .button: value
        case .axis(let v): .axis(v.isFinite ? min(max(v, -1), 1) : 0)
        case .axis2D(let v): .axis2D([v.x.isFinite ? min(max(v.x, -1), 1) : 0, v.y.isFinite ? min(max(v.y, -1), 1) : 0])
        }
    }
}
