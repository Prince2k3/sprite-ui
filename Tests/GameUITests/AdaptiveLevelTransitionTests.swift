@_spi(Backend) import ECSCore
@testable import GameUI
@_spi(Backend) @testable import SpriteBackend
import Foundation
import SpriteKit
import Testing

@MainActor @Suite struct AdaptiveLevelTransitionTests {
    // Synthetic application layouts, not native device/posture detection.
    private enum Surface: CaseIterable {
        case book, tabletop, outer, flat

        var geometry: GameSurfaceGeometry {
            switch self {
            case .flat:
                .init(size: CGSize(width: 800, height: 600))
            case .book:
                .init(size: CGSize(width: 800, height: 600), reservedRegions: [
                    .init(id: "fold", kind: .division,
                          frame: CGRect(x: 390, y: 0, width: 20, height: 600))
                ])
            case .tabletop:
                .init(size: CGSize(width: 800, height: 600), reservedRegions: [
                    .init(id: "fold", kind: .division,
                          frame: CGRect(x: 0, y: 290, width: 800, height: 20))
                ])
            case .outer:
                .init(size: CGSize(width: 360, height: 640),
                      safeAreaInsets: .init(top: 20, bottom: 16))
            }
        }
    }

    private enum Failure: Error, Equatable { case preparation }

    @MainActor private final class PreparationGate {
        private(set) var waiting = false
        private var continuation: CheckedContinuation<Entity, any Error>?

        func value() async throws -> Entity {
            try await withCheckedThrowingContinuation {
                continuation = $0
                waiting = true
            }
        }

        func finish(_ result: Result<Entity, any Error>) {
            let pending = continuation
            continuation = nil
            pending?.resume(with: result)
        }
    }

    // Supply presentation availability without a window, but exercise the real
    // host bridge, hub suppression leases, and native-input session routing.
    @MainActor private final class Presenter: LevelPresentation {
        let host: GameHost
        var gateChanges: [Bool] = []
        var captures = 0
        var isLevelPresentationAvailable: Bool { true }

        init(host: GameHost) { self.host = host }

        func captureLevelPresentation() throws -> SpriteImage {
            captures += 1
            return SpriteImage(width: 1, height: 1, pixels: [255, 0, 0, 255])
        }

        func levelInputDidChange(blocked: Bool) {
            gateChanges.append(blocked)
            host.levelPresentation.levelInputDidChange(blocked: blocked)
        }
    }

    @MainActor private final class Fixture {
        let host: GameHost
        let content: GameViewContent
        let world: World
        let renderer: SpriteRenderer
        let outgoing: Entity
        let player: Entity
        let playerID: Entity.ID
        let playerNode: SKNode
        let camera: Entity
        let cameraNode: SKNode
        let nativeCamera: SKCameraNode
        let hub: PlayerInputHub
        let participant: PlayerInputSession
        let participantID: UUID
        let session: GameInputSession
        let presenter: Presenter
        let key = InputAction("key")
        let pointer = InputAction("pointer")
        let fold = InputAction("fold", kind: .axis)
        var neutral: GameHingeState? { .init(angle: .pi, status: .fullyOpen) }
        var held: GameHingeState? { .init(angle: .pi / 2, status: .partiallyOpen) }

        init() async throws {
            let host = GameHost()
            let player = Entity(name: "player", components: SpriteComponent(color: .red, size: [20, 20]))
            let camera = Entity(components: CameraComponent(target: .entity(player.id), smoothing: 0))
            player.position = [75, 25]
            let outgoing = try await host.levels.load(id: "outgoing", transition: .instant) { context in
                let root = Entity(name: "outgoing")
                root.addChild(player); root.addChild(camera)
                context.camera = camera
                return root
            }
            try host.levels.preserve(player)
            try host.levels.preserve(camera)
            host.configureViewports([.init(id: "game", camera: camera.id, region: .largestUsable)])
            host.updateSurfaceGeometry(Surface.flat.geometry)
            host.renderer.flush()
            host.renderer.updateCameras(deltaTime: 0, time: 0)
            self.host = host; content = host.content; world = host.world; renderer = host.renderer
            self.outgoing = outgoing; self.player = player; playerID = player.id
            self.camera = camera
            playerNode = try #require(host.renderer.node(for: player))
            cameraNode = try #require(host.renderer.node(for: camera))
            nativeCamera = try #require(host.renderer.camera)
            hub = PlayerInputHub()
            participant = hub.addPlayer(named: "Player", contexts: [.init(name: "play", bindings: [
                .init(key, control: .key("space")), .init(pointer, control: .pointerButton(0)),
                .init(fold, control: .hinge)
            ])])
            participantID = participant.id
            session = GameInputSession()
            presenter = Presenter(host: host)
            host.levels.presentation = presenter
            session.configure(nil, hub: hub)
            session.hinge.configure(.init(smoothing: 0))
            session.availability = .init(visible: true, focused: true, sceneActive: true,
                                         scopeActive: true, windowActive: true)
            session.bind([.init(id: host.inputHostID, host: host)])
            host.updateHingeState(.init(angle: .pi, status: .fullyOpen))
            try hub.assign(.keyboard, to: participant)
            try hub.assign(.pointer, to: participant)
            try hub.assign(.hinge, to: participant)
        }

        func pressButtons() {
            session.router.key("space", pressed: false)
            session.router.pointer(0, pressed: false)
            session.router.key("space", pressed: true)
            session.router.pointer(0, pressed: true)
            #expect(participant.input.value(for: key).isPressed)
            #expect(participant.input.value(for: pointer).isPressed)
        }

        func pressAll() {
            pressButtons()
            host.updateHingeState(neutral); host.updateHingeState(held)
            #expect(participant.input.value(for: fold) == .axis(1))
        }

        func expectStable(_ geometry: GameSurfaceGeometry) {
            #expect(host.world === world && host.renderer === renderer && world.observer === renderer)
            #expect(content.levels === host.levels && content.levels.world === world)
            #expect(player.id == playerID && world.entity(withID: playerID) === player)
            #expect(player.parent === world.root && renderer.node(for: player) === playerNode)
            #expect(world.entity(withID: camera.id) === camera && camera.parent === world.root)
            #expect(renderer.node(for: camera) === cameraNode && renderer.camera === nativeCamera)
            #expect(world.activeCamera === camera && camera.position == player.position)
            #expect(content.surfaceGeometry == geometry && renderer.surfaceGeometry == geometry)
            #expect(renderer.size == geometry.size)
            #expect(hub.owner(of: .keyboard) === participant && hub.owner(of: .pointer) === participant)
            #expect(hub.owner(of: .hinge) === participant && participant.id == participantID)
            #expect(session.router.hasBackendLease && hub.isEnabled && participant.isEnabled)
        }

        func expectNeutral() {
            #expect(!participant.input.value(for: key).isPressed)
            #expect(!participant.input.value(for: pointer).isPressed)
            #expect(participant.input.value(for: fold) == .axis(0))
        }

        func expectRecoveryNeedsFreshNeutral() {
            #expect(session.router.isActive && !host.levelInputBlocked)
            session.router.key("space", pressed: true, isRepeat: true)
            session.router.pointer(0, pressed: true)
            host.updateHingeState(held)
            session.refresh()
            expectNeutral()
            pressAll()
        }
    }

    private func waitUntil(_ predicate: () -> Bool) async throws {
        for _ in 0..<1000 {
            if predicate() { return }
            await Task.yield()
        }
        try #require(predicate(), "Level operation did not reach its checkpoint")
    }

    @Test func foldingDuringPreparationAndInstallationPreservesPersistentSceneAndCompletesOnce() async throws {
        let f = try await Fixture(), gate = PreparationGate()
        defer { f.session.stop() }
        let incoming = Entity(name: "incoming")
        var activations = 0, loads = 0, cancellations = 0, updates = 0
        let loaded = f.world.subscribe(to: LevelEvents.DidLoad.self) { _ in loads += 1 }
        let cancelled = f.world.subscribe(to: LevelEvents.DidCancel.self) { _ in cancellations += 1 }
        let tick = f.world.subscribe(to: WorldEvents.Update.self) { _ in updates += 1 }
        defer { loaded.cancel(); cancelled.cancel(); tick.cancel() }
        let task = Task { try await f.content.levels.load(id: "incoming", transition: .instant) { context in
            context.camera = f.camera
            context.onActivate { root in
                activations += 1
                #expect(root === incoming && f.host.levels.phase == .installing)
                #expect(f.host.levelInputBlocked && f.host.levels.blocksInput)
                for surface in Surface.allCases {
                    f.host.updateSurfaceGeometry(surface.geometry)
                    f.expectStable(surface.geometry)
                    #expect(f.host.levels.currentRoot === incoming && f.host.levels.phase == .installing)
                }
            }
            return try await gate.value()
        } }
        defer { task.cancel(); gate.finish(.failure(CancellationError())) }
        try await waitUntil { gate.waiting }
        f.pressAll()
        for surface in Surface.allCases {
            let id = f.host.beginInput(at: CGPoint(x: 50, y: 50))
            let contact = try #require(f.host.inputContacts[id])
            f.host.updateSurfaceGeometry(surface.geometry)
            #expect(contact.cancelled && f.host.inputContacts.isEmpty)
            #expect(f.participant.input.state(for: f.key).phase == .cancelled)
            #expect(f.participant.input.state(for: f.pointer).phase == .cancelled)
            #expect(f.participant.input.value(for: f.fold) == .axis(1))
            f.session.refresh()
            #expect(f.host.levels.phase == .preparing && !f.host.levels.blocksInput)
            #expect(f.host.levels.currentRoot === f.outgoing && f.outgoing.isActive)
            f.expectStable(surface.geometry)
            f.session.router.key("space", pressed: true, isRepeat: true)
            f.session.router.pointer(0, pressed: true)
            #expect(!f.participant.input.value(for: f.key).isPressed)
            #expect(!f.participant.input.value(for: f.pointer).isPressed)
            f.pressButtons()
        }
        gate.finish(.success(incoming))
        let installed = try await task.value
        #expect(installed === incoming && f.host.levels.currentRoot === incoming)
        #expect(f.outgoing.world == nil && activations == 1 && loads == 1 && cancellations == 0)
        #expect(f.host.levels.phase == .idle && !f.host.levels.blocksInput && updates == 0)
        #expect(f.presenter.gateChanges == [true, false])
        f.expectStable(Surface.flat.geometry)
        f.expectRecoveryNeedsFreshNeutral()
    }

    @Test(arguments: [false, true])
    func failedOrCancelledPreparationAfterFoldingKeepsOutgoingSceneAndAllowsRetry(cancel: Bool) async throws {
        let f = try await Fixture(), gate = PreparationGate()
        defer { f.session.stop() }
        var cleanup = 0, activations = 0, failures = 0
        var cancellations: [Bool] = []
        let failed = f.world.subscribe(to: LevelEvents.DidFail.self) { _ in failures += 1 }
        let cancelled = f.world.subscribe(to: LevelEvents.DidCancel.self) { cancellations.append($0.committed) }
        defer { failed.cancel(); cancelled.cancel() }
        let stale = Entity(name: "stale")
        let task = Task { try await f.host.levels.load(id: "pending", transition: .fade(duration: 30)) { context in
            context.onUnload { cleanup += 1 }
            context.onActivate { _ in activations += 1 }
            return try await gate.value()
        } }
        defer { task.cancel(); gate.finish(.failure(CancellationError())) }
        try await waitUntil { gate.waiting }
        for surface in Surface.allCases {
            f.host.updateSurfaceGeometry(surface.geometry)
            #expect(f.host.levels.phase == .preparing && f.host.levels.currentRoot === f.outgoing)
            #expect(!f.host.levelInputBlocked && cleanup == 0)
            f.expectStable(surface.geometry)
            f.pressAll()
        }
        if cancel {
            // Deliberately noncooperative preparation must never install late.
            f.host.levels.cancel()
            gate.finish(.success(stale))
            await #expect(throws: CancellationError.self) { try await task.value }
        } else {
            gate.finish(.failure(Failure.preparation))
            await #expect(throws: Failure.preparation) { try await task.value }
        }
        #expect(f.host.levels.currentRoot === f.outgoing && f.host.levels.currentID == "outgoing")
        #expect(f.outgoing.isActive && stale.world == nil && cleanup == 1 && activations == 0)
        #expect(failures == (cancel ? 0 : 1) && cancellations == (cancel ? [false] : []))
        #expect(f.host.levels.phase == .idle && !f.host.levels.blocksInput && !f.host.levelInputBlocked)
        #expect(f.host.levels.overlayOpacity == 0 && f.host.levels.outgoingImage == nil)
        #expect(f.presenter.gateChanges.isEmpty && f.session.router.isActive)
        f.expectStable(Surface.flat.geometry)
        f.pressAll()
        let retry = try await f.host.levels.load(id: "retry", transition: .instant) { context in
            context.camera = f.camera
            return Entity(name: "retry")
        }
        #expect(f.host.levels.currentRoot === retry && f.outgoing.world == nil)
        f.expectStable(Surface.flat.geometry)
        f.expectRecoveryNeedsFreshNeutral()
    }

    @Test(arguments: [false, true])
    func foldingDuringTransitionRetainsAssignmentsAndCancellationRequiresFreshNeutral(crossFade: Bool) async throws {
        let f = try await Fixture()
        defer { f.session.stop() }
        f.pressAll()
        let id = f.host.beginInput(at: CGPoint(x: 50, y: 50))
        let contact = try #require(f.host.inputContacts[id])
        let incoming = Entity(name: "incoming")
        var activations = 0, cleanup = 0, updates = 0
        var cancellations: [Bool] = []
        let cancelled = f.world.subscribe(to: LevelEvents.DidCancel.self) { cancellations.append($0.committed) }
        let tick = f.world.subscribe(to: WorldEvents.Update.self) { _ in updates += 1 }
        defer { cancelled.cancel(); tick.cancel() }
        let task = Task { try await f.host.levels.load(id: "incoming",
            transition: crossFade ? .crossFade(duration: 30) : .fade(duration: 30)) { context in
                context.camera = f.camera
                context.onActivate { _ in activations += 1 }
                context.onUnload { cleanup += 1 }
                return incoming
            }
        }
        // Cancel the task too, so the production animation's sleep is interrupted.
        defer { f.host.levels.cancel(); task.cancel() }
        let phase: LevelCoordinator.Phase = crossFade ? .crossFading : .fadingOut
        try await waitUntil { f.host.levels.phase == phase }
        #expect(contact.cancelled && f.host.inputContacts.isEmpty)
        #expect(f.participant.input.state(for: f.key).phase == .cancelled)
        #expect(f.participant.input.state(for: f.pointer).phase == .cancelled)
        #expect(f.participant.input.state(for: f.fold).phase == .cancelled)
        let image = f.host.levels.outgoingImage
        for surface in Surface.allCases {
            f.host.updateSurfaceGeometry(surface.geometry)
            f.session.refresh()
            #expect(f.host.levels.phase == phase && f.host.levels.blocksInput && f.host.levelInputBlocked)
            #expect(!f.session.router.isActive && cancellations.isEmpty && updates == 0)
            #expect(f.host.levels.currentRoot === (crossFade ? incoming : f.outgoing))
            #expect(f.host.levels.outgoingImage == image)
            f.expectStable(surface.geometry)
            // Neither routed nor direct values can bypass the suppression lease.
            f.session.router.key("space", pressed: true, isRepeat: true)
            f.session.router.pointer(0, pressed: true)
            f.participant.input.setValue(.button(true), for: .key("space"), device: .keyboard)
            f.participant.input.setValue(.button(true), for: .pointerButton(0), device: .pointer)
            // Cached neutral while blocked cannot arm the sensor on resume.
            f.host.updateHingeState(f.neutral)
            f.expectNeutral()
        }
        #expect(f.presenter.captures == (crossFade ? 1 : 0))
        #expect((image != nil) == crossFade && activations == (crossFade ? 1 : 0))
        f.host.levels.cancel()
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(cancellations == [crossFade] && cleanup == (crossFade ? 0 : 1))
        #expect(f.host.levels.currentRoot === (crossFade ? incoming : f.outgoing))
        #expect(crossFade ? f.outgoing.world == nil : f.outgoing.isActive)
        #expect(f.host.levels.phase == .idle && !f.host.levels.blocksInput)
        #expect(f.host.levels.overlayOpacity == 0 && f.host.levels.outgoingImage == nil)
        #expect(f.presenter.gateChanges == [true, false] && updates == 0)
        f.expectStable(Surface.flat.geometry)
        f.expectRecoveryNeedsFreshNeutral()
    }
}
