import SpriteUI
import SwiftUI

/// The Steering milestone: a flock of boids driven by `SteeringSystem`.
/// Flock: they flock, dodge the rocks and scatter from your finger.
/// Follow: they circle a closed path. Arrive: they gather where you touch.
/// Cruise: a switchable "cruise" group (wander at a set speed) kept on a wide
/// path by `stayOn`; turn it off and a "rest" goal takes over and they slow to a stop.
struct SteeringDemoView: View {
    @State private var scene = SteeringScene()
    @State private var size = CGSize(width: 400, height: 600)

    var body: some View {
        VStack(spacing: 0) {
            GameView { content in
                scene.build(in: content)
            }
            .onGeometryChange(for: CGSize.self) { $0.size } action: { newSize in
                size = newSize
                scene.resize(to: newSize)
            }
            .gesture(DragGesture(minimumDistance: 0).onChanged { value in
                scene.moveTarget(to: [
                    Float(value.location.x - size.width / 2),
                    Float(size.height / 2 - value.location.y),
                ])
            })
            .overlay(alignment: .top) {
                Text(scene.mode.hint)
                    .font(.caption.bold())
                    .padding(.horizontal, 10).padding(.vertical, 5)
                    .background(.ultraThinMaterial, in: .capsule)
                    .padding(.top, 8)
            }

            VStack(spacing: 10) {
                Picker("Mode", selection: $scene.mode) {
                    ForEach(SteeringScene.Mode.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)

                HStack {
                    Text("Speed").font(.footnote)
                    Slider(value: $scene.maxSpeed, in: 40...240)
                    Text("\(Int(scene.maxSpeed))").font(.footnote.monospacedDigit()).frame(width: 32)
                }

                HStack {
                    Toggle("Rocks", isOn: $scene.showsRocks)
                    if scene.mode == .cruise {
                        Toggle("Cruise", isOn: $scene.cruising)
                    }
                    Button("Scatter") { scene.scatter() }
                }
                .toggleStyle(.button)
                .buttonStyle(.bordered)
                .tint(.orange)
                .font(.footnote)
            }
            .padding()
        }
        .onChange(of: scene.mode) { scene.applyGoals() }
        .onChange(of: scene.maxSpeed) { scene.applyGoals() }
        .onChange(of: scene.showsRocks) { scene.applyRocks() }
        .onChange(of: scene.cruising) { scene.applyCruising() }
        .background(Color.black)
        .preferredColorScheme(.dark)
    }
}

// MARK: Scene

@MainActor
@Observable
final class SteeringScene {
    enum Mode: String, CaseIterable {
        case flock = "Flock", follow = "Follow", arrive = "Arrive", cruise = "Cruise"

        var hint: String {
            switch self {
            case .flock: "drag to scare the flock"
            case .follow: "boids circle the path"
            case .arrive: "drag to call them over"
            case .cruise: "wandering at a set speed, kept on the path"
            }
        }
    }

    static let boidCount = 70
    static let rockDots = 28

    // Reactions live in the view's `onChange`, not `didSet` (see MazeScene).
    var mode = Mode.flock
    var maxSpeed: Float = 120
    var showsRocks = true
    var cruising = true

    @ObservationIgnored private var boids: [Entity] = []
    @ObservationIgnored private var rocks: [(entity: Entity, radius: Float)] = []
    @ObservationIgnored private let target = Entity(
        name: "target", components: SpriteComponent(color: .orange, size: [14, 14])
    )
    @ObservationIgnored private let pathLayer = Entity(name: "path")
    @ObservationIgnored private var bounds = BoundingBox(center: .zero, size: [360, 560])
    @ObservationIgnored private var targetPoint: SIMD2<Float> = [0, -1000]
    @ObservationIgnored private var rng = SeededGenerator(seed: 7)

    init() {
        for i in 0..<Self.boidCount {
            let hue = 0.5 + 0.12 * Double(i % 5) / 5
            let boid = Entity(
                name: "boid \(i)",
                components: SpriteComponent(color: Color(hue: hue, saturation: 0.7, brightness: 1), size: [12, 4]),
                SpatialIndexComponent()
            )
            boid.transform.zPosition = 2
            boids.append(boid)
        }
        for (center, radius) in [(SIMD2<Float>(-80, 120), Float(36)), ([90, -40], 44), ([-60, -170], 30)] {
            let rock = Entity(name: "rock", components: SteeringObstacleComponent(radius: radius))
            rock.position = center
            for j in 0..<Self.rockDots {
                let angle = Float(j) / Float(Self.rockDots) * 2 * .pi
                let dot = Entity(components: SpriteComponent(color: .gray, size: [4, 4]))
                dot.position = [cos(angle), sin(angle)] * radius
                rock.addChild(dot)
            }
            rocks.append((rock, radius))
        }
        target.transform.rotation = .pi / 4
        target.transform.zPosition = 3
        target.components[SpriteComponent.self]?.opacity = 0
        scatter()
    }

    func build(in content: GameViewContent) {
        let world = content.world
        world.random = SeededGenerator(seed: 99)
        world.spatialCellSize = 40
        world.addSystem(SteeringSystem.self)
        world.addSystem(SpatialIndexSystem.self)

        content.add(pathLayer)
        for rock in rocks { content.add(rock.entity) }
        for boid in boids { content.add(boid) }
        content.add(target)
        applyGoals()
    }

    func resize(to size: CGSize) {
        guard size.width > 0, size.height > 0 else { return }
        bounds = BoundingBox(center: .zero, size: [Float(size.width) - 16, Float(size.height) - 16])
        applyGoals()
    }

    func moveTarget(to point: SIMD2<Float>) {
        targetPoint = point
        target.position = point
        if mode != .follow, mode != .cruise { target.components[SpriteComponent.self]?.opacity = 1 }
        applyGoals()
    }

    func scatter() {
        for boid in boids {
            boid.position = [
                Float.random(in: bounds.min.x...bounds.max.x, using: &rng),
                Float.random(in: bounds.min.y...bounds.max.y, using: &rng),
            ]
            let angle = Float.random(in: 0..<(2 * .pi), using: &rng)
            let velocity = SIMD2(cos(angle), sin(angle)) * maxSpeed * 0.5
            var steering = boid.components[SteeringComponent.self] ?? makeSteering()
            steering.velocity = velocity
            boid.components.set(steering)
        }
    }

    func applyRocks() {
        for rock in rocks {
            if showsRocks {
                rock.entity.components.set(SteeringObstacleComponent(radius: rock.radius))
            } else {
                rock.entity.components.remove(SteeringObstacleComponent.self)
            }
            for dot in rock.entity.children { dot.components[SpriteComponent.self]?.opacity = showsRocks ? 1 : 0 }
        }
    }

    /// Rewrites every boid's goals for the current mode, keeping velocity and wander state.
    func applyGoals() {
        var goals = goals(for: mode)
        goals.setEnabled(cruising, named: "cruise")
        goals.setEnabled(!cruising, named: "rest")
        for boid in boids {
            var steering = boid.components[SteeringComponent.self] ?? makeSteering()
            steering.maxSpeed = maxSpeed
            steering.maxForce = maxSpeed * 3
            // Keep each boid's own wander state across rewrites.
            let wander = steering.goals.lazy.compactMap { goal -> Wander? in
                if case .wander(let state) = goal.behavior { state } else { nil }
            }.first
            steering.goals = goals.map { goal in
                if case .wander = goal.behavior, let wander { SteeringGoal(.wander(wander), weight: goal.weight) } else { goal }
            }
            boid.components.set(steering)
        }
        drawPath()
        if mode == .follow || mode == .cruise { target.components[SpriteComponent.self]?.opacity = 0 }
    }

    /// Switches every boid's "cruise" group on or off without touching its other goals.
    func applyCruising() {
        for boid in boids {
            guard var steering = boid.components[SteeringComponent.self] else { continue }
            steering.setEnabled(cruising, named: "cruise")
            steering.setEnabled(!cruising, named: "rest")
            boid.components.set(steering)
        }
    }

    private func makeSteering() -> SteeringComponent {
        SteeringComponent(maxSpeed: maxSpeed, maxForce: maxSpeed * 3, radius: 6, orientsToVelocity: true)
    }

    private func goals(for mode: Mode) -> [SteeringGoal] {
        let edges = SteeringGoal(.stayWithin(bounds, margin: 30), weight: 2)
        let avoid = SteeringGoal(.avoidObstacles(lookAhead: 0.6), weight: 3)
        switch mode {
        case .flock:
            return [
                SteeringGoal(.separate(radius: 18), weight: 1.6),
                SteeringGoal(.align(radius: 45), weight: 0.6),
                SteeringGoal(.cohere(radius: 60), weight: 0.4),
                SteeringGoal(.wander(Wander(radius: 20, distance: 40, rate: 4)), weight: 0.3),
                SteeringGoal(.flee(.point(targetPoint), panicDistance: 90), weight: 2.5),
                avoid, edges,
            ]
        case .follow:
            return [
                SteeringGoal(.follow(loop(radius: 12), lookAhead: 0.3)),
                SteeringGoal(.separate(radius: 14), weight: 1.2),
                avoid,
            ]
        case .arrive:
            return [
                SteeringGoal(.arrive(.point(targetPoint), slowingRadius: 120)),
                SteeringGoal(.separate(radius: 16), weight: 1.4),
                avoid, edges,
            ]
        case .cruise:
            return [
                .group("cruise", [
                    SteeringGoal(.reachSpeed(maxSpeed * 0.6)),
                    SteeringGoal(.wander(Wander(radius: 25, distance: 40, rate: 5)), weight: 0.8),
                ]),
                SteeringGoal(.reachSpeed(0), name: "rest", isEnabled: false),
                SteeringGoal(.stayOn(loop(radius: 40), lookAhead: 0.4), weight: 2.5),
                SteeringGoal(.separate(radius: 14), weight: 1.2),
                avoid,
            ]
        }
    }

    /// A rounded loop inside the view.
    private func loop(radius: Float) -> AgentPath {
        let half = (bounds.size / 2) - [50, 70]
        let points = (0..<48).map { i -> SIMD2<Float> in
            let angle = Float(i) / 48 * 2 * .pi
            // A squircle: rounder than a rectangle, squarer than an ellipse.
            let c = cos(angle), s = sin(angle)
            let x = copysign(pow(abs(c), 0.5), c), y = copysign(pow(abs(s), 0.5), s)
            return [x * half.x, y * half.y]
        }
        return AgentPath(points: points, radius: radius, isClosed: true)
    }

    private func drawPath() {
        let points = mode == .follow || mode == .cruise ? loop(radius: 12).points : []
        while pathLayer.children.count < points.count {
            pathLayer.addChild(Entity(components: SpriteComponent(color: .white.opacity(0.35), size: [3, 3])))
        }
        for (i, dot) in pathLayer.children.enumerated() {
            if i < points.count {
                dot.position = points[i]
                dot.components[SpriteComponent.self]?.opacity = 1
            } else {
                dot.components[SpriteComponent.self]?.opacity = 0
            }
        }
    }
}
