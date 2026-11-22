import ECSCore
@testable import SpriteBackend
import SpriteKit
import Testing

/// SpriteKit stores velocities as `Float`s, so they come back a hair off.
private func close(_ a: CGVector?, _ dx: CGFloat, _ dy: CGFloat) -> Bool {
    guard let a else { return false }
    return abs(a.dx - dx) < 1e-3 && abs(a.dy - dy) < 1e-3
}

private func close(_ a: SIMD2<Float>?, _ b: SIMD2<Float>) -> Bool {
    guard let a else { return false }
    return abs(a.x - b.x) < 1e-3 && abs(a.y - b.y) < 1e-3
}

/// SpriteKit only steps the simulation inside a presented `SKView`, so these tests play
/// the simulation's part: they move nodes and bodies by hand, then run the renderer's
/// end-of-step work.
@MainActor @Suite struct PhysicsTests {
    private func makeBall(_ world: World, _ renderer: SpriteRenderer) -> (Entity, SKNode) {
        let ball = Entity(components: PhysicsBodyComponent(shape: .circle(radius: 10), restitution: 0.8))
        ball.position = [0, 100]
        world.addEntity(ball)
        return (ball, renderer.node(for: ball)!)
    }

    @Test func componentBecomesABody() throws {
        let world = World()
        let renderer = SpriteRenderer(world: world)
        let crate = Entity(components: PhysicsBodyComponent(
            shape: .rectangle(size: [20, 10]), mass: 3, friction: 0.7, affectedByGravity: false,
            categoryBitMask: 0b10, collisionBitMask: 0b01, contactTestBitMask: 0b100, velocity: [5, 6]
        ))
        world.addEntity(crate)
        let body = try #require(renderer.node(for: crate)?.physicsBody)
        #expect(body.isDynamic)
        #expect(abs(body.mass - 3) < 1e-4)
        #expect(abs(body.friction - 0.7) < 1e-4)
        #expect(!body.affectedByGravity)
        #expect(body.categoryBitMask == 0b10 && body.collisionBitMask == 0b01 && body.contactTestBitMask == 0b100)
        #expect(close(body.velocity, 5, 6))
    }

    @Test func edgesAreStatic() throws {
        let world = World()
        let renderer = SpriteRenderer(world: world)
        let room = Entity(components: PhysicsBodyComponent(shape: .edgeLoop(rectangle: [300, 200])))
        world.addEntity(room)
        #expect(room.components[PhysicsBodyComponent.self]?.isDynamic == false)
        #expect(try #require(renderer.node(for: room)?.physicsBody).isDynamic == false)
    }

    @Test func changesReachTheBody() throws {
        let world = World()
        let renderer = SpriteRenderer(world: world)
        let (ball, node) = makeBall(world, renderer)
        let first = try #require(node.physicsBody)

        ball.components[PhysicsBodyComponent.self]?.restitution = 0.1
        renderer.flush()
        #expect(node.physicsBody === first)
        #expect(abs(first.restitution - 0.1) < 1e-4)

        // A new shape is a new body that keeps moving the same way.
        first.velocity = CGVector(dx: 30, dy: 0)
        renderer.didSimulatePhysics()
        ball.components[PhysicsBodyComponent.self]?.shape = .rectangle(size: [20, 20])
        renderer.flush()
        let second = try #require(node.physicsBody)
        #expect(second !== first)
        #expect(close(second.velocity, 30, 0))

        ball.components[PhysicsBodyComponent.self] = nil
        renderer.flush()
        #expect(node.physicsBody == nil)
    }

    @Test func simulationResultsComeBackWithoutBeingChanges() {
        let world = World()
        let renderer = SpriteRenderer(world: world)
        let (ball, node) = makeBall(world, renderer)

        // The simulation moves the ball.
        node.position = CGPoint(x: 4, y: 80)
        node.zRotation = 0.5
        node.physicsBody!.velocity = CGVector(dx: 2, dy: -40)
        node.physicsBody!.angularVelocity = 1.5
        renderer.didSimulatePhysics()

        #expect(ball.position == [4, 80])
        #expect(ball.transform.rotation == 0.5)
        #expect(close(ball.components[PhysicsBodyComponent.self]?.velocity, [2, -40]))
        #expect(abs((ball.components[PhysicsBodyComponent.self]?.angularVelocity ?? 0) - 1.5) < 1e-3)

        // Nothing is pending, so a flush doesn't push stale values back.
        node.position = CGPoint(x: 6, y: 60)
        node.physicsBody!.velocity = CGVector(dx: 2, dy: -60)
        renderer.flush()
        #expect(node.position == CGPoint(x: 6, y: 60))

        // Unrelated edits don't rewrite position or velocity either.
        ball.transform.zPosition = 3
        ball.components[PhysicsBodyComponent.self]?.friction = 0.9
        renderer.flush()
        #expect(node.position == CGPoint(x: 6, y: 60))
        #expect(close(node.physicsBody!.velocity, 2, -60))
        #expect(node.zPosition == 3)
    }

    @Test func modelEditsOverrideTheSimulation() {
        let world = World()
        let renderer = SpriteRenderer(world: world)
        let (ball, node) = makeBall(world, renderer)

        // Teleported and launched mid-step, say from a contact handler.
        node.position = CGPoint(x: 0, y: 90)
        ball.position = [50, 50]
        ball.components[PhysicsBodyComponent.self]?.velocity = [0, 300]
        renderer.didSimulatePhysics()
        #expect(ball.position == [50, 50])
        #expect(ball.components[PhysicsBodyComponent.self]?.velocity == [0, 300])

        renderer.flush()
        #expect(node.position == CGPoint(x: 50, y: 50))
        #expect(close(node.physicsBody!.velocity, 0, 300))
    }

    @Test func staticBodiesAreLeftAlone() {
        let world = World()
        let renderer = SpriteRenderer(world: world)
        let wall = Entity(components: PhysicsBodyComponent(shape: .rectangle(size: [10, 10]), isDynamic: false))
        wall.position = [20, 0]
        world.addEntity(wall)
        renderer.node(for: wall)!.position = .zero
        renderer.didSimulatePhysics()
        #expect(wall.position == [20, 0])
    }

    @Test func contactsArePublishedOnceToEachSubscriber() {
        let world = World()
        let renderer = SpriteRenderer(world: world)
        let (ball, ballNode) = makeBall(world, renderer)
        let floor = Entity(components: PhysicsBodyComponent(shape: .edgeChain([[-100, 0], [100, 0]])))
        let bystander = Entity()
        world.addEntity(floor)
        world.addEntity(bystander)
        let floorNode = renderer.node(for: floor)!

        var everywhere: [PhysicsEvents.ContactBegan] = []
        var onBall: [Entity] = []
        var onFloor: [Entity] = []
        var onBystander = 0
        var ended = 0
        let subscriptions = [
            world.subscribe(to: PhysicsEvents.ContactBegan.self) { everywhere.append($0) },
            world.subscribe(to: PhysicsEvents.ContactBegan.self, on: ball) { onBall.append($0.other(than: ball)) },
            world.subscribe(to: PhysicsEvents.ContactBegan.self, on: floor) { onFloor.append($0.other(than: floor)) },
            world.subscribe(to: PhysicsEvents.ContactBegan.self, on: bystander) { _ in onBystander += 1 },
            world.subscribe(to: PhysicsEvents.ContactEnded.self, on: floor) { _ in ended += 1 },
        ]

        renderer.reportContact(between: ballNode, and: floorNode, began: true,
                               point: CGPoint(x: 3, y: 0), normal: CGVector(dx: 0, dy: -1), impulse: 12)
        #expect(everywhere.isEmpty, "contacts wait until the step is over")
        renderer.didSimulatePhysics()

        #expect(everywhere.count == 1)
        #expect(everywhere.first?.point == [3, 0] && everywhere.first?.normal == [0, -1])
        #expect(everywhere.first?.impulse == 12)
        #expect(onBall.map(\.id) == [floor.id])
        #expect(onFloor.map(\.id) == [ball.id])
        #expect(onBystander == 0)

        renderer.reportContact(between: ballNode, and: floorNode, began: false)
        renderer.didSimulatePhysics()
        #expect(ended == 1)
        _ = subscriptions
    }

    @Test func contactsWithRemovedEntitiesAreDropped() {
        let world = World()
        let renderer = SpriteRenderer(world: world)
        let (ball, ballNode) = makeBall(world, renderer)
        let (other, otherNode) = makeBall(world, renderer)
        var count = 0
        let subscription = world.subscribe(to: PhysicsEvents.ContactBegan.self) { _ in count += 1 }

        renderer.reportContact(between: ballNode, and: otherNode, began: true)
        world.removeEntity(other)
        renderer.didSimulatePhysics()
        #expect(count == 0)

        // Nodes no longer in the world aren't reported at all.
        renderer.reportContact(between: ballNode, and: otherNode, began: true)
        renderer.didSimulatePhysics()
        #expect(count == 0)
        _ = (ball, subscription)
    }

    @Test func gravityIsTheWorldsGravity() {
        let renderer = SpriteRenderer(world: World())
        #expect(abs(renderer.gravity.y + 9.8) < 1e-4)
        renderer.gravity = [1, -3]
        #expect(renderer.physicsWorld.gravity == CGVector(dx: 1, dy: -3))
    }
}
