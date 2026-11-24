@_spi(Backend) @testable import ECSCore
@testable import SpriteBackend
import Foundation
import SpriteKit
import Testing

@MainActor @Suite struct NetworkPresentationTests {
    @MainActor private struct Fixture {
        let hub: InMemoryNetwork
        let hostWorld: World
        let clientWorld: World
        let host: NetworkSession
        let client: NetworkSession
        let actor: Entity
        let renderer: SpriteRenderer
        var replica: Entity { client.entity(withNetworkID: actor.components[SynchronizationComponent.self]!.id)! }
        var node: SKNode { renderer.node(for: replica)! }

        init() throws {
            hub = InMemoryNetwork()
            let hostPeer = NetworkPeer(id: .init(rawValue: "host"), displayName: "Host")
            let clientPeer = NetworkPeer(id: .init(rawValue: "client"), displayName: "Client")
            let ht = try hub.connect(hostPeer), ct = try hub.connect(clientPeer)
            hostWorld = World(); clientWorld = World()
            actor = Entity(name: "actor", components: SynchronizationComponent())
            hostWorld.addEntity(actor)
            host = NetworkSession(world: hostWorld, transport: ht, role: .host,
                                  configuration: .init(interpolationDuration: 0.2))
            client = NetworkSession(world: clientWorld, transport: ct, role: .client(host: hostPeer.id),
                                    configuration: .init(interpolationDuration: 0.2))
            try host.start(); try client.start()
            hostWorld.systems.setEnabled(false, for: NetworkReplicationSystem.self)
            clientWorld.systems.setEnabled(false, for: NetworkReplicationSystem.self)
            for _ in 0..<3 { hub.advance(by: 0); host.update(deltaTime: 0); client.update(deltaTime: 0) }
            renderer = SpriteRenderer(world: clientWorld, size: CGSize(width: 240, height: 100))
            replica.components.set(SpriteComponent(color: .cyan, size: [10, 10]))
            replica.components.set(InputTargetComponent())
            frame()
        }

        func move(to pose: Transform, elapsed: TimeInterval) throws {
            actor.transform = pose
            try host.synchronize()
            hub.advance(by: 0); client.update(deltaTime: elapsed)
            frame()
        }
        func frame() {
            renderer.update(0); renderer.didSimulatePhysics(); renderer.didFinishUpdate()
        }
    }

    @Test func remotePresentationDoesNotNeedFixedClockOrChangeCanonicalState() throws {
        let f = try Fixture()
        try f.move(to: Transform(translation: [100, 0]), elapsed: 0.1)
        #expect(f.clientWorld.fixedStep == nil)
        #expect(f.replica.position == [100, 0])
        #expect(f.replica.snapshot()[Transform.self]?.translation == [100, 0])
        #expect(abs(f.node.position.x - 50) < 0.0001)
        #expect(abs(f.replica.presentation.position.x - 50) < 0.0001)
        #expect(f.renderer.inputTarget(at: CGPoint(x: 50, y: 0)) === f.replica)
        #expect(f.replica.position == [100, 0])
        f.client.update(deltaTime: 0.1); f.frame()
        #expect(f.node.position.x == 100)
    }

    @Test func pauseAndExplicitFlushExposeLatestCanonicalTransform() throws {
        let f = try Fixture()
        try f.move(to: Transform(translation: [100, 0]), elapsed: 0.1)
        f.renderer.flush()
        #expect(f.node.position.x == 100)
        f.frame()
        #expect(f.node.position.x == 50)
        f.clientWorld.isPaused = true; f.frame()
        #expect(f.node.position.x == 100)
        #expect(f.replica.position == [100, 0])
    }

    @Test func localNativePhysicsAndConstraintsRetainTransformOwnership() throws {
        let f = try Fixture()
        f.replica.components.set(PhysicsBodyComponent(shape: .circle(radius: 4), isDynamic: false))
        try f.move(to: Transform(translation: [100, 0]), elapsed: 0.1)
        #expect(f.node.position.x == 100)
        f.replica.components.remove(PhysicsBodyComponent.self)
        let constraint = SKConstraint.positionX(SKRange(constantValue: 100))
        f.node.constraints = [constraint]
        f.frame()
        #expect(f.node.position.x == 100)
    }

    @Test func followCameraUsesDisplayedRemotePoseAndStopPreservesLocalCamera() throws {
        let f = try Fixture()
        let camera = Entity(name: "local camera", components: CameraComponent(target: .entity(f.replica.id), smoothing: 0))
        f.clientWorld.addEntity(camera)
        try f.move(to: Transform(translation: [100, 0]), elapsed: 0.1)
        #expect(abs(camera.position.x - 50) < 0.0001)
        let replicaID = f.replica.id
        f.client.stop(); f.renderer.flush()
        #expect(f.clientWorld.entity(withID: replicaID) == nil)
        #expect(f.clientWorld.entity(withID: camera.id) === camera)
        #expect(f.renderer.node(for: camera) != nil)
    }

    @Test func shortestRotationAndScaleArePresentationOnly() throws {
        let f = try Fixture()
        try f.move(to: Transform(translation: [40, 20], rotation: 1.5 * .pi, scale: [3, 5], zPosition: 4), elapsed: 0.1)
        #expect(abs(f.node.zRotation + .pi / 4) < 0.0001)
        #expect(f.node.xScale == 2)
        #expect(f.node.yScale == 3)
        #expect(f.node.zPosition == 2)
        #expect(f.replica.transform.scale == [3, 5])
        #expect(f.replica.transform == f.actor.transform)
    }
}
