import SpriteUI
import SwiftUI

/// The Physics milestone: a box of pegs. Tap to drop a ball or a crate; SpriteKit
/// simulates them through `PhysicsBodyComponent`, and their positions and velocities
/// come back into the entities each frame. Pegs flash when a ball hits them, from a
/// `PhysicsEvents.ContactBegan` subscription. Tilt changes gravity; Kick pushes everything up.
struct PhysicsDemoView: View {
    @State private var scene = PhysicsScene()
    @State private var size = CGSize(width: 400, height: 600)

    var body: some View {
        VStack(spacing: 0) {
            GameView { content in
                scene.build(in: content)
            } update: { content in
                content.renderer.gravity = scene.tilt.gravity
            }
            .onGeometryChange(for: CGSize.self) { $0.size } action: { size = $0 }
            .gesture(SpatialTapGesture().onEnded { value in
                scene.drop(at: [
                    Float(value.location.x - size.width / 2),
                    Float(size.height / 2 - value.location.y),
                ])
            })
            .overlay(alignment: .top) {
                Text(scene.summary)
                    .font(.caption.bold().monospacedDigit())
                    .padding(.horizontal, 10).padding(.vertical, 5)
                    .background(.ultraThinMaterial, in: .capsule)
                    .padding(.top, 8)
            }

            VStack(spacing: 10) {
                Picker("Drop", selection: $scene.shape) {
                    ForEach(PhysicsScene.DropShape.allCases, id: \.self) { Text($0.rawValue) }
                }
                .pickerStyle(.segmented)
                Picker("Gravity", selection: $scene.tilt) {
                    ForEach(PhysicsScene.Tilt.allCases, id: \.self) { Image(systemName: $0.symbol) }
                }
                .pickerStyle(.segmented)
                HStack {
                    Button("Kick") { scene.kick() }
                    Button("Clear") { scene.clear() }
                }
                .buttonStyle(.bordered)
                .tint(.orange)
                .font(.footnote)
            }
            .padding()
        }
        .onChange(of: size, initial: true) { scene.resizeRoom(to: size) }
        .background(Color.black)
        .preferredColorScheme(.dark)
    }
}

// MARK: Scene

@MainActor
@Observable
final class PhysicsScene {
    enum DropShape: String, CaseIterable { case ball = "Ball", crate = "Crate", mixed = "Mixed" }

    enum Tilt: CaseIterable {
        case down, left, zero, right, up

        var gravity: SIMD2<Float> {
            switch self {
            case .down: [0, -9.8]
            case .left: [-9.8, 0]
            case .zero: [0, 0]
            case .right: [9.8, 0]
            case .up: [0, 9.8]
            }
        }

        var symbol: String {
            switch self {
            case .down: "arrow.down"
            case .left: "arrow.left"
            case .zero: "circle.slash"
            case .right: "arrow.right"
            case .up: "arrow.up"
            }
        }
    }

    // Categories, so balls report contacts with pegs and nothing else.
    private static let ballCategory: UInt32 = 1 << 0
    private static let crateCategory: UInt32 = 1 << 1
    private static let pegCategory: UInt32 = 1 << 2

    var shape = DropShape.ball
    var tilt = Tilt.down
    private(set) var summary = "tap to drop"

    @ObservationIgnored private var world: World?
    @ObservationIgnored private let room = Entity(name: "room")
    @ObservationIgnored private var pegs: [Entity] = []
    @ObservationIgnored private var bodies: [Entity] = []
    @ObservationIgnored private var hits = 0
    @ObservationIgnored private var dropped = 0
    @ObservationIgnored private var subscriptions: [EventSubscription] = []
    @ObservationIgnored private var generator = SeededGenerator(seed: 3)

    private static let disc = SpriteImage.disc(diameter: 64)
    private static let colors: [Color] = [.cyan, .pink, .mint, .yellow, .purple, .orange]
    private static let pegColor = Color(white: 0.45)

    init() {
        room.components.set(PhysicsBodyComponent(shape: .edgeLoop(rectangle: [400, 600]), friction: 0.4))

        // Staggered rows of pegs.
        for row in 0..<5 {
            let y = Float(110 - row * 55)
            let columns = row.isMultiple(of: 2) ? 6 : 5
            for column in 0..<columns {
                let x = (Float(column) - Float(columns - 1) / 2) * 56
                let peg = Entity(name: "peg")
                peg.position = [x, y]
                peg.components.set(SpriteComponent(image: Self.disc, size: [14, 14], tint: Self.pegColor, tintAmount: 1))
                peg.components.set(PhysicsBodyComponent(
                    shape: .circle(radius: 7), isDynamic: false, restitution: 0.5, categoryBitMask: Self.pegCategory
                ))
                pegs.append(peg)
            }
        }
    }

    func build(in content: GameViewContent) {
        world = content.world
        content.add(room)
        for peg in pegs { content.add(peg) }

        // Every ball-on-peg contact, whichever body SpriteKit calls A.
        subscriptions.append(content.world.subscribe(to: PhysicsEvents.ContactBegan.self) { [weak self] contact in
            self?.contact(contact)
        })
        // Velocities are copied back from the simulation, so systems and UI can read them.
        subscriptions.append(content.world.subscribe(to: WorldEvents.Update.self) { [weak self] _ in
            self?.updateSummary()
        })
    }

    func resizeRoom(to size: CGSize) {
        guard size.width > 0, size.height > 0 else { return }
        room.components[PhysicsBodyComponent.self]?.shape = .edgeLoop(rectangle: [Float(size.width), Float(size.height)])
    }

    func drop(at point: SIMD2<Float>) {
        let color = Self.colors[dropped % Self.colors.count]
        dropped += 1
        let isBall = switch shape {
        case .ball: true
        case .crate: false
        case .mixed: Bool.random(using: &generator)
        }

        let body = Entity(name: isBall ? "ball" : "crate")
        body.position = point
        if isBall {
            let radius = Float.random(in: 9...15, using: &generator)
            body.components.set(SpriteComponent(image: Self.disc, size: [radius * 2, radius * 2], tint: color, tintAmount: 1))
            body.components.set(PhysicsBodyComponent(
                shape: .circle(radius: radius), restitution: 0.6,
                categoryBitMask: Self.ballCategory, contactTestBitMask: Self.pegCategory
            ))
        } else {
            let side = Float.random(in: 20...32, using: &generator)
            body.transform.rotation = Float.random(in: 0..<(.pi / 2), using: &generator)
            body.components.set(SpriteComponent(color: color.opacity(0.85), size: [side, side]))
            body.components.set(PhysicsBodyComponent(
                shape: .rectangle(size: [side, side]), friction: 0.5, restitution: 0.15,
                categoryBitMask: Self.crateCategory
            ))
        }
        bodies.append(body)
        world?.addEntity(body)
        updateSummary()
    }

    /// An upward shove with a little sideways spin, scaled by mass so everything jumps alike.
    func kick() {
        for body in bodies {
            guard let mass = body.components[PhysicsBodyComponent.self].map({ physicsMass(of: body, $0) }) else { continue }
            let sideways = Float.random(in: -1...1, using: &generator)
            body.applyImpulse([sideways * 150 * mass, 450 * mass])
            body.applyAngularImpulse(sideways * 0.002)
        }
    }

    func clear() {
        for body in bodies { world?.removeEntity(body) }
        bodies.removeAll()
        hits = 0
        updateSummary()
    }

    // MARK: Private

    private func contact(_ contact: PhysicsEvents.ContactBegan) {
        guard let peg = [contact.entityA, contact.entityB].first(where: { $0.name == "peg" }) else { return }
        hits += 1
        peg.components[SpriteComponent.self]?.color = .white
        peg.components[SpriteComponent.self]?.size = [18, 18]
        withAnimation(.easeOut(duration: 0.4)) {
            peg.components[SpriteComponent.self]?.color = Self.pegColor
            peg.components[SpriteComponent.self]?.size = [14, 14]
        }
        updateSummary()
    }

    /// Mass from density × area, matching how SpriteKit sizes a body (150 points per meter).
    private func physicsMass(of body: Entity, _ physics: PhysicsBodyComponent) -> Float {
        let meters: Float = 150
        switch physics.shape {
        case .circle(let radius): return physics.density * .pi * (radius / meters) * (radius / meters)
        case .rectangle(let size): return physics.density * (size.x / meters) * (size.y / meters)
        default: return 0
        }
    }

    private func updateSummary() {
        let fastest = bodies.compactMap { $0.components[PhysicsBodyComponent.self]?.velocity }
            .map { ($0.x * $0.x + $0.y * $0.y).squareRoot() }
            .max() ?? 0
        let text = "\(bodies.count) bodies · \(hits) peg hits · top \(Int(fastest / 10) * 10) pt/s"
        if text != summary { summary = text }
    }
}
