import ECSCore
import Foundation
@_spi(Backend) @testable import SpriteBackend
import Testing

@MainActor @Suite struct LevelTests {
    private struct Pulse: Event {}
    private enum Failure: Error, Equatable { case preparation, capture }

    @MainActor private final class Presenter: LevelPresentation {
        private var available = true
        var onAvailability: (() -> Void)?
        var isLevelPresentationAvailable: Bool {
            get { onAvailability?(); return available }
            set { available = newValue }
        }
        var snapshots = 0
        var gateChanges: [Bool] = []
        var onBlock: (() -> Void)?
        var onCapture: (() -> Void)?
        var failsCapture = false
        func captureLevelPresentation() throws -> SpriteImage {
            snapshots += 1
            if failsCapture { throw Failure.capture }
            onCapture?()
            return SpriteImage(width: 1, height: 1, pixels: [255, 0, 0, 255])
        }
        func levelInputDidChange(blocked: Bool) {
            gateChanges.append(blocked)
            if blocked { onBlock?() }
        }
    }
    @MainActor private final class Gate {
        var waiting = false
        private var continuation: CheckedContinuation<Entity, Never>?
        func value() async -> Entity {
            await withCheckedContinuation { continuation = $0; waiting = true }
        }
        func finish(_ root: Entity) { let pending = continuation; continuation = nil; pending?.resume(returning: root) }
    }
    private func waitUntil(_ predicate: () -> Bool) async throws {
        for _ in 0..<1000 {
            if predicate() { return }
            await Task.yield()
        }
        try #require(predicate(), "Main-actor operation did not reach the expected checkpoint")
    }

    @Test func instantaneousReplacementOwnsOnlyItsRootAndDoesNotAdvanceSimulation() async throws {
        let world = World()
        let manager = LevelCoordinator(world: world)
        let unrelated = Entity(name: "hud"); world.addEntity(unrelated)
        var updates = 0
        let token = world.subscribe(to: WorldEvents.Update.self) { _ in updates += 1 }
        let first = try await manager.load(id: "first", transition: .instant) { _ in Entity(name: "first") }
        let second = try await manager.load(id: "second", transition: .instant) { _ in Entity(name: "second") }
        #expect(first.world == nil && second.world === world && unrelated.world === world)
        #expect(manager.currentRoot === second && manager.currentID == "second")
        #expect(manager.phase == .idle && !manager.blocksInput && manager.overlayOpacity == 0)
        #expect(updates == 0)
        withExtendedLifetime(token) {}
    }

    @Test func preservedEntitiesKeepIdentitySceneTransformAndCameraSelection() async throws {
        let world = World()
        let levels = LevelCoordinator(world: world)
        let root = try await levels.load(id: "one", transition: .instant) { _ in
            let root = Entity(); root.position = [100, 20]; return root
        }
        let player = Entity(name: "player"); player.position = [7, 9]; root.addChild(player)
        let camera = Entity(components: CameraComponent()); player.addChild(camera)
        let id = player.id
        try levels.preserve(player)
        let transform = player.sceneTransformMatrix
        try await levels.load(id: "two", transition: .instant) { context in
            context.camera = camera
            return Entity()
        }
        #expect(player.id == id && player.parent === world.root && player.world === world)
        #expect(player.sceneTransformMatrix == transform && player.position == [107, 29])
        #expect(world.activeCamera === camera && root.world == nil)
        #expect(throws: LevelLoadingError.managedRoot) { try levels.preserve(world.root) }
        #expect(throws: LevelLoadingError.managedRoot) { try levels.preserve(try #require(levels.currentRoot)) }
        #expect(throws: LevelLoadingError.foreignEntity) { try LevelCoordinator(world: World()).preserve(player) }
    }

    @Test func scopedSubscriptionsStopBeforeUnloadCallbacksAndResourcesAreCleared() async throws {
        let world = World()
        let levels = LevelCoordinator(world: world)
        var hits = 0, disposed = 0
        var scope: LevelContext?
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".prefab")
        defer { try? FileManager.default.removeItem(at: file) }
        try PrefabResource(root: Entity(name: "prepared")).write(to: file)
        try await levels.load(id: "one", transition: .instant) { context in
            scope = context
            let template = try await context.resources.prefab(contentsOf: file)
            context.onActivate { _ in context.retain(world.subscribe(to: Pulse.self) { _ in hits += 1 }) }
            context.onUnload { disposed += 1; world.publish(Pulse()) }
            return template.instantiate()
        }
        #expect(scope?.resources.cachedResourceCount == 1)
        world.publish(Pulse()); #expect(hits == 1)
        try await levels.load(id: "two", transition: .instant) { _ in Entity() }
        world.publish(Pulse())
        #expect(hits == 1 && disposed == 1 && scope?.resources.cachedResourceCount == 0)
        scope?.retain(world.subscribe(to: Pulse.self) { _ in hits += 100 })
        scope?.onUnload { disposed += 1 }
        world.publish(Pulse())
        #expect(hits == 1 && disposed == 2)
    }

    @Test func failedPreparationAndInvalidHierarchiesLeaveTheOutgoingLevelIntact() async throws {
        let world = World()
        let manager = LevelCoordinator(world: world)
        let old = try await manager.load(id: "old", transition: .instant) { _ in Entity() }
        var disposed = 0, failures = 0
        let token = world.subscribe(to: LevelEvents.DidFail.self) { _ in failures += 1 }
        await #expect(throws: Failure.preparation) {
            try await manager.load(id: "bad", transition: .instant) { context in
                context.onUnload { disposed += 1 }; throw Failure.preparation
            }
        }
        await #expect(throws: LevelLoadingError.invalidRoot) {
            try await manager.load(id: "attached", transition: .instant) { _ in old }
        }
        await #expect(throws: LevelLoadingError.invalidCamera) {
            try await manager.load(id: "camera", transition: .instant) { context in
                context.camera = Entity(components: CameraComponent()); return Entity()
            }
        }
        #expect(old.world === world && manager.currentRoot === old && manager.currentID == "old")
        #expect(disposed == 1 && failures == 3 && !manager.blocksInput && !manager.isLoading)
        withExtendedLifetime(token) {}
    }

    @Test func supersededLoaderCannotAttachEvenWhenItIgnoresCancellation() async throws {
        let world = World(), gate = Gate()
        let levels = LevelCoordinator(world: world)
        let old = try await levels.load(id: "old", transition: .instant) { _ in Entity() }
        var disposed = 0
        let task = Task { try await levels.load(id: "slow", transition: .instant) { context in
            context.onUnload { disposed += 1 }
            return await gate.value()
        } }
        defer { task.cancel(); gate.finish(Entity()) }
        try await waitUntil { gate.waiting }
        #expect(levels.phase == .preparing && !levels.blocksInput && old.isActive)
        let fresh = try await levels.load(id: "fresh", transition: .instant) { _ in Entity() }
        let stale = Entity(name: "stale"); gate.finish(stale)
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(stale.world == nil && levels.currentRoot === fresh && disposed == 1)
    }

    @Test func callerCancellationDisposesPendingPreparationWithoutReplacingTheLevel() async throws {
        let world = World(), gate = Gate()
        let levels = LevelCoordinator(world: world)
        let old = try await levels.load(id: "old", transition: .instant) { _ in Entity() }
        var disposed = false
        let task = Task { try await levels.load(id: "slow", transition: .instant) { context in
            context.onUnload { disposed = true }; return await gate.value()
        } }
        defer { task.cancel(); gate.finish(Entity()) }
        try await waitUntil { gate.waiting }
        task.cancel()
        try await waitUntil { disposed }
        let stale = Entity(); gate.finish(stale)
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(stale.world == nil && old.isActive && levels.currentRoot === old && levels.phase == .idle)
    }

    @Test func cancellingBeforeCommitUnblocksInputAndKeepsOutgoingScopesAlive() async throws {
        let world = World(), presenter = Presenter()
        let levels = LevelCoordinator(world: world); levels.presentation = presenter
        var oldDisposed = false, nextDisposed = false
        let old = try await levels.load(id: "old", transition: .instant) { context in
            context.onUnload { oldDisposed = true }; return Entity()
        }
        presenter.gateChanges.removeAll()
        presenter.onBlock = { levels.cancel() }
        await #expect(throws: CancellationError.self) {
            try await levels.load(id: "next", transition: .fade(duration: 0.05)) { context in
                context.onUnload { nextDisposed = true }; return Entity()
            }
        }
        #expect(levels.currentRoot === old && old.isActive && !oldDisposed && nextDisposed)
        #expect(presenter.gateChanges == [true, false] && levels.overlayOpacity == 0 && levels.outgoingImage == nil)
    }

    @Test func crossFadeCapturesOnceAndDeferredCancellationKeepsTheCommittedLevel() async throws {
        let world = World(), presenter = Presenter()
        let levels = LevelCoordinator(world: world); levels.presentation = presenter
        let old = try await levels.load(id: "old", transition: .instant) { _ in Entity() }
        var disposed = false, cancelCommitted: Bool?
        let token = world.subscribe(to: LevelEvents.DidCancel.self) { cancelCommitted = $0.committed }
        await #expect(throws: CancellationError.self) {
            try await levels.load(id: "new", transition: .crossFade(duration: 0.05)) { context in
                context.onUnload { disposed = true }
                context.onActivate { _ in levels.cancel() }
                return Entity(name: "committed")
            }
        }
        #expect(presenter.snapshots == 1 && cancelCommitted == true)
        #expect(levels.currentID == "new" && levels.currentRoot?.isActive == true && old.world == nil)
        #expect(!disposed && !levels.blocksInput && levels.outgoingImage == nil)
        presenter.onBlock = nil
        try await levels.load(id: "after", transition: .instant) { _ in Entity() }
        #expect(disposed)
        withExtendedLifetime(token) {}
    }

    @Test func animationsUseWallTimeWhilePausedAndPublishOnlySettledSuccess() async throws {
        let world = World(), presenter = Presenter()
        let levels = LevelCoordinator(world: world); levels.presentation = presenter
        try await levels.load(id: "one", transition: .instant) { _ in Entity() }
        world.isPaused = true
        presenter.gateChanges.removeAll()
        var settled = false, updates = 0
        let token = world.subscribe(to: LevelEvents.DidLoad.self) { event in
            settled = event.id == "two" && levels.phase == .idle && !levels.blocksInput && levels.currentRoot === event.root
        }
        let update = world.subscribe(to: WorldEvents.Update.self) { _ in updates += 1 }
        try await levels.load(id: "two", transition: .fade(duration: 0.02)) { _ in Entity() }
        #expect(world.isPaused && settled && updates == 0)
        #expect(presenter.gateChanges == [true, false] && presenter.snapshots == 0)
        withExtendedLifetime((token, update)) {}
    }

    @Test func captureFailureAndUnavailablePresentationDoNotCommitOrGateInput() async throws {
        let world = World(), presenter = Presenter()
        let levels = LevelCoordinator(world: world); levels.presentation = presenter
        let old = try await levels.load(id: "old", transition: .instant) { _ in Entity() }
        presenter.gateChanges.removeAll(); presenter.failsCapture = true
        await #expect(throws: Failure.capture) { try await levels.load(id: "capture", transition: .crossFade()) { _ in Entity() } }
        presenter.failsCapture = false; presenter.onCapture = { levels.cancel() }
        await #expect(throws: CancellationError.self) { try await levels.load(id: "reentrant", transition: .crossFade()) { _ in Entity() } }
        #expect(levels.outgoingImage == nil && !levels.blocksInput)
        presenter.onCapture = nil
        presenter.onAvailability = { levels.cancel() }
        await #expect(throws: CancellationError.self) { try await levels.load(id: "getter", transition: .fade()) { _ in Entity() } }
        #expect(levels.outgoingImage == nil && !levels.blocksInput && levels.phase == .idle)
        presenter.onAvailability = nil
        presenter.isLevelPresentationAvailable = false
        await #expect(throws: LevelLoadingError.presentationUnavailable) { try await levels.load(id: "hidden", transition: .fade()) { _ in Entity() } }
        #expect(levels.currentRoot === old && old.isActive && presenter.gateChanges.isEmpty)
        await #expect(throws: LevelLoadingError.invalidID) { try await levels.load(id: " ", transition: .instant) { _ in Entity() } }
        await #expect(throws: LevelLoadingError.invalidTransition) { try await levels.load(id: "bad", transition: .fade(duration: .nan)) { _ in Entity() } }
        #expect(levels.currentRoot === old && levels.phase == .idle)
    }

    @Test func transitionValuesRoundTripAndZeroDurationNeedsNoPresenter() async throws {
        for value: LevelTransition in [.instant, .fade(), .crossFade(duration: 2)] {
            #expect(try JSONDecoder().decode(LevelTransition.self, from: JSONEncoder().encode(value)) == value)
        }
        let levels = LevelCoordinator(world: World())
        try await levels.load(id: "zero", transition: .fade(duration: 0)) { _ in Entity() }
        #expect(levels.currentID == "zero" && !levels.isLoading)
    }

    @Test func outgoingCleanupMayRemoveARequestedPersistentCameraWithoutTrapping() async throws {
        let world = World()
        let manager = LevelCoordinator(world: world)
        let camera = Entity(components: CameraComponent()); world.addEntity(camera)
        try await manager.load(id: "old", transition: .instant) { context in
            context.onUnload { camera.removeFromParent() }; return Entity()
        }
        let root = try await manager.load(id: "new", transition: .instant) { context in
            context.camera = camera; return Entity()
        }
        #expect(root.isActive && manager.currentRoot === root && camera.world == nil)
        #expect(world.activeCamera == nil && !manager.blocksInput && !manager.isLoading)
    }

    @Test func retiredScopeRejectsResourceLoadsFromAnUncancelledChildTask() async throws {
        let world = World(), gate = Gate()
        let levels = LevelCoordinator(world: world)
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".prefab")
        defer { try? FileManager.default.removeItem(at: file) }
        try PrefabResource(root: Entity()).write(to: file)
        var scope: LevelContext?, cleanup = 0
        let task = Task { try await levels.load(id: "slow", transition: .instant) { context in
            scope = context; context.onUnload { cleanup += 1 }
            // Unstructured work deliberately does not inherit cancellation.
            let child = Task { @MainActor in
                let root = await gate.value()
                _ = try await context.resources.prefab(contentsOf: file)
                return root
            }
            return try await child.value
        } }
        defer { task.cancel(); gate.finish(Entity()) }
        try await waitUntil { gate.waiting }
        levels.cancel(); gate.finish(Entity())
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(cleanup == 1 && scope?.resources.cachedResourceCount == 0 && levels.currentRoot == nil)
    }

    @Test(arguments: [false, true])
    func cancellationFromUnloadOrEntityAddedDefersUntilIncomingIsCoherent(cancelFromAdd: Bool) async throws {
        let world = World()
        let manager = LevelCoordinator(world: world)
        try await manager.load(id: "old", transition: .instant) { context in
            if !cancelFromAdd { context.onUnload { manager.cancel() } }
            return Entity()
        }
        var incomingDisposed = false, cancellations = 0
        let events = world.subscribe(to: LevelEvents.DidCancel.self) { event in
            #expect(event.committed); cancellations += 1
        }
        let added = world.subscribe(to: WorldEvents.DidAddEntity.self) { event in
            if cancelFromAdd, event.entity.name == "incoming" { manager.cancel() }
        }
        await #expect(throws: CancellationError.self) {
            try await manager.load(id: "new", transition: .instant) { context in
                context.onUnload { incomingDisposed = true }
                return Entity(name: "incoming")
            }
        }
        #expect(manager.currentID == "new" && manager.currentRoot?.isActive == true)
        #expect(cancellations == 1 && !incomingDisposed && !manager.blocksInput && !manager.isLoading)
        withExtendedLifetime((events, added)) {}
    }
}
