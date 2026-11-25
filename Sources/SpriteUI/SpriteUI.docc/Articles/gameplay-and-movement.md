# Choosing how a character moves

A guard needs to patrol a room, walk around a wall, and stop when it reaches a doorway. Finding a route and moving along it are separate jobs. So is deciding what happens when the guard meets something that was not in the route plan.

Start with the behavior you want, then choose the code that controls position.

## Approach a destination smoothly

A character that should slow near a target needs more than a direction. Steering calculates a force from the character's current motion and a goal.

``SpriteUI/Agent2D`` holds position, velocity, and speed and force limits. ``SpriteUI/AgentGoal`` supplies force calculations. In this example, arrival pulls toward the destination while obstacle avoidance pushes away from nearby circles.

```swift
import SpriteUI

func advanceAgent(_ agent: inout Agent2D, toward destination: SIMD2<Float>,
                  avoiding obstacles: [CircleObstacle], deltaTime: Float) {
    let arrival = AgentGoal.arrive(
        agent, at: destination, slowingRadius: agent.brakingDistance
    )
    let avoidance = AgentGoal.avoid(agent, obstacles: obstacles, lookAhead: 0.5)
    agent.apply(arrival + avoidance * 2, deltaTime: deltaTime)
}
```

`agent.apply` combines the result with elapsed time, limits force and speed, then advances position. The avoidance weight of 2 makes that force twice as strong; it does not give it absolute priority over arrival.

Use positive mass and choose speed and force limits that suit the character. `seek` asks for full-speed travel toward a point; `arrive` slows near it. Other goals can use a target's motion or neighboring agents. If you use `Wander`, retain its evolving state and random generator between updates.

This calculation works without a world or renderer, which is useful when developing movement rules separately from the scene.

## Put a patrol in the scene

To apply steering to entities, store the goals in ``SpriteUI/SteeringComponent`` and install ``SpriteUI/SteeringSystem``. It reads the agents' starting state, calculates forces, and writes their movement.

Here, an ``SpriteUI/AgentPath`` describes a closed patrol loop. A second goal adds obstacle avoidance.

```swift
import SpriteUI
import SwiftUI

@MainActor
func addPatrol(to world: World) throws -> Entity {
    try world.systems.add(SteeringSystem.self)
    let route = AgentPath(
        points: [[-100, -60], [100, -60], [100, 60], [-100, 60]],
        radius: 12,
        isClosed: true
    )
    let patrol = Entity(name: "patrol", components: [
        SpriteComponent(color: .orange, size: [20, 20]),
        SteeringComponent(maxSpeed: 80, maxForce: 180, radius: 10,
                          orientsToVelocity: true, goals: [
            SteeringGoal(.follow(route), name: "patrol"),
            SteeringGoal(.avoidObstacles(lookAhead: 0.5), weight: 2)
        ])
    ])
    patrol.position = [-100, -60]
    world.addEntity(patrol)
    return patrol
}
```

The path is a line through scene points with a corridor radius. The follow goal supplies forward travel; a stay goal would keep the agent near the path without sending it along the route by itself.

The name `"patrol"` lets you switch that goal off with `components[SteeringComponent.self]?.setEnabled(false, named: "patrol")`. Named groups let you switch several goals together when the guard changes from patrolling to chasing.

Steering uses scene coordinates and converts the result through parent transforms. Entity targets use IDs that can follow a cloned or restored hierarchy.

For flocking, add ``SpriteUI/SpatialIndexComponent`` to neighbors and install ``SpriteUI/SpatialIndexSystem``. The index refreshes after steering and path following. Call `world.updateSpatialIndex()` after initial placement or a teleport when you need to query immediately.

## Find a route around a wall

Steering toward a point does not by itself find a route through a level. A graph describes places the character can visit and the connections between them. ``SpriteUI/GridGraph`` is useful when those places are tiles or cells.

This helper blocks one cell, finds a route to another, and smooths it. ``SpriteUI/GridSpace`` converts the grid cells into scene positions before the entity starts following them.

```swift
import SpriteUI

@MainActor
func startGridRoute(for entity: Entity, in world: World) throws -> Bool {
    guard entity.world === world else { return false }
    var grid = GridGraph(width: 10, height: 6, allowsDiagonals: false)
    grid.setWalkable(false, at: GridPoint(4, 2))
    let space = GridSpace(cellSize: 32, centering: grid)
    let start = space.point(at: entity.scenePosition)
    guard let path = grid.findPath(from: start, to: GridPoint(8, 4)) else {
        return false
    }
    try world.systems.add(PathFollowSystem.self)
    entity.follow(space.positions(along: grid.smoothed(path)), speed: 80,
                  orientsToPath: true)
    return true
}
```

`PathFollowSystem` moves at a steady speed and can pass several waypoints in one frame. At the end it removes the path component and publishes ``SpriteUI/PathEvents/DidFinish``. Retain an event subscription if opening the doorway depends on arrival. `stopFollowingPath()` stops without publishing completion.

For an open floor plan, ``SpriteUI/NavigationMesh`` finds routes through walkable space around polygon obstacles. Its point-based `findPath(from:to:)` returns scene points. Use `bufferRadius` to leave clearance for the character. ``SpriteUI/ObstacleGraph`` offers routes around obstacle corners instead.

The world navigation helpers read ``SpriteUI/PolygonObstacleComponent`` geometry when you build the graph or mesh. Update or rebuild it when obstacles move. Add colliders or physics bodies separately when those same walls also need collision behavior.

## Decide what to do when the way is blocked

A planned route describes where to go. Collision queries tell you what occupies space now. World raycasts inspect a segment, overlaps test a placed shape, and sweeps test a shape translated toward a destination.

The queries return ``SpriteUI/CollisionHit`` values in scene coordinates and work without a renderer. Use a ``SpriteUI/CollisionQueryFilter`` to select categories and exclude particular entities. Supplying a `group` also tests target collision masks.

A query reports geometry; your rule decides whether to stop, replan, or slide. For a walking character that should slide along walls, ``SpriteUI/CharacterControllerComponent`` combines shape sweeps with movement and overlap recovery.

```swift
import SpriteUI

@MainActor
func moveWalker(_ character: Entity, velocity: SIMD2<Float>, deltaTime: Float)
    throws -> CharacterMovementResult {
    if character.components[CharacterControllerComponent.self] == nil {
        character.components.set(
            CharacterControllerComponent(shape: .circle(radius: 12))
        )
    }
    return try character.moveCharacter(by: velocity * deltaTime, relativeTo: nil)
}
```

The caller supplies velocity and elapsed time. `moveCharacter` returns contacts, recovery movement, remaining movement, and whether the character is still overlapping. Use these results to decide grounding or blocked-route behavior. Gravity, jumping, steps, and moving platforms remain rules you write.

Controller contacts are returned by the call rather than published as ``SpriteUI/PhysicsEvents``. The controller can also supply query and input geometry when there is no separate collider or physics body.

## Let forces move a dynamic object

A crate that falls and tumbles is a different problem from a guard following a route. Give it a ``SpriteUI/PhysicsBodyComponent`` and use forces or impulses. The renderer sends inputs to the backend, then copies completed poses and velocities back before presentation systems run.

Configure `contactTestBitMask` when game rules need contact events. Physical collision masks and contact reporting are separate settings. Retain subscriptions to ``SpriteUI/PhysicsEvents/ContactBegan`` or ``SpriteUI/PhysicsEvents/ContactEnded`` for those rules.

Use ``SpriteUI/PhysicsJointComponent`` for a simulated connection between bodies. A ``SpriteUI/TransformConstraintComponent`` instead maintains a visual relationship, such as looking at a target, without collision response.

## Keep in mind

Choose one writer for an entity's movement in each mode. Path following does not stop at colliders, and steering avoidance does not guarantee a clear route. To combine steering with a character controller, write a system that feeds desired movement into `moveCharacter`; the built-in steering system writes positions directly.

A character controller must not share motion with a dynamic body. Each controller move holds rotation and scale fixed, and overlap recovery can add displacement. Physics needs the backend; a world advanced without a renderer does not step rigid bodies. Physics velocity uses parent coordinates, while steering uses scene coordinates.

An added `CollisionComponent` overrides body geometry and filters. Disabling it suppresses body activity, queries, and targeted input while retaining component velocities. Model collision queries do not follow visual clipping or in-between animation poses. A singular parent can prevent steering from applying a result.

Tile-map `gridSpace(at:)` assumes square tiles, uses `tileSize.x`, and ignores map rotation and scale. Convert coordinates yourself for transformed maps.

## Next lesson

Read <doc:systems-and-input> to connect player input to these rules. Then use <doc:rendering-and-resources> to give moving characters shared artwork, animation, and labels.
