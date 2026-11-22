import ECSCore
import Foundation
import Gameplay
import GameplayECS
import Testing

private func length(_ v: SIMD2<Float>) -> Float { (v * v).sum().squareRoot() }

/// Runs `steps` frames of `force` at 60 fps.
private func simulate(_ agent: inout SteeringAgent, steps: Int, force: (SteeringAgent) -> SIMD2<Float>) {
    for _ in 0..<steps { agent.apply(force(agent), deltaTime: 1 / 60) }
}

@Suite struct SteeringAgentTests {
    @Test func applyCapsForceAndSpeed() {
        var agent = SteeringAgent(maxSpeed: 10, maxForce: 100)
        agent.apply([1000, 0], deltaTime: 0.05)
        // Force capped at 100 → 5 pt/s after 0.05 s.
        #expect(abs(agent.velocity.x - 5) < 1e-4)
        for _ in 0..<100 { agent.apply([1000, 0], deltaTime: 0.05) }
        #expect(abs(agent.speed - 10) < 1e-4)
        #expect(agent.heading == [1, 0])
    }

    @Test func massSlowsResponse() {
        var light = SteeringAgent(maxSpeed: 100, maxForce: 50)
        var heavy = SteeringAgent(maxSpeed: 100, maxForce: 50, mass: 5)
        light.apply([50, 0], deltaTime: 0.1)
        heavy.apply([50, 0], deltaTime: 0.1)
        #expect(abs(light.velocity.x - 5 * heavy.velocity.x) < 1e-4)
    }

    @Test func standingStillHasNoHeading() {
        #expect(SteeringAgent(maxSpeed: 1, maxForce: 1).heading == nil)
    }

    @Test func codableRoundTrip() throws {
        let agent = SteeringAgent(position: [1, 2], velocity: [3, 4], maxSpeed: 5, maxForce: 6, mass: 2, radius: 7)
        let decoded = try JSONDecoder().decode(SteeringAgent.self, from: JSONEncoder().encode(agent))
        #expect(decoded == agent)
    }
}

@Suite struct SteeringBehaviorTests {
    let base = SteeringAgent(maxSpeed: 100, maxForce: 400)

    @Test func seekReachesTarget() {
        var agent = base
        simulate(&agent, steps: 120) { Steering.seek($0, toward: [100, 0]) }
        // Seek overshoots and orbits, but should have got there.
        #expect(length(agent.position - [100, 0]) < 40)
    }

    @Test func fleeOnlyInsidePanicDistance() {
        var agent = base
        agent.position = [10, 0]
        #expect(Steering.flee(agent, from: .zero, panicDistance: 5) == .zero)
        let force = Steering.flee(agent, from: .zero, panicDistance: 50)
        #expect(force.x > 0 && abs(force.y) < 1e-4)
        // On top of the threat it still picks a way out.
        agent.position = .zero
        #expect(Steering.flee(agent, from: .zero) != .zero)
    }

    @Test func arriveStopsOnTarget() {
        var agent = base
        simulate(&agent, steps: 600) { Steering.arrive($0, at: [200, 50], slowingRadius: $0.brakingDistance * 2) }
        #expect(length(agent.position - [200, 50]) < 1)
        #expect(agent.speed < 1)
    }

    @Test func pursueLeadsTheTarget() {
        let agent = base
        let force = Steering.pursue(agent, target: [100, 0], moving: [0, 100])
        // Aims ahead of the target, so up as well as right.
        #expect(force.x > 0 && force.y > 0)
        let away = Steering.evade(agent, threat: [100, 0], moving: [0, 100])
        #expect(away.x < 0 && away.y < 0)
        #expect(Steering.evade(agent, threat: [100, 0], moving: .zero, panicDistance: 50) == .zero)
    }

    @Test func flocking() {
        var agent = base
        agent.velocity = [0, 10]
        let neighbors: [SIMD2<Float>] = [[10, 0], [10, 10]]
        let apart = Steering.separate(agent, from: neighbors)
        #expect(apart.x < 0)
        let together = Steering.cohere(agent, with: neighbors)
        #expect(together.x > 0)
        let aligned = Steering.align(agent, with: [[100, 0], [50, 0]])
        #expect(aligned.x > 0 && aligned.y < 0)
        #expect(Steering.separate(agent, from: []) == .zero)
        #expect(Steering.cohere(agent, with: []) == .zero)
        #expect(Steering.align(agent, with: []) == .zero)
    }

    @Test func avoidSwervesAroundObstacle() {
        var agent = base
        agent.radius = 5
        agent.velocity = [100, 0]
        let rock = CircleObstacle(center: [60, 3], radius: 20)
        let force = Steering.avoid(agent, obstacles: [rock])
        // Obstacle is slightly left of the line, so swerve right (−y) and brake.
        #expect(force.y < 0 && force.x < 0)
        #expect(Steering.avoid(agent, obstacles: [CircleObstacle(center: [-60, 0], radius: 20)]) == .zero)
        #expect(Steering.avoid(agent, obstacles: [CircleObstacle(center: [60, 80], radius: 20)]) == .zero)

        // Driving straight at it with avoidance never ends up inside.
        var closest = Float.infinity
        agent = base
        agent.radius = 5
        agent.position = [-100, 1]
        for _ in 0..<240 {
            let force = Steering.seek(agent, toward: [200, 0]) + 3 * Steering.avoid(agent, obstacles: [CircleObstacle(center: .zero, radius: 30)])
            agent.apply(force, deltaTime: 1 / 60)
            closest = min(closest, length(agent.position))
        }
        #expect(closest > 30)
        #expect(agent.position.x > 100)
    }

    @Test func overlappingObstaclePushesOut() {
        var agent = base
        agent.position = [5, 0]
        let force = Steering.avoid(agent, obstacles: [CircleObstacle(center: .zero, radius: 20)])
        #expect(force.x > 0)
    }

    @Test func stayWithinTurnsBack() {
        var agent = base
        let box = BoundingBox(center: .zero, size: [200, 200])
        agent.position = [95, 0]
        agent.velocity = [50, 0]
        #expect(Steering.stay(agent, within: box, margin: 10).x < 0)
        agent.position = .zero
        #expect(Steering.stay(agent, within: box, margin: 10) == .zero)
    }

    @Test func wanderIsDeterministicAndBounded() {
        func run() -> SteeringAgent {
            var agent = base
            agent.velocity = [50, 0]
            var wander = Wander()
            var rng = SeededGenerator(seed: 4)
            simulate(&agent, steps: 300) { wander.force(for: $0, deltaTime: 1 / 60, using: &rng) }
            return agent
        }
        let a = run(), b = run()
        #expect(a == b)
        #expect(a.speed <= base.maxSpeed + 1e-3)
        #expect(length(a.position) > 50)
    }
}

@Suite struct SteeringPathTests {
    let square = SteeringPath(points: [[0, 0], [100, 0], [100, 100], [0, 100]], radius: 5, isClosed: true)

    @Test func measuresAlongThePath() {
        #expect(square.length == 400)
        #expect(square.point(atDistance: 150) == [100, 50])
        #expect(square.point(atDistance: 450) == [50, 0])
        #expect(square.point(atDistance: -50) == [0, 50])
        #expect(square.distance(closestTo: [110, 30]) == 130)

        let open = SteeringPath(points: [[0, 0], [10, 0]])
        #expect(open.length == 10)
        #expect(open.point(atDistance: 99) == [10, 0])
        #expect(SteeringPath(points: [[3, 3]]).point(atDistance: 5) == [3, 3])
    }

    @Test func followStaysNearAClosedPath() {
        var agent = SteeringAgent(position: [0, 0], maxSpeed: 80, maxForce: 400)
        var worst: Float = 0
        var travelled: Float = 0
        for step in 0..<600 {
            let before = agent.position
            agent.apply(Steering.follow(agent, path: square), deltaTime: 1 / 60)
            travelled += length(agent.position - before)
            if step > 60 {
                let along = square.distance(closestTo: agent.position)
                worst = max(worst, length(square.point(atDistance: along) - agent.position))
            }
        }
        #expect(worst < 20)
        #expect(travelled > 400)  // went all the way round
    }

    @Test func followStopsAtEndOfOpenPath() {
        let path = SteeringPath(points: [[0, 0], [100, 0], [100, 100]])
        var agent = SteeringAgent(maxSpeed: 80, maxForce: 300)
        simulate(&agent, steps: 900) { Steering.follow($0, path: path) }
        #expect(length(agent.position - [100, 100]) < 2)
        #expect(agent.speed < 2)
    }

    @Test func codableRoundTrip() throws {
        let decoded = try JSONDecoder().decode(SteeringPath.self, from: JSONEncoder().encode(square))
        #expect(decoded == square)
        #expect(decoded.length == 400)
        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(SteeringPath.self, from: Data(#"{"points":[],"radius":1,"isClosed":false}"#.utf8))
        }
    }
}

@MainActor @Suite(.serialized) struct SteeringSystemTests {
    @Test func arrivesAtAPoint() {
        let world = World()
        world.addSystem(SteeringSystem.self)
        let entity = Entity()
        entity.components.set(SteeringComponent(
            maxSpeed: 100, maxForce: 300, orientsToVelocity: true,
            goals: [SteeringGoal(.arrive(.point([100, 0])))]
        ))
        world.addEntity(entity)
        world.update(deltaTime: 0.1)
        #expect(entity.position.x > 0)
        #expect(abs(entity.transform.rotation) < 1e-4)
        for _ in 0..<600 { world.update(deltaTime: 1 / 60) }
        #expect(length(entity.position - [100, 0]) < 1)
        #expect(length(entity.components[SteeringComponent.self]!.velocity) < 1)
    }

    @Test func pursuesAnotherEntity() {
        let world = World()
        world.addSystem(SteeringSystem.self)
        let prey = Entity()
        prey.position = [200, 0]
        prey.components.set(SteeringComponent(maxSpeed: 40, maxForce: 200, velocity: [0, 40], goals: [
            SteeringGoal(.seek(.point([200, 10_000]))),
        ]))
        let hunter = Entity()
        hunter.components.set(SteeringComponent(maxSpeed: 120, maxForce: 400, goals: [SteeringGoal(.pursue(prey.id))]))
        world.addEntity(prey)
        world.addEntity(hunter)
        var closest = Float.infinity
        for _ in 0..<300 {
            world.update(deltaTime: 1 / 60)
            closest = min(closest, length(hunter.position - prey.position))
        }
        #expect(closest < 10)
    }

    @Test func avoidsObstacleEntities() {
        let world = World()
        world.addSystem(SteeringSystem.self)
        let rock = Entity()
        rock.components.set(SteeringObstacleComponent(radius: 30))
        world.addEntity(rock)
        let mover = Entity()
        mover.position = [-150, 2]
        mover.components.set(SteeringComponent(maxSpeed: 100, maxForce: 400, radius: 5, goals: [
            SteeringGoal(.seek(.point([300, 0]))),
            SteeringGoal(.avoidObstacles(), weight: 3),
        ]))
        world.addEntity(mover)
        var closest = Float.infinity
        for _ in 0..<300 {
            world.update(deltaTime: 1 / 60)
            closest = min(closest, length(mover.position))
        }
        #expect(closest > 30)
    }

    @Test func flockSeparatesUsingSpatialIndex() {
        let world = World()
        world.addSystem(SteeringSystem.self)
        world.addSystem(SpatialIndexSystem.self)
        let boids = (0..<5).map { i in
            let boid = Entity()
            boid.position = [Float(i) * 2, 0]
            boid.components.set(SpatialIndexComponent())
            boid.components.set(SteeringComponent(maxSpeed: 60, maxForce: 200, goals: [
                SteeringGoal(.separate(radius: 30)),
            ]))
            world.addEntity(boid)
            return boid
        }
        world.updateSpatialIndex()
        for _ in 0..<120 { world.update(deltaTime: 1 / 60) }
        let spread = boids.last!.position.x - boids.first!.position.x
        #expect(spread > 30)
    }

    @Test func wanderUsesWorldRandomReproducibly() {
        func run() -> SIMD2<Float> {
            let world = World()
            world.random = SeededGenerator(seed: 11)
            world.addSystem(SteeringSystem.self)
            let entity = Entity()
            entity.components.set(SteeringComponent(maxSpeed: 50, maxForce: 100, velocity: [50, 0], goals: [
                SteeringGoal(.wander(Wander())),
            ]))
            world.addEntity(entity)
            for _ in 0..<120 { world.update(deltaTime: 1 / 60) }
            guard case .wander(let state) = entity.components[SteeringComponent.self]!.goals[0].behavior else {
                Issue.record("wander goal lost")
                return .zero
            }
            #expect(state.angle != 0)
            return entity.position
        }
        #expect(run() == run())
    }

    @Test func componentIsCodable() throws {
        let component = SteeringComponent(maxSpeed: 1, maxForce: 2, goals: [
            SteeringGoal(.flee(.entity(7), panicDistance: 40), weight: 2),
            SteeringGoal(.stayWithin(BoundingBox(center: .zero, size: [10, 10]), margin: 1)),
            SteeringGoal(.follow(SteeringPath(points: [[0, 0], [1, 1]]))),
            SteeringGoal(.cohere(radius: 5, categories: .default)),
        ])
        let decoded = try JSONDecoder().decode(SteeringComponent.self, from: JSONEncoder().encode(component))
        #expect(decoded == component)
    }
}

@Suite struct SteeringAdditionsTests {
    @Test func reachSpeedSpeedsUpAndSlowsDownWithoutTurning() {
        var agent = SteeringAgent(velocity: [0, 10], maxSpeed: 100, maxForce: 200)
        simulate(&agent, steps: 240) { Steering.reachSpeed($0, 60) }
        #expect(abs(agent.speed - 60) < 0.5)
        #expect(abs(agent.velocity.x) < 1e-3)

        simulate(&agent, steps: 240) { Steering.reachSpeed($0, 20) }
        #expect(abs(agent.speed - 20) < 0.5)
        #expect(agent.velocity.y > 0)

        // Asking for more than the top speed settles at the top speed.
        simulate(&agent, steps: 240) { Steering.reachSpeed($0, 500) }
        #expect(abs(agent.speed - 100) < 0.5)
    }

    @Test func reachSpeedSetsOffAlongXFromRest() {
        var agent = SteeringAgent(maxSpeed: 50, maxForce: 100)
        simulate(&agent, steps: 120) { Steering.reachSpeed($0, 30) }
        #expect(agent.velocity.x > 25 && abs(agent.velocity.y) < 1e-3)
    }

    @Test func stayOnPathOnlyPushesWhenLeaving() {
        let path = SteeringPath(points: [[-200, 0], [200, 0]], radius: 10)
        // Moving along the path: nothing to correct.
        let along = SteeringAgent(position: [0, 0], velocity: [50, 0], maxSpeed: 100, maxForce: 200)
        #expect(Steering.stay(along, on: path) == .zero)

        // Drifting off sideways: pushed back toward the line.
        let drifting = SteeringAgent(position: [0, 5], velocity: [0, 60], maxSpeed: 100, maxForce: 200)
        #expect(Steering.stay(drifting, on: path).y < 0)
    }

    @Test func stayOnPathKeepsAWandererClose() {
        let path = SteeringPath(points: [[-300, 0], [300, 0]], radius: 15)
        var agent = SteeringAgent(velocity: [40, 30], maxSpeed: 60, maxForce: 150)
        var wander = Wander(rate: 6)
        var random = SeededGenerator(seed: 4)
        var worst: Float = 0
        for _ in 0..<600 {
            let force = wander.force(for: agent, deltaTime: 1 / 60, using: &random) * 0.5
                + Steering.stay(agent, on: path, lookAhead: 0.5) * 3
            agent.apply(force, deltaTime: 1 / 60)
            worst = max(worst, abs(agent.position.y))
        }
        #expect(worst < 45)
    }
}

@MainActor @Suite(.serialized) struct SteeringGoalGroupTests {
    private func mover(_ goals: [SteeringGoal]) -> (World, Entity) {
        let world = World()
        world.addSystem(SteeringSystem.self)
        let entity = Entity()
        entity.components.set(SteeringComponent(maxSpeed: 100, maxForce: 200, goals: goals))
        world.addEntity(entity)
        return (world, entity)
    }

    @Test func aGroupAddsItsGoalsScaledByItsWeight() {
        let (world, entity) = mover([
            .group("east", weight: 2, [SteeringGoal(.seek(.point([1000, 0])))]),
        ])
        for _ in 0..<60 { world.update(deltaTime: 1 / 60) }
        #expect(entity.position.x > 30 && abs(entity.position.y) < 1e-3)
    }

    @Test func disabledGoalsAndGroupsDoNothing() {
        let (world, entity) = mover([
            SteeringGoal(.seek(.point([0, 1000])), name: "north", isEnabled: false),
            .group("east", [SteeringGoal(.seek(.point([1000, 0])))]),
        ])
        #expect(entity.components[SteeringComponent.self]?.setEnabled(false, named: "east") == true)
        // Already off: nothing changes.
        #expect(entity.components[SteeringComponent.self]?.setEnabled(false, named: "east") == false)
        #expect(entity.components[SteeringComponent.self]?.isEnabled(named: "east") == false)
        #expect(entity.components[SteeringComponent.self]?.isEnabled(named: "nobody") == nil)
        for _ in 0..<30 { world.update(deltaTime: 1 / 60) }
        #expect(entity.position == .zero)

        entity.components[SteeringComponent.self]?.setEnabled(true, named: "north")
        for _ in 0..<30 { world.update(deltaTime: 1 / 60) }
        #expect(entity.position.y > 5 && entity.position.x == 0)
    }

    @Test func goalsNestedInGroupsCanBeSwitched() {
        let (world, entity) = mover([
            .group("all", [
                .group("inner", [SteeringGoal(.reachSpeed(80), name: "cruise")]),
            ]),
        ])
        entity.components[SteeringComponent.self]?.velocity = [1, 0]
        entity.components[SteeringComponent.self]?.setEnabled(false, named: "cruise")
        for _ in 0..<30 { world.update(deltaTime: 1 / 60) }
        #expect(entity.position.x < 1)

        entity.components[SteeringComponent.self]?.setEnabled(true, named: "cruise")
        for _ in 0..<240 { world.update(deltaTime: 1 / 60) }
        #expect(abs((entity.components[SteeringComponent.self]?.velocity.x ?? 0) - 80) < 1)
    }

    @Test func wanderInsideAGroupKeepsItsState() {
        let world = World()
        world.random = SeededGenerator(seed: 2)
        world.addSystem(SteeringSystem.self)
        let entity = Entity()
        entity.components.set(SteeringComponent(maxSpeed: 50, maxForce: 100, velocity: [50, 0], goals: [
            .group("roam", [SteeringGoal(.wander(Wander()))]),
        ]))
        world.addEntity(entity)
        for _ in 0..<60 { world.update(deltaTime: 1 / 60) }
        guard case .group(let goals) = entity.components[SteeringComponent.self]!.goals[0].behavior,
              case .wander(let state) = goals[0].behavior
        else {
            Issue.record("group lost its wander goal")
            return
        }
        #expect(state.angle != 0)
    }

    @Test func groupsAndSwitchesAreCodable() throws {
        let component = SteeringComponent(maxSpeed: 1, maxForce: 2, goals: [
            .group("flock", weight: 0.5, isEnabled: false, [
                SteeringGoal(.reachSpeed(3), name: "cruise"),
                SteeringGoal(.stayOn(SteeringPath(points: [[0, 0], [5, 0]], radius: 2), lookAhead: 1)),
            ]),
        ])
        let decoded = try JSONDecoder().decode(SteeringComponent.self, from: JSONEncoder().encode(component))
        #expect(decoded == component)

        // Goals saved before names and switches existed still load, switched on.
        let old = #"{"behavior":{"reachSpeed":{"_0":4}},"weight":1}"#
        let goal = try JSONDecoder().decode(SteeringGoal.self, from: Data(old.utf8))
        #expect(goal.isEnabled && goal.name == nil && goal.behavior == .reachSpeed(4))
    }
}
