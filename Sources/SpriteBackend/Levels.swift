import ECSCore
import Foundation
import Observation

/// A surface transition, independent of the world's simulation clock.
/// Fade uses half its total duration before replacing the level and half after.
/// Cross-fade freezes the outgoing game surface; it never simulates two levels.
public enum LevelTransition: Hashable, Codable, Sendable {
    case instant
    case fade(duration: TimeInterval = 0.35)
    case crossFade(duration: TimeInterval = 0.35)

    var duration: TimeInterval {
        switch self { case .instant: 0; case .fade(let value), .crossFade(let value): value }
    }
}

public enum LevelLoadingError: Error, Equatable {
    case invalidID, invalidTransition, invalidRoot, invalidCamera
    case busy, foreignEntity, managedRoot, presentationUnavailable
}

/// Resources and cleanup belonging to a single prepared level instance.
/// Register activation work here instead of changing the live world while loading.
@MainActor public final class LevelContext {
    public let id: String
    public let resources = ResourceLibrary()
    /// An enabled camera in the incoming hierarchy or among persistent entities.
    /// Nil leaves selection to the world's existing camera policy.
    public var camera: Entity?
    private var subscriptions: [EventSubscription] = []
    private var activation: [@MainActor (Entity) -> Void] = []
    private var cleanup: [@MainActor () -> Void] = []
    private var disposed = false

    init(id: String) { self.id = id }

    public func retain(_ subscription: EventSubscription) {
        if disposed { subscription.cancel() } else { subscriptions.append(subscription) }
    }
    /// Runs after the incoming root is installed and currentRoot is available.
    public func onActivate(_ action: @escaping @MainActor (Entity) -> Void) {
        if !disposed { activation.append(action) }
    }
    /// Runs once when preparation fails, is cancelled, or this level is unloaded.
    /// Registering cleanup after disposal executes it immediately.
    public func onUnload(_ action: @escaping @MainActor () -> Void) {
        if disposed { action() } else { cleanup.append(action) }
    }
    func activate(_ root: Entity) {
        let actions = activation; activation.removeAll()
        for action in actions where !disposed { action(root) }
    }
    func dispose() {
        guard !disposed else { return }
        disposed = true
        let tokens = subscriptions; subscriptions.removeAll()
        let actions = cleanup; cleanup.removeAll(); activation.removeAll()
        for token in tokens { token.cancel() }
        resources.closeLevelScope()
        for action in actions.reversed() { action() }
    }
}

public enum LevelEvents {
    public struct DidLoad: Event { public let id: String; public let root: Entity }
    public struct DidFail: Event { public let id: String; public let error: any Error }
    public struct DidCancel: Event { public let id: String; public let committed: Bool }
}

/// The view-owned bridge for surface capture and temporary input suppression.
@_spi(Backend) @MainActor public protocol LevelPresentation: AnyObject {
    var isLevelPresentationAvailable: Bool { get }
    func captureLevelPresentation() throws -> SpriteImage
    func levelInputDidChange(blocked: Bool)
}

/// Replaces one managed hierarchy while retaining its World, view and player sessions.
/// Top-level entities outside currentRoot are never removed. This runtime object
/// and its subscriptions are not snapshot data. Don't detach managed roots from
/// lifecycle callbacks or replace the whole world underneath a pending request.
@MainActor @Observable public final class LevelCoordinator {
    public enum Phase: String, Sendable {
        case idle, preparing, fadingOut, installing, fadingIn, crossFading
    }
    public let world: World
    public private(set) var currentID: String?
    public private(set) var currentRoot: Entity?
    public private(set) var phase = Phase.idle
    public private(set) var blocksInput = false
    public private(set) var overlayOpacity: Double = 0
    public private(set) var outgoingImage: SpriteImage?
    public var isLoading: Bool { phase != .idle }
    @ObservationIgnored @_spi(Backend) public weak var presentation: (any LevelPresentation)?
    @ObservationIgnored private var currentContext: LevelContext?
    @ObservationIgnored private var request: Request?
    @ObservationIgnored private var installing = false
    @ObservationIgnored private var deferredCancellation = false

    @MainActor private final class Request {
        let token = UUID()
        let context: LevelContext
        var preparation: Task<Entity, any Error>?
        var committed = false
        var hadOutgoingLevel = false
        init(_ context: LevelContext) { self.context = context }
    }

    public init(world: World) { self.world = world }

    isolated deinit {
        request?.preparation?.cancel()
        if request?.context !== currentContext { request?.context.dispose() }
        currentContext?.dispose()
        if blocksInput { presentation?.levelInputDidChange(blocked: false) }
    }

    /// Promotes an existing entity to a persistent top-level sibling, preserving
    /// its scene transform. Do this before switching levels. Its identity, value
    /// components and resource handles remain intact across subsequent loads.
    public func preserve(_ entity: Entity) throws {
        guard !installing else { throw LevelLoadingError.busy }
        guard entity.world === world else { throw LevelLoadingError.foreignEntity }
        guard entity !== world.root, entity !== currentRoot else { throw LevelLoadingError.managedRoot }
        try entity.setParent(world.root, preservingWorldTransform: true)
    }

    /// Prepares a detached hierarchy with an owned resource scope, then replaces
    /// the current level. Preparation leaves the outgoing world playable. A newer
    /// request cancels an older one; even noncooperative loaders cannot install
    /// stale results. Positive animated durations require a visible GameView.
    @discardableResult
    public func load(id: String, transition: LevelTransition = .fade(),
                     prepare: @escaping @MainActor (LevelContext) async throws -> Entity) async throws -> Entity {
        try Task.checkCancellation()
        guard !installing else { throw LevelLoadingError.busy }
        guard !id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw LevelLoadingError.invalidID }
        guard transition.duration.isFinite, (0...30).contains(transition.duration) else { throw LevelLoadingError.invalidTransition }
        cancel()
        let next = Request(LevelContext(id: id))
        request = next; phase = .preparing
        let task = Task { @MainActor in
            try Task.checkCancellation()
            return try await prepare(next.context)
        }
        next.preparation = task
        let token = next.token
        return try await withTaskCancellationHandler {
            do {
                let root = try await task.value
                try check(next)
                try validate(root, context: next.context)
                if transition.duration > 0 {
                    let available = presentation?.isLevelPresentationAvailable == true
                    try check(next)
                    guard available else { throw LevelLoadingError.presentationUnavailable }
                    if case .crossFade = transition, currentRoot != nil {
                        guard let presentation else { throw LevelLoadingError.presentationUnavailable }
                        let image = try presentation.captureLevelPresentation()
                        try check(next)
                        outgoingImage = image
                    }
                }
                setInputBlocked(true)
                try check(next)
                if case .fade = transition, currentRoot != nil, transition.duration > 0 {
                    phase = .fadingOut
                    try await animate(from: 0, to: 1, duration: transition.duration / 2, request: next)
                }
                try check(next)
                try validate(root, context: next.context)
                install(root, request: next)
                try check(next)
                if transition.duration > 0 {
                    if outgoingImage != nil {
                        phase = .crossFading
                        try await animate(from: 1, to: 0, duration: transition.duration, request: next)
                    } else {
                        phase = .fadingIn
                        let duration = transition.duration / ((transition.isFade && next.hadOutgoingLevel) ? 2 : 1)
                        try await animate(from: 1, to: 0, duration: duration, request: next)
                    }
                }
                try check(next)
                request = nil
                finishPresentation()
                world.publish(LevelEvents.DidLoad(id: id, root: root), from: root)
                return root
            } catch {
                if request === next {
                    if error is CancellationError || Task.isCancelled {
                        cancel()
                    } else {
                        request = nil
                        if currentContext !== next.context { next.context.dispose() }
                        finishPresentation()
                        world.publish(LevelEvents.DidFail(id: id, error: error))
                    }
                } else if currentContext !== next.context { next.context.dispose() }
                throw error
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                if self?.request?.token == token { self?.cancel() }
            }
        }
    }

    /// Before commit, keeps the outgoing level. After commit, keeps the incoming
    /// level and ends only its visual transition. Cancellation during installation
    /// is deferred until the hierarchy and activation callbacks are coherent.
    public func cancel() {
        if installing { deferredCancellation = true; return }
        guard let old = request else { return }
        request = nil
        old.preparation?.cancel()
        if currentContext !== old.context { old.context.dispose() }
        finishPresentation()
        world.publish(LevelEvents.DidCancel(id: old.context.id, committed: old.committed))
    }

    private func check(_ expected: Request) throws {
        try Task.checkCancellation()
        guard request === expected else { throw CancellationError() }
    }
    private func validate(_ root: Entity, context: LevelContext) throws {
        guard root !== world.root, root.parent == nil, root.world == nil else { throw LevelLoadingError.invalidRoot }
        if let currentRoot, currentRoot.world !== world || currentRoot.parent !== world.root { throw LevelLoadingError.invalidRoot }
        if let camera = context.camera {
            let incoming = camera === root || camera.isDescendant(of: root)
            let persistent = camera.world === world && camera !== currentRoot && currentRoot.map({ !camera.isDescendant(of: $0) }) != false
            guard (incoming || persistent), camera.isEnabledInHierarchy,
                  camera.components[CameraComponent.self]?.isActive == true else { throw LevelLoadingError.invalidCamera }
        }
    }
    private func install(_ root: Entity, request next: Request) {
        installing = true; deferredCancellation = false
        phase = .installing
        let previousRoot = currentRoot, previousContext = currentContext
        next.hadOutgoingLevel = previousRoot != nil
        currentRoot = nil; currentID = nil; currentContext = nil
        previousContext?.dispose()
        previousRoot?.removeFromParent()
        world.addEntity(root)
        currentRoot = root; currentID = next.context.id; currentContext = next.context
        if let camera = next.context.camera {
            // Outgoing cleanup may remove a persistent camera after validation.
            // Installation has committed; fall back safely rather than trapping
            // on World.activeCamera's same-world precondition.
            world.activeCamera = camera.world === world && camera.isEnabledInHierarchy
                && camera.components[CameraComponent.self]?.isActive == true ? camera : nil
        }
        next.committed = true
        next.context.activate(root)
        installing = false
        if deferredCancellation { deferredCancellation = false; cancel() }
    }
    private func setInputBlocked(_ value: Bool) {
        guard blocksInput != value else { return }
        blocksInput = value
        presentation?.levelInputDidChange(blocked: value)
    }
    private func finishPresentation() {
        outgoingImage = nil; overlayOpacity = 0; phase = .idle
        setInputBlocked(false)
    }
    private func animate(from start: Double, to end: Double, duration: TimeInterval, request next: Request) async throws {
        overlayOpacity = start
        let clock = ContinuousClock()
        let began = clock.now
        while true {
            try check(next)
            let elapsed = began.duration(to: clock.now).components
            let seconds = Double(elapsed.seconds) + Double(elapsed.attoseconds) / 1e18
            let fraction = duration > 0 ? min(1, seconds / duration) : 1
            overlayOpacity = start + (end - start) * fraction
            if fraction >= 1 { break }
            try await Task.sleep(nanoseconds: 16_000_000)
        }
    }
}

private extension LevelTransition {
    var isFade: Bool { if case .fade = self { true } else { false } }
}
