# Gameplay and movement

Choose a movement owner, combine steering goals, and turn a planned route into motion.

## Choose the operation that matches the rule

Planning, steering, collision queries, character motion, and rigid-body simulation solve different steps of a game rule. Choose one writer for an entity's movement in a given mode.

| API | It provides | Your game still decides |
| --- | --- | --- |
| ``SpriteUI/Graph`` and ``SpriteUI/NavigationMesh`` | A route through connected nodes or walkable space | When to replan and how to traverse the route |
| ``SpriteUI/AgentGoal`` and ``SpriteUI/Agent2D`` | Steering forces and integrated agent motion | Which goals to combine and where to store the result |
| ``SpriteUI/SteeringComponent`` with ``SpriteUI/SteeringSystem`` | Scene-space steering applied to entities | Behavior selection and arrival/gameplay outcomes |
| ``SpriteUI/PathComponent`` with ``SpriteUI/PathFollowSystem`` | Steady-speed movement through scene waypoints | Route generation and collision policy |
| ``SpriteUI/CollisionComponent`` and world queries | Geometry for rays, overlaps, sweeps, and interaction | What a hit means and whether to move |
| ``SpriteUI/CharacterControllerComponent`` | Explicit swept movement with recovery and sliding | Velocity, gravity, jumping, steps, and platforms |
| ``SpriteUI/PhysicsBodyComponent`` | Backend rigid-body response | Forces, impulses, collision masks, and contact rules |

A path follower does not automatically stop at colliders, and a steering avoidance force does not guarantee a collision-free route. Avoid putting a path follower, steering, a transform animation, and a dynamic body in charge of the same transform. Switch modes explicitly or write a system that integrates desired motion with the collision policy you need.

## Start with a pure steering calculation

``SpriteUI/AgentGoal`` is a namespace of force functions. ``SpriteUI/Agent2D`` stores position, velocity, speed/force limits, mass, and radius. Goals return forces; `apply(_:deltaTime:)` caps the combined force, integrates velocity, caps speed, and advances position. Goal weights are force multipliers rather than priorities.

This complete function performs one standalone simulation step without a world or renderer:

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

Construct an agent with positive mass and suitable `maxSpeed` and `maxForce`. `seek` requests full-speed travel toward a point; `arrive` slows near it. Pursuit and evasion use target motion. Separation, alignment, and cohesion use neighboring positions or velocities. `Wander` has evolving state, so keep it and your random generator across updates rather than reconstructing them every frame.

An ``SpriteUI/AgentPath`` is a nonempty polyline with a corridor radius and optional closure. `AgentGoal.follow` steers along it; `AgentGoal.stay` keeps an agent near it without providing forward travel by itself. An open path clamps distance sampling at its ends, and a closed path wraps. A path value is geometry for steering, not an automatically scheduled entity controller.

## Let the ECS adapter advance an entity

The ECS adapter stores goals in ``SpriteUI/SteeringComponent``. Each ``SpriteUI/SteeringGoal`` wraps a ``SpriteUI/SteeringBehavior``, weight, optional name, and enabled flag. Point targets and entity targets use scene space. The system snapshots all agents before calculating forces so iteration order does not bias neighbors.

This setup function creates a patrol agent with a named path goal and obstacle avoidance. The caller presents the supplied world or advances it headlessly.

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

Use `components[SteeringComponent.self]?.setEnabled(false, named: "patrol")` to switch off that goal without losing its stored state or weight. Named groups let several weighted goals act as a switchable mode; a group's weight scales the combined inner force. Entity targets use IDs and remap within a cloned or restored hierarchy.

For flocking, add ``SpriteUI/SpatialIndexComponent`` to participating neighbors and install ``SpriteUI/SpatialIndexSystem``. The index system declares that it runs after steering and path following, keeping the next query's positions current. Call `world.updateSpatialIndex()` after initial placement or a teleport if you need an immediate query before its next scheduled refresh. Give a custom mover a `.before(SpatialIndexSystem.self)` dependency when appropriate.

Steering positions, velocities, radii, and goal points use scene coordinates. The adapter converts its result back through rotated or scaled parents. A singular parent prevents a valid commit; it does not justify writing a made-up local pose.

## Plan a route, then choose how to traverse it

``SpriteUI/Graph`` requires neighbors and edge costs and supports path and cost-map searches. ``SpriteUI/AdjacencyGraph`` fits authored connections, while ``SpriteUI/GridGraph`` fits cells with blocked areas and traversal costs. Convert grid nodes to scene points using ``SpriteUI/GridSpace`` before handing them to an entity.

This complete helper plans around one blocked cell, smooths the route, and starts constant-speed traversal. It returns `false` when the entity is not in the world or no route exists.

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

`PathFollowSystem` spends the full frame's distance budget across waypoint boundaries. At the final waypoint it removes the component and publishes ``SpriteUI/PathEvents/DidFinish`` after movement commits. Retain the subscription token if you handle completion. `stopFollowingPath()` stops without publishing a finish event.

For open rooms, ``SpriteUI/NavigationMesh`` triangulates bounded walkable floor around padded polygon obstacles. Its `findPath(from:to:)` point overload returns scene points; its graph nodes are triangle indices. Use `bufferRadius` to reserve clearance for the moving unit. ``SpriteUI/ObstacleGraph`` offers a corner-based route representation around polygon obstacles.

Add ``SpriteUI/PolygonObstacleComponent`` to scene obstacles when using the world navigation helpers. `world.navigationMesh(bounds:bufferRadius:)` and `world.obstacleGraph(bufferRadius:)` capture current obstacle geometry; rebuild or update the result after obstacles move. These navigation obstacles are not automatically physics bodies or colliders. Author those separately when the same wall also needs collision response.

Tile maps expose `gridGraph` and `gridSpace(at:)` through the umbrella integration. The convenience grid space assumes square tiles, uses `tileSize.x`, and ignores map rotation and scale. Use explicit coordinate conversion for transformed maps rather than treating that helper as a complete affine mapping.

## Use queries to inspect collision geometry

World raycasts, overlaps, and sweeps read active model-space colliders and return ``SpriteUI/CollisionHit`` values in scene space. They work without a renderer. A ``SpriteUI/CollisionQueryFilter`` can select categories and exclude exact entity IDs. Supplying its optional `group` also tests target collision masks; omitting it permits inspection independently of physical response.

Raycasts inspect a line segment. Overlaps place a shape under an affine transform. Sweeps translate a shape toward an ending scene origin while holding rotation and scale fixed. A hit reports distance, fraction, and an outward normal; an initial interior or overlap hit can have a zero normal. Queries inspect geometry without performing automatic movement or publishing physics contact events.

Visual clipping and shader effects do not change these model-space queries. Compare the displayed input path in <doc:systems-and-input> when a pointer and a ray appear to disagree.

## Move a kinematic character explicitly

A character controller supplies convex geometry and a synchronous sweep-and-slide operation. This helper advances an already attached character using a scene-space velocity and returns the detailed result for the caller to inspect:

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

Inspect `contacts`, `recoveryTranslation`, `remainingTranslation`, and `isOverlapping` to implement grounding, wall response, or a blocked-route policy. Recovery can contribute additional displacement. Rotation and scale stay fixed during one move, and gravity, steps, and moving platforms remain game policies. Controller contacts are returned synchronously rather than emitted as ``SpriteUI/PhysicsEvents``.

A controller can provide query and input geometry when neither an explicit collider nor a physics body exists. Do not combine it with a dynamic physics body. Steering can supply a desired direction to a custom controller system, but the built-in `SteeringSystem` writes positions directly; attaching both components does not automatically make it call `moveCharacter`.

## Let physics own dynamic motion

Use ``SpriteUI/PhysicsBodyComponent`` for motion driven by forces, impulses, and rigid-body response. The renderer pushes inputs to the backend, copies completed poses and velocities back, then runs presentation systems. Dynamic simulation requires the backend; a headless world alone does not step rigid bodies. Physics velocity is expressed in the parent's space, unlike the steering adapter's scene-space velocity.

An explicit `CollisionComponent` overrides a body's shape, offset, and collision filters. Disabling that collider suppresses its body, queries, and targeted input while retaining component velocities. Contact reporting still needs the body's `contactTestBitMask` configured; physical collision masks and contact reporting are separate settings. Retain subscriptions to ``SpriteUI/PhysicsEvents/ContactBegan`` or ``SpriteUI/PhysicsEvents/ContactEnded`` for contact-driven rules.

Use ``SpriteUI/PhysicsJointComponent`` when bodies need a simulated relationship. Use ``SpriteUI/TransformConstraintComponent`` for visual follow, look-at, distance, or limit relationships that do not supply collision response. Constraints are renderer-evaluated, and their status values explain incompatible owners or unresolved targets.

## See also

- <doc:systems-and-input>
- <doc:rendering-and-resources>
- <doc:saving-and-debugging>
