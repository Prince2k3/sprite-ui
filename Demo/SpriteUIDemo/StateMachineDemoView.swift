import SpriteUI
import SwiftUI
import simd

/// The State Machines milestone: guards patrol, chase the player when it's close,
/// lunge when they catch it, then back off. Drag the orange player around.
struct StateMachineDemoView: View {
    @State private var scene = GuardScene()

    var body: some View {
        VStack(spacing: 0) {
            GameView { content in
                scene.build(in: content)
            }
            .gesture(DragGesture(minimumDistance: 0).targetedToAnyEntity().onChanged { value in
                value.entity.position = value.convert(value.location, to: .scene)
            })
            .overlay(alignment: .top) { legend }

            HStack {
                Text("catches \(scene.catches)")
                    .font(.footnote.monospacedDigit())
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Reset") { withAnimation(.snappy) { scene.reset() } }
                    .buttonStyle(.bordered)
                    .tint(.white)
            }
            .padding()
        }
        .background(Color.black)
        .preferredColorScheme(.dark)
    }

    private var legend: some View {
        HStack(spacing: 10) {
            ForEach(Guard.allCases, id: \.self) { state in
                Label {
                    Text("\(state)")
                } icon: {
                    RoundedRectangle(cornerRadius: 2).fill(state.color).frame(width: 10, height: 10)
                }
            }
        }
        .font(.caption.bold())
        .padding(.horizontal, 10).padding(.vertical, 5)
        .background(.ultraThinMaterial, in: .capsule)
        .padding(.top, 8)
    }
}

/// A guard's behavior. Each state colors the guard on entry and moves it every frame.
enum Guard: EntityState, CaseIterable {
    case patrol, chase, attack, recover

    static let sightRange: Float = 130
    static let loseRange: Float = 190
    static let reach: Float = 34

    var color: Color {
        switch self {
        case .patrol: .gray
        case .chase: .yellow
        case .attack: .red
        case .recover: .blue
        }
    }

    /// patrol → chase → attack → recover → patrol; a chase can also be given up.
    func canTransition(to next: Guard) -> Bool {
        switch (self, next) {
        case (.patrol, .chase), (.chase, .patrol), (.chase, .attack),
             (.attack, .recover), (.recover, .patrol): true
        default: false
        }
    }

    func didEnter(from previous: Guard?, on entity: Entity) {
        withAnimation(.smooth(duration: 0.2)) {
            entity.components[SpriteComponent.self]?.color = color
        }
        if self == .attack {
            withAnimation(.bouncy(duration: 0.3, extraBounce: 0.3)) { entity.transform.scale = [1.5, 1.5] }
        } else if previous == .attack {
            withAnimation(.smooth(duration: 0.3)) { entity.transform.scale = [1, 1] }
        }
    }

    func update(on entity: Entity, context: UpdateContext) {
        guard let player = context.world.root.findEntity(named: "player") else { return }
        let toPlayer = player.position - entity.position
        let distance = simd_length(toPlayer)
        let dt = Float(context.deltaTime)
        let time = entity.timeInState(Guard.self)

        switch self {
        case .patrol:
            guard var patrol = entity.components[PatrolComponent.self] else { return }
            if simd_distance(patrol.target, entity.position) < 4 {
                patrol.target = PatrolComponent.randomPoint(using: &context.world.random)
                entity.components.set(patrol)
            }
            entity.move(toward: patrol.target, speed: 40, dt: dt)
            if distance < Self.sightRange { entity.enter(Guard.chase) }
        case .chase:
            entity.move(toward: player.position, speed: 95, dt: dt)
            if distance < Self.reach { entity.enter(Guard.attack) }
            else if distance > Self.loseRange { entity.enter(Guard.patrol) }
        case .attack:
            if time > 0.4 { entity.enter(Guard.recover) }
        case .recover:
            // Back off, then go back to patrolling.
            if distance > 0 { entity.position -= toPlayer / distance * 60 * dt }
            if time > 1.2 { entity.enter(Guard.patrol) }
        }
    }
}

/// Where a patrolling guard is headed.
struct PatrolComponent: Component {
    var target: SIMD2<Float>

    static func randomPoint(using rng: inout SeededGenerator) -> SIMD2<Float> {
        [Float.random(in: -160...160, using: &rng), Float.random(in: -220...220, using: &rng)]
    }
}

extension Entity {
    fileprivate func move(toward target: SIMD2<Float>, speed: Float, dt: Float) {
        let delta = target - position
        let length = simd_length(delta)
        guard length > 0 else { return }
        position += delta / length * min(speed * dt, length)
    }
}

@MainActor
@Observable
final class GuardScene {
    private(set) var catches = 0

    @ObservationIgnored let player = Entity(
        name: "player",
        components: SpriteComponent(color: .orange, size: [32, 32]), InputTargetComponent()
    )
    @ObservationIgnored private let guards = (0..<4).map { index in
        Entity(name: "guard-\(index)", components: SpriteComponent(color: .gray, size: [26, 26]))
    }
    @ObservationIgnored private var subscription: EventSubscription?
    @ObservationIgnored private var world: World?

    private static let homes: [SIMD2<Float>] = [[-120, 180], [120, 180], [-120, -180], [120, -180]]

    func build(in content: GameViewContent) {
        world = content.world
        content.world.random = SeededGenerator(seed: 7)
        content.world.addSystem(StateMachineSystem<Guard>.self)
        content.add(player)
        for (guardEntity, home) in zip(guards, Self.homes) {
            guardEntity.components.set(PatrolComponent(target: home))
            content.add(guardEntity)
        }
        // Count every lunge, from any guard.
        subscription = content.subscribe(to: StateMachineEvents.DidEnter<Guard>.self) { [weak self] event in
            if event.state == .attack { self?.catches += 1 }
        }
        reset()
    }

    func reset() {
        player.position = .zero
        for (guardEntity, home) in zip(guards, Self.homes) {
            guardEntity.position = home
            // Force the machine back to patrol, wherever it was.
            guardEntity.components.remove(StateMachineComponent<Guard>.self)
            guardEntity.enter(Guard.patrol)
        }
        catches = 0
    }
}
