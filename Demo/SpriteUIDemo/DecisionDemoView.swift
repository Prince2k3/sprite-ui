import SpriteUI
import SwiftUI
import simd

/// The Decisions milestone: critters pick what to do with a decision tree,
/// a tree learned from examples, or a fuzzy rule system.
/// Drag to be the predator; critters get hungry, tired, and eat the green pellets.
struct DecisionDemoView: View {
    @State private var scene = DecisionScene()
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
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        scene.movePlayer(to: [
                            Float(value.location.x - size.width / 2),
                            Float(size.height / 2 - value.location.y),
                        ])
                    }
                    .onEnded { _ in scene.hidePlayer() }
            )
            .overlay(alignment: .top) {
                Text(scene.summary)
                    .font(.caption.bold().monospacedDigit())
                    .padding(.horizontal, 10).padding(.vertical, 5)
                    .background(.ultraThinMaterial, in: .capsule)
                    .padding(.top, 8)
            }
            .overlay(alignment: .bottomLeading) {
                if scene.showsBrain {
                    Text(scene.brainText)
                        .font(.system(size: 9, design: .monospaced))
                        .fixedSize()
                        .padding(8)
                        .background(.ultraThinMaterial, in: .rect(cornerRadius: 8))
                        .padding(8)
                        .allowsHitTesting(false)
                }
            }

            VStack(spacing: 10) {
                Picker("Brain", selection: $scene.brain) {
                    ForEach(DecisionScene.Brain.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)

                HStack(spacing: 12) {
                    ForEach(CritterAction.allCases, id: \.self) { action in
                        HStack(spacing: 4) {
                            Circle().fill(action.color).frame(width: 8, height: 8)
                            Text(action.rawValue)
                        }
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)

                HStack {
                    Toggle("Show brain", isOn: $scene.showsBrain)
                    Button("Scatter") { scene.scatter() }
                }
                .toggleStyle(.button)
                .buttonStyle(.bordered)
                .tint(.orange)
                .font(.footnote)
            }
            .padding()
        }
        .onChange(of: scene.brain) { scene.applyBrain() }
        .background(Color.black)
        .preferredColorScheme(.dark)
    }
}

// MARK: Brains

enum CritterAction: String, CaseIterable, Hashable, Codable, Sendable {
    case flee, eat, wander, rest

    var color: Color {
        switch self {
        case .flee: .red
        case .eat: .green
        case .wander: .cyan
        case .rest: .purple
        }
    }
}

/// What a critter knows about itself, for the rule system.
struct CritterState: Sendable {
    var playerDistance: Double
    var hunger: Double
    var energy: Double

    /// The same facts as answers, for the trees.
    var answers: DecisionAnswers {
        ["playerDistance": .number(playerDistance), "hunger": .number(hunger), "energy": .number(energy)]
    }
}

enum Mood: Hashable, Sendable {
    case scared, hungry, tired, curious

    var action: CritterAction {
        switch self {
        case .scared: .flee
        case .hungry: .eat
        case .tired: .rest
        case .curious: .wander
        }
    }
}

enum CritterBrain {
    case tree(DecisionTree<CritterAction>)
    case rules(RuleSystem<CritterState, Mood>)

    func decide(_ state: CritterState, using rng: inout SeededGenerator) -> CritterAction {
        switch self {
        case .tree(let tree): tree.decide(state.answers, using: &rng) ?? .wander
        case .rules(let rules): rules.evaluate(state).strongest?.action ?? .wander
        }
    }

    static let handBuilt = DecisionTree<CritterAction>(
        .ask("playerDistance",
            .when(.below(110), .action(.flee)),
            otherwise: .ask("hunger",
                .when(.atLeast(0.6), .action(.eat)),
                otherwise: .ask("energy",
                    .when(.below(0.25), .action(.rest)),
                    otherwise: .random([(9, .action(.wander)), (1, .action(.rest))]))))
    )

    /// A designer's table of situations and the right reaction to each.
    static let examples: [(playerDistance: Double, hunger: Double, energy: Double, action: CritterAction)] = [
        (40, 0.2, 0.8, .flee), (90, 0.9, 0.5, .flee), (60, 0.1, 0.1, .flee), (100, 0.7, 0.2, .flee),
        (300, 0.9, 0.5, .eat), (250, 0.7, 0.1, .eat), (220, 0.65, 0.9, .eat), (400, 0.8, 0.6, .eat),
        (200, 0.3, 0.1, .rest), (400, 0.2, 0.15, .rest), (350, 0.5, 0.2, .rest),
        (300, 0.2, 0.8, .wander), (180, 0.4, 0.6, .wander), (150, 0.5, 0.9, .wander), (500, 0.1, 0.4, .wander),
    ]

    static let learned = DecisionTree(
        learningFrom: examples.map {
            CritterState(playerDistance: $0.playerDistance, hunger: $0.hunger, energy: $0.energy).answers
        },
        actions: examples.map(\.action)
    )

    static let rules = RuleSystem<CritterState, Mood>(
        Rule(assert: .scared, gradedBy: { critter, _ in 1 - critter.playerDistance / 150 }),
        Rule(assert: .hungry, gradedBy: { critter, _ in critter.hunger }),
        Rule(assert: .tired, gradedBy: { critter, _ in 2 * (0.5 - critter.energy) }),
        Rule(assert: .curious, gradedBy: { _, _ in 0.3 }),
        // Fear spoils the appetite. Low salience, so it runs after the facts above exist.
        Rule(salience: -1, when: { _, facts in facts[.scared] > 0.5 }, retract: .hungry, grade: 0.5)
    )

    static let rulesText = """
    scared  = 1 − playerDistance / 150
    hungry  = hunger
    tired   = 2 × (0.5 − energy)
    curious = 0.3
    if scared > 0.5: hungry −= 0.5
    → strongest mood wins
    """
}

// MARK: Components and system

struct CritterComponent: Component {
    var hunger: Double
    var energy: Double
    var action = CritterAction.wander
    /// Seconds until the next decision. Staggered so critters don't all think at once.
    var untilDecision: Double
    var food: Entity?
}

struct FoodComponent: Component {}

/// The demo's settings, kept on the arena entity so the system can read them.
struct DecisionArenaComponent: Component {
    var brain = CritterBrain.tree(CritterBrain.handBuilt)
    var player: SIMD2<Float>?
    var bounds = BoundingBox(center: .zero, size: [360, 560])
}

enum DecisionEvents {
    /// Published when any critter changes what it's doing.
    struct Counted: Event {
        let counts: [CritterAction: Int]
    }
}

/// Every half second each critter answers its brain's questions and acts on the answer.
struct DecisionSystem: System {
    private static let arenas = EntityQuery(where: .has(DecisionArenaComponent.self))
    private static let critters = EntityQuery(where: .has(CritterComponent.self))
    private static let foods = EntityQuery(where: .has(FoodComponent.self))
    static let fleeDistance: Double = 110

    init(world: World) {}

    mutating func update(context: UpdateContext) {
        guard let arenaEntity = context.entities(matching: Self.arenas).first,
              let arena = arenaEntity.components[DecisionArenaComponent.self]
        else { return }
        let world = context.world
        let dt = context.deltaTime
        let foods = Array(context.entities(matching: Self.foods))
        var changed = false

        for critter in context.entities(matching: Self.critters) {
            guard var state = critter.components[CritterComponent.self] else { continue }
            let playerDistance = arena.player.map { Double(simd_distance($0, critter.position)) } ?? 1000

            // Bodies change over time.
            state.hunger = min(state.hunger + 0.03 * dt, 1)
            switch state.action {
            case .rest: state.energy = min(state.energy + 0.25 * dt, 1)
            case .flee: state.energy = max(state.energy - 0.07 * dt, 0)
            default: state.energy = max(state.energy - 0.035 * dt, 0)
            }

            // Eat a pellet on reaching it, and drop a new one somewhere else.
            if state.action == .eat, let food = state.food, simd_distance(food.position, critter.position) < 12 {
                state.hunger = max(state.hunger - 0.8, 0)
                food.position = Self.randomPoint(in: arena.bounds, using: &world.random)
                state.untilDecision = 0
            }

            // A nearby predator interrupts anything; otherwise wait for the next think.
            let threatened = playerDistance < Self.fleeDistance
            state.untilDecision -= dt
            if state.untilDecision <= 0 || (threatened && state.action != .flee) {
                state.untilDecision = 0.5
                let facts = CritterState(playerDistance: playerDistance, hunger: state.hunger, energy: state.energy)
                var action = arena.brain.decide(facts, using: &world.random)
                // Once resting, stay down until rested, unless something wants to eat you.
                if state.action == .rest, action != .flee, state.energy < 0.9 { action = .rest }
                let food = action == .eat ? Self.nearest(foods, to: critter.position) : nil
                if action != state.action || food?.id != state.food?.id || action == .flee {
                    let restartsWander = action == .wander && state.action != .wander
                    if action != state.action { changed = true }
                    state.action = action
                    state.food = food
                    Self.steer(critter, for: state, player: arena.player, bounds: arena.bounds, restartWander: restartsWander)
                }
            }
            critter.components.set(state)
            if critter.components[SpriteComponent.self]?.color != state.action.color {
                critter.components[SpriteComponent.self]?.color = state.action.color
            }
        }

        if changed {
            var counts: [CritterAction: Int] = [:]
            for critter in context.entities(matching: Self.critters) {
                counts[critter.components[CritterComponent.self]!.action, default: 0] += 1
            }
            world.publish(DecisionEvents.Counted(counts: counts), from: arenaEntity)
        }
    }

    /// Turns an action into steering goals.
    static func steer(
        _ critter: Entity,
        for state: CritterComponent,
        player: SIMD2<Float>?,
        bounds: BoundingBox,
        restartWander: Bool
    ) {
        guard var steering = critter.components[SteeringComponent.self] else { return }
        let base = [
            SteeringGoal(.separate(radius: 16), weight: 1.2),
            SteeringGoal(.stayWithin(bounds, margin: 30), weight: 2.5),
        ]
        switch state.action {
        case .flee:
            steering.maxSpeed = 170
            steering.goals = base + [
                SteeringGoal(.flee(.point(player ?? critter.position), panicDistance: 200), weight: 2)
            ]
        case .eat:
            steering.maxSpeed = 110
            steering.goals = base + [
                SteeringGoal(.arrive(.point(state.food?.position ?? critter.position), slowingRadius: 30))
            ]
        case .wander:
            steering.maxSpeed = 55
            if restartWander {
                steering.goals = base + [SteeringGoal(.wander(Wander(radius: 20, distance: 40, rate: 3)), weight: 0.6)]
            }
        case .rest:
            steering.maxSpeed = 55
            steering.goals = base + [SteeringGoal(.arrive(.point(critter.position), slowingRadius: 40))]
        }
        steering.maxForce = steering.maxSpeed * 3
        critter.components.set(steering)
    }

    static func nearest(_ foods: [Entity], to point: SIMD2<Float>) -> Entity? {
        foods.min { simd_distance($0.position, point) < simd_distance($1.position, point) }
    }

    static func randomPoint(in bounds: BoundingBox, using rng: inout SeededGenerator) -> SIMD2<Float> {
        [
            Float.random(in: (bounds.min.x + 30)...(bounds.max.x - 30), using: &rng),
            Float.random(in: (bounds.min.y + 30)...(bounds.max.y - 30), using: &rng),
        ]
    }
}

// MARK: Scene

@MainActor
@Observable
final class DecisionScene {
    enum Brain: String, CaseIterable {
        case tree = "Tree", learned = "Learned", rules = "Rules"
    }

    static let critterCount = 14
    static let foodCount = 6

    // Reactions live in the view's `onChange`, not `didSet` (see MazeScene).
    var brain = Brain.tree
    var showsBrain = true
    private(set) var counts: [CritterAction: Int] = [.wander: critterCount]

    var summary: String {
        CritterAction.allCases.map { "\($0.rawValue) \(counts[$0] ?? 0)" }.joined(separator: " · ")
    }

    var brainText: String {
        switch brain {
        case .tree: CritterBrain.handBuilt.description
        case .learned: "learned from \(CritterBrain.examples.count) examples\n" + CritterBrain.learned.description
        case .rules: CritterBrain.rulesText
        }
    }

    @ObservationIgnored private let arena = Entity(name: "arena", components: DecisionArenaComponent())
    @ObservationIgnored private var critters: [Entity] = []
    @ObservationIgnored private var foods: [Entity] = []
    @ObservationIgnored private let player = Entity(
        name: "player", components: SpriteComponent(color: .orange, size: [16, 16])
    )
    @ObservationIgnored private var subscription: EventSubscription?
    @ObservationIgnored private var rng = SeededGenerator(seed: 11)

    init() {
        for i in 0..<Self.critterCount {
            let critter = Entity(
                name: "critter \(i)",
                components: SpriteComponent(color: CritterAction.wander.color, size: [12, 8]),
                SpatialIndexComponent(),
                SteeringComponent(maxSpeed: 55, maxForce: 165, radius: 6, orientsToVelocity: true),
                CritterComponent(
                    hunger: Double.random(in: 0...0.5, using: &rng),
                    energy: Double.random(in: 0.4...1, using: &rng),
                    untilDecision: Double.random(in: 0..<0.5, using: &rng)
                )
            )
            critter.transform.zPosition = 2
            critters.append(critter)
        }
        for i in 0..<Self.foodCount {
            let food = Entity(name: "food \(i)", components: SpriteComponent(color: .green, size: [7, 7]), FoodComponent())
            food.transform.rotation = .pi / 4
            foods.append(food)
        }
        player.transform.rotation = .pi / 4
        player.transform.zPosition = 3
        player.components[SpriteComponent.self]?.opacity = 0
        scatter()
    }

    func build(in content: GameViewContent) {
        let world = content.world
        world.random = SeededGenerator(seed: 5)
        world.spatialCellSize = 40
        world.addSystem(DecisionSystem.self)
        world.addSystem(SteeringSystem.self)
        world.addSystem(SpatialIndexSystem.self)

        content.add(arena)
        for food in foods { content.add(food) }
        for critter in critters { content.add(critter) }
        content.add(player)
        subscription = content.subscribe(to: DecisionEvents.Counted.self) { [weak self] event in
            self?.counts = event.counts
        }
    }

    func resize(to size: CGSize) {
        guard size.width > 0, size.height > 0 else { return }
        arena.components[DecisionArenaComponent.self]?.bounds = BoundingBox(
            center: .zero, size: [Float(size.width) - 16, Float(size.height) - 16]
        )
    }

    func movePlayer(to point: SIMD2<Float>) {
        player.position = point
        player.components[SpriteComponent.self]?.opacity = 1
        arena.components[DecisionArenaComponent.self]?.player = point
    }

    func hidePlayer() {
        player.components[SpriteComponent.self]?.opacity = 0
        arena.components[DecisionArenaComponent.self]?.player = nil
    }

    func applyBrain() {
        arena.components[DecisionArenaComponent.self]?.brain = switch brain {
        case .tree: .tree(CritterBrain.handBuilt)
        case .learned: .tree(CritterBrain.learned)
        case .rules: .rules(CritterBrain.rules)
        }
    }

    /// Scatters critters and food across the arena.
    func scatter() {
        let bounds = arena.components[DecisionArenaComponent.self]?.bounds ?? BoundingBox(center: .zero, size: [360, 560])
        for critter in critters {
            critter.position = DecisionSystem.randomPoint(in: bounds, using: &rng)
            critter.components[CritterComponent.self]?.untilDecision = 0
        }
        for food in foods {
            food.position = DecisionSystem.randomPoint(in: bounds, using: &rng)
        }
    }
}
