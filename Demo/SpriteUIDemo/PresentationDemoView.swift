import CoreGraphics
import Observation
import SpriteUI
import SwiftUI

/// A single simulation supplies the primary arena, local previews and an optional accessory.
@MainActor
struct PresentationDemoView: View {
    @State private var model = PresentationDemoModel()
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Text("One world, shared frames").font(.title2.bold())
                Text("Move the cyan player in the arena. Every preview shows the same camera and completed GPU frame.")
                    .font(.caption).foregroundStyle(.secondary)
                PresentationDemoArena(model: model)
                    .frame(height: 320)
                PresentationDemoMovementControls(model: model)
                PresentationDemoCounters(model: model)
                PresentationDemoRenderControls(model: model)
                PresentationDemoMirrorControls(model: model)
                PresentationDemoMirrors(model: model)
                PresentationDemoStatistics(monitor: model.monitor, source: model.source)
                PresentationDemoSnapshot(model: model)
                PresentationDemoExternalControls(model: model)
            }
            .padding(12)
        }
        .background(.black).preferredColorScheme(.dark).tint(.cyan)
        .onChange(of: scenePhase) { _, phase in
            if phase != .active { model.releaseInput(); model.cancelAudit() }
        }
        .onDisappear { model.releaseInput(); model.cancelAudit() }
    }
}

/// Only quality settings configure this host; telemetry and mirror visibility are read elsewhere.
@MainActor
private struct PresentationDemoArena: View {
    let model: PresentationDemoModel

    var body: some View {
        GeometryReader { proxy in
            GameView(viewports: model.viewports, rendering: model.rendering,
                     renderMonitor: model.monitor, presentation: model.source) {
                model.install(in: $0)
            }
            .onGameSurfaceChange { model.surfaceDidChange($0) }
            .gameInput(model.hub)
            .gesture(SpatialTapGesture().onEnded { model.move(to: $0.location) })
            .overlay { PresentationDemoSurfaceControls(model: model, size: proxy.size) }
            .modifier(PresentationDemoExternalOutput(model: model))
            .clipped()
            .accessibilityLabel("Primary interactive arena. Tap a usable region to move the player")
            .accessibilityIdentifier("presentation-arena")
        }
    }
}

@MainActor
private struct PresentationDemoExternalOutput: ViewModifier {
    let model: PresentationDemoModel

    @ViewBuilder func body(content: Content) -> some View {
        #if os(iOS) && !targetEnvironment(macCatalyst)
        if #available(iOS 27.0, *) {
            content.gameExternalDisplay(model.source, isEnabled: model.externalEnabled) {
                model.externalAvailable = $0
            }
        } else {
            content
        }
        #else
        content
        #endif
    }
}

@MainActor
private struct PresentationDemoSurfaceControls: View {
    let model: PresentationDemoModel
    let size: CGSize
    @State private var controlSize = CGSize.zero

    var body: some View {
        if let geometry = model.surface,
           abs(geometry.bounds.width - size.width) <= 1 / geometry.displayScale,
           abs(geometry.bounds.height - size.height) <= 1 / geometry.displayScale {
            let placement = geometry.placement(of: controlSize, anchor: [1, 1])
            Button("Stop player", systemImage: "stop.fill") { model.releaseInput() }
                .font(.caption.bold()).padding(8).frame(minHeight: 44)
                .background(.black.opacity(0.85), in: RoundedRectangle(cornerRadius: 8))
                .fixedSize()
                .onGeometryChange(for: CGSize.self) { $0.size } action: { controlSize = $0 }
                .position(x: placement?.midX ?? 0, y: placement?.midY ?? 0)
                .opacity(placement == nil ? 0 : 1)
                .allowsHitTesting(placement != nil)
                .accessibilityHidden(placement == nil)
                .accessibilityIdentifier("presentation-safe-stop")
        }
    }
}

@MainActor
private struct PresentationDemoMovementControls: View {
    let model: PresentationDemoModel

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Player · tap an arrow to keep moving; Stop releases it").font(.caption)
            HStack {
                ForEach(PresentationDemoModel.directions, id: \.name) { direction in
                    Button { model.move(direction: direction.name) } label: {
                        Image(systemName: direction.symbol).frame(maxWidth: .infinity, minHeight: 44)
                    }
                    .accessibilityLabel("Move player \(direction.name)")
                }
                Button("Stop") { model.releaseInput() }.frame(minWidth: 44, minHeight: 44)
            }
            .buttonStyle(.bordered)
        }
    }
}

@MainActor
private struct PresentationDemoCounters: View {
    let model: PresentationDemoModel

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text("World installs \(model.installations) · Updates \(model.updates) · Finished frames \(model.finishedFrames)")
            Text("World time \(model.worldTime, specifier: "%.2f")s · Contacts \(model.contacts) · Action markers \(model.actionMarkers)")
            Text("Player (\(model.playerPosition.x, specifier: "%.0f"), \(model.playerPosition.y, specifier: "%.0f")) · Move commands \(model.moveCommands)")
            Text("World \(model.worldIdentity) · Source \(model.sourceIdentity)")
            if !model.status.isEmpty { Text(model.status).foregroundStyle(.orange) }
        }
        .font(.caption.monospacedDigit())
        .accessibilityIdentifier("presentation-world-counters")
    }
}

@MainActor
private struct PresentationDemoRenderControls: View {
    @Bindable var model: PresentationDemoModel

    var body: some View {
        DisclosureGroup("Render quality and budget") {
            VStack(alignment: .leading, spacing: 8) {
                Text("Resolution scale \(model.resolutionScale, specifier: "%.2f")×").font(.caption)
                Slider(value: $model.resolutionScale, in: 0.25...1, step: 0.25)
                    .accessibilityLabel("Render resolution scale")
                Picker("Preferred FPS", selection: $model.preferredFPS) {
                    ForEach([30, 60, 120], id: \.self) { Text("\($0) FPS").tag($0) }
                }.pickerStyle(.segmented)
                Picker("Pixel budget", selection: $model.maximumPixels) {
                    Text("1 MP").tag(1_048_576)
                    Text("4 MP").tag(4_194_304)
                    Text("16 MP").tag(16_777_216)
                }.pickerStyle(.segmented)
                Toggle("Adapt to system pressure", isOn: $model.adaptsToPressure)
                Text("Requested FPS is a preference. Effective size and scale below reflect the actual render budget.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .disabled(model.isAuditing)
        }
        .accessibilityIdentifier("presentation-quality-controls")
    }
}

@MainActor
private struct PresentationDemoMirrorControls: View {
    @Bindable var model: PresentationDemoModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Picker("Local same-frame previews", selection: Binding(
                get: { model.mirrorCount }, set: { model.setMirrorCount($0) })) {
                Text("Off").tag(0)
                Text("One").tag(1)
                Text("Two").tag(2)
            }
            .pickerStyle(.segmented).disabled(model.isAuditing)
            .accessibilityIdentifier("presentation-mirror-count")
            Text("Read-only GPU previews. Touching them does not move the player. They share the source's frame; they have no world, camera or input session of their own.")
                .font(.caption).foregroundStyle(.secondary)
            Text(model.toggleResult).font(.caption.monospacedDigit())
            Button(model.isAuditing ? "Checking mirror isolation…" : "Check mirror isolation") { model.beginAudit() }
                .buttonStyle(.bordered).disabled(model.isAuditing || model.installations == 0)
                .accessibilityIdentifier("presentation-check-isolation")
            Text(model.auditResult).font(.caption.monospacedDigit())
                .accessibilityIdentifier("presentation-isolation-result")
        }
    }
}

@MainActor
private struct PresentationDemoMirrors: View {
    let model: PresentationDemoModel

    var body: some View {
        ForEach(0..<model.mirrorCount, id: \.self) { index in
            VStack(alignment: .leading, spacing: 4) {
                Text("Same-frame preview \(index + 1) · read only").font(.headline)
                GamePresentationView(source: model.source)
                    .frame(maxWidth: .infinity).frame(height: 180)
                    .background(.white.opacity(0.05))
                    .allowsHitTesting(false)
                    .accessibilityLabel("Same-frame preview \(index + 1), read only")
                    .accessibilityIdentifier("presentation-preview-\(index)")
            }
        }
    }
}

@MainActor
private struct PresentationDemoStatistics: View {
    let monitor: GameRenderMonitor
    let source: GamePresentationSource

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(source.isAvailable ? "Presentation source available" : "Waiting for a completed GPU frame")
            Text("Source \(Int(source.pixelSize.width)) × \(Int(source.pixelSize.height)) px · Frame \(source.frameNumber)")
            if let stats = monitor.latest {
                Text("Logical \(Int(stats.logicalSize.width)) × \(Int(stats.logicalSize.height)) pt · Drawable \(Int(stats.drawableSize.width)) × \(Int(stats.drawableSize.height)) px")
                Text("Viewports \(stats.renderedViewportCount) · Render pixels \(stats.renderPixels) · Targets \(Double(stats.estimatedRenderTargetBytes) / 1_048_576, specifier: "%.2f") MiB")
                Text("Effective scale \(stats.effectiveResolutionScale, specifier: "%.2f")× · Preferred \(stats.preferredFramesPerSecond) FPS")
                Text("Render frame \(stats.frameNumber) · Presentation frames \(stats.presentationFrameCount) · Dropped \(stats.droppedPresentationFrames)")
            }
        }
        .font(.caption.monospacedDigit())
        .accessibilityIdentifier("presentation-render-statistics")
    }
}

@MainActor
private struct PresentationDemoSnapshot: View {
    let model: PresentationDemoModel

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button("Capture snapshot and identities") { model.captureSnapshot() }
                .buttonStyle(.bordered).accessibilityIdentifier("presentation-snapshot")
            Text(model.snapshotResult).font(.caption.monospacedDigit())
            if let image = model.snapshot {
                Image(decorative: image, scale: 1).resizable().scaledToFit()
                    .frame(maxHeight: 180)
                    .accessibilityLabel("Captured primary game surface, still image")
            }
        }
    }
}

@MainActor
private struct PresentationDemoExternalControls: View {
    @Bindable var model: PresentationDemoModel

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            #if os(iOS) && !targetEnvironment(macCatalyst)
            if #available(iOS 27.0, *) {
                Toggle("Enable native external accessory display", isOn: $model.externalEnabled)
                Text(model.externalEnabled
                     ? (model.externalAvailable ? "Native external display available." : "No native external display available. Connect a supported accessory.")
                     : "Native external output disabled.")
            } else {
                Text("Native external accessory output requires iOS 27 or later.")
            }
            #else
            Text("Native external accessory output is available on iOS 27 or later.")
            #endif
            Text("External output is a noninteractive accessory presentation. Local Same-frame previews are not external displays. This does not provide access to an iPhone Duo outer display or use camera capture.")
                .foregroundStyle(.secondary)
        }
        .font(.caption)
        .accessibilityIdentifier("presentation-external-status")
    }
}

@MainActor @Observable
private final class PresentationDemoModel {
    static let moveAction = InputAction("presentation-move", kind: .axis2D)
    static let directions: [(name: String, symbol: String, vector: SIMD2<Float>)] = [
        ("left", "arrow.left", [-1, 0]), ("right", "arrow.right", [1, 0]),
        ("up", "arrow.up", [0, 1]), ("down", "arrow.down", [0, -1])
    ]
    let hub = PlayerInputHub()
    let monitor = GameRenderMonitor()
    // Nil selects the full completed surface. Its only pane is the existing main camera.
    let source = GamePresentationSource()
    let pad = InputDevice.virtual("presentation-player")
    var resolutionScale = 1.0
    var preferredFPS = 60
    var maximumPixels = 16_777_216
    var adaptsToPressure = false
    var externalEnabled = false
    var externalAvailable = false
    private(set) var mirrorCount = 1
    private(set) var surface: GameSurfaceGeometry?
    private(set) var installations = 0
    private(set) var updates = 0
    private(set) var finishedFrames = 0
    private(set) var contacts = 0
    private(set) var actionMarkers = 0
    private(set) var moveCommands = 0
    private(set) var worldTime: TimeInterval = 0
    private(set) var playerPosition = SIMD2<Float>.zero
    private(set) var worldIdentity = "pending"
    private(set) var status = ""
    private(set) var toggleResult = "Change preview count while watching the same world's counters."
    private(set) var auditResult = "Checks 0 → 1 → 2 → 0 previews over 30 primary frames each."
    private(set) var isAuditing = false
    private(set) var snapshot: CGImage?
    private(set) var snapshotResult = "Snapshot captures the completed surface without advancing the world."
    @ObservationIgnored private let player = Entity(name: "Presentation player", components:
        SpriteComponent(color: .cyan, size: [26, 26]))
    @ObservationIgnored private let camera = Entity(name: "Presentation camera", components:
        CameraComponent(target: .named("Presentation player"), smoothing: 0.15))
    @ObservationIgnored private var content: GameViewContent?
    @ObservationIgnored private var subscriptions: [EventSubscription] = []
    @ObservationIgnored private var input: InputController?
    @ObservationIgnored private var destination: SIMD2<Float>?
    @ObservationIgnored private var auditStep = 0
    @ObservationIgnored private var auditBaseline: (updates: Int, frames: Int, renderFrame: UInt64)?
    @ObservationIgnored private var auditSamples: [Int] = []
    @ObservationIgnored private var auditRenderSamples: [UInt64] = []
    @ObservationIgnored private var savedMirrorCount = 1
    @ObservationIgnored private var auditWorld: ObjectIdentifier?
    @ObservationIgnored private var auditSource: ObjectIdentifier?

    var sourceIdentity: String { String(describing: ObjectIdentifier(source)) }
    var viewports: [GameViewport] {
        [GameViewport(id: "main", camera: camera.id, region: .largestUsable)]
    }
    var rendering: GameRenderConfiguration {
        GameRenderConfiguration(resolutionScale: resolutionScale, preferredFramesPerSecond: preferredFPS,
                                maximumRenderPixels: maximumPixels, maximumTextureDimension: 8192,
                                adaptsToSystemPressure: adaptsToPressure)
    }

    init() {
        let map = InputActionMap(name: "Presentation player", bindings: Self.directions.map {
            InputBinding(Self.moveAction, control: .virtual($0.name), scale: $0.vector)
        })
        let session = hub.addPlayer(named: "P1", contexts: [map])
        input = session.input
        hub.connect(InputDeviceInfo(id: pad, name: "Presentation pad"))
        do { try hub.assign(pad, to: session) }
        catch { status = "Input setup failed: \(error)" }
    }

    func install(in content: GameViewContent) {
        installations += 1
        self.content = content
        worldIdentity = String(describing: ObjectIdentifier(content.world))
        content.renderer.backgroundColor = .black
        surfaceDidChange(content.surfaceGeometry)
        for x in stride(from: -600, through: 600, by: 60) {
            let line = Entity(components: SpriteComponent(color: .white.opacity(0.12), size: [1, 1200]))
            line.position = [Float(x), 0]; line.zPosition = -10; content.add(line)
        }
        for y in stride(from: -600, through: 600, by: 60) {
            let line = Entity(components: SpriteComponent(color: .white.opacity(0.12), size: [1200, 1]))
            line.position = [0, Float(y)]; line.zPosition = -10; content.add(line)
        }
        content.add(player); content.add(camera)
        subscriptions = [
            content.subscribe(to: WorldEvents.Update.self) { [weak self] in self?.step($0.deltaTime) },
            content.subscribe(to: RenderingEvents.DidUpdate.self) { [weak self] _ in
                guard let self else { return }
                finishedFrames += 1
                recordAuditFrame()
            },
            content.subscribe(to: PhysicsEvents.ContactBegan.self) { [weak self] _ in self?.contacts += 1 },
            content.subscribe(to: PlaybackEvents.MarkerReached.self) { [weak self] _ in self?.actionMarkers += 1 }
        ]
        addPhysicsProbe(in: content)
        let beacon = Entity(name: "Action beacon", components: SpriteComponent(color: .pink, size: [16, 16]))
        beacon.position = [0, 65]; content.add(beacon)
        do {
            let action = try AnimationResource.rotate(from: 0, to: .pi * 2, duration: 2)
                .addingMarker("turn", at: 1)
            _ = try beacon.playAnimation(action, options: .init(repeatMode: .forever))
        } catch { status = "Action setup failed: \(error)" }
    }

    func surfaceDidChange(_ geometry: GameSurfaceGeometry) {
        surface = geometry
        let size = geometry.largestUsableRegion.size
        if size.width > 0, size.height > 0 {
            camera.components[CameraComponent.self]?.zoom = Float(min(size.width / 360, size.height / 260))
        }
    }

    func move(direction: String) {
        destination = nil
        moveCommands += 1
        hub.submit(Self.directions.map { (.virtual($0.name), .button($0.name == direction)) }, device: pad)
    }

    func move(to point: CGPoint) {
        guard let content, let viewport = content.viewport(at: point),
              let target = content.scenePoint(fromView: point, inViewport: viewport.id) else { return }
        releaseInput()
        moveCommands += 1
        destination = target
    }

    func releaseInput() {
        destination = nil
        hub.submit(Self.directions.map { (.virtual($0.name), .button(false)) }, device: pad)
    }

    private func step(_ deltaTime: TimeInterval) {
        updates += 1
        worldTime += deltaTime
        let distance = Float(max(0, deltaTime)) * 90
        if let destination {
            let offset = destination - player.position
            let length = sqrt(offset.x * offset.x + offset.y * offset.y)
            if length > 0 { player.position += offset * min(1, distance / length) }
        } else {
            player.position += (input?.value(for: Self.moveAction).vector ?? .zero) * distance
        }
        player.position.x = min(500, max(-500, player.position.x))
        player.position.y = min(500, max(-500, player.position.y))
        playerPosition = player.position
    }

    private func addPhysicsProbe(in content: GameViewContent) {
        let chamber = Entity(name: "Physics chamber", components:
            PhysicsBodyComponent(shape: .edgeLoop(rectangle: [120, 40]), friction: 0, restitution: 1,
                                 categoryBitMask: 1, collisionBitMask: 2))
        chamber.position = [0, -65]
        for y: Float in [-20, 20] {
            let wall = Entity(components: SpriteComponent(color: .gray, size: [120, 2]))
            wall.position = [0, y]; chamber.addChild(wall)
        }
        for x: Float in [-60, 60] {
            let wall = Entity(components: SpriteComponent(color: .gray, size: [2, 40]))
            wall.position = [x, 0]; chamber.addChild(wall)
        }
        let ball = Entity(name: "Physics probe", components:
            SpriteComponent(color: .yellow, size: [12, 12]),
            PhysicsBodyComponent(shape: .circle(radius: 6), friction: 0, restitution: 1, linearDamping: 0,
                                 affectedByGravity: false, allowsRotation: false,
                                 categoryBitMask: 2, collisionBitMask: 1, contactTestBitMask: 1, velocity: [80, 0]))
        ball.position = [0, -65]
        content.add(chamber); content.add(ball)
    }

    func setMirrorCount(_ count: Int) {
        let before = updates
        mirrorCount = min(2, max(0, count))
        toggleResult = "Preview toggle: \(updates - before) synchronous world updates; world and source retained."
    }

    func beginAudit() {
        guard !isAuditing, let content else { return }
        savedMirrorCount = mirrorCount
        auditWorld = ObjectIdentifier(content.world)
        auditSource = ObjectIdentifier(source)
        auditSamples = []; auditRenderSamples = []; auditStep = 0; auditBaseline = nil
        isAuditing = true
        setMirrorCount(0)
        auditResult = "Checking 0 previews over 30 primary frames…"
    }

    private func recordAuditFrame() {
        guard isAuditing, let stats = monitor.latest else { return }
        guard let baseline = auditBaseline else {
            auditBaseline = (updates, finishedFrames, stats.frameNumber)
            return
        }
        guard finishedFrames - baseline.frames >= 30 else { return }
        auditSamples.append(updates - baseline.updates)
        auditRenderSamples.append(stats.frameNumber >= baseline.renderFrame
                                  ? stats.frameNumber - baseline.renderFrame : 0)
        auditStep += 1
        let counts = [0, 1, 2, 0]
        if auditStep < counts.count {
            setMirrorCount(counts[auditStep])
            // Rebase on the next primary callback, after SwiftUI can mount previews.
            auditBaseline = nil
            auditResult = "Checking \(counts[auditStep]) previews over 30 primary frames…"
        } else {
            let retained = content.map { ObjectIdentifier($0.world) == auditWorld } == true
                && ObjectIdentifier(source) == auditSource && installations == 1
            let passed = retained && auditSamples.allSatisfy { $0 == 30 }
                && auditRenderSamples.allSatisfy { $0 == 30 }
            auditResult = "\(passed ? "PASS" : "CHECK FAILED") · Updates / 30 primary callbacks for 0, 1, 2, 0 previews: \(auditSamples.map(String.init).joined(separator: ", ")). GPU render frames: \(auditRenderSamples.map(String.init).joined(separator: ", ")). Identities \(retained ? "retained" : "changed")."
            isAuditing = false
            setMirrorCount(savedMirrorCount)
        }
    }

    func cancelAudit() {
        guard isAuditing else { return }
        isAuditing = false
        setMirrorCount(savedMirrorCount)
        auditResult = "Check interrupted when the arena became inactive. Run again while visible."
    }

    func captureSnapshot() {
        guard let content else { return }
        let before = (updates, ObjectIdentifier(content.world), ObjectIdentifier(source))
        do {
            let image = try content.capturePresentation()
            guard let provider = CGDataProvider(data: Data(image.pixels) as CFData),
                  let captured = CGImage(width: image.width, height: image.height, bitsPerComponent: 8,
                      bitsPerPixel: 32, bytesPerRow: image.width * 4, space: CGColorSpaceCreateDeviceRGB(),
                      bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue), provider: provider,
                      decode: nil, shouldInterpolate: image.smoothsScaling, intent: .defaultIntent)
            else { snapshotResult = "Could not create snapshot image."; return }
            snapshot = captured
            let retained = before.1 == ObjectIdentifier(content.world) && before.2 == ObjectIdentifier(source)
            snapshotResult = "\(image.width) × \(image.height) px at world time \(String(format: "%.2f", worldTime))s · Updates during capture \(updates - before.0) · Identities \(retained ? "retained" : "changed") · Source frame \(source.frameNumber)."
        } catch { snapshotResult = "Snapshot unavailable: \(error)" }
    }
}
