import SpriteUI
import SwiftUI
import simd

/// A complete SpriteUI game host, with entities rendered by GameView's backend.
public struct DemoBotsView: View {
    @State private var game: DemoBotsSession
    @State private var controls: DemoBotsInput
    @State private var showsHelp = false
    @State private var surfaceGeometry: GameSurfaceGeometry?
    private let surfaceRegions: [GameSurfaceGeometry.ReservedRegion]?
    @State private var sceneDebug: SceneDebugController
    @Environment(\.scenePhase) private var scenePhase

    /// Synthetic reservations are an override for previews; production hosts
    /// leave this nil and use the geometry reported by GameView.
    public init(surfaceRegions: [GameSurfaceGeometry.ReservedRegion]? = nil) {
        self.surfaceRegions = surfaceRegions
        let game = DemoBotsSession()
        let debug = SceneDebugController(options: [.collisionShapes, .selection, .statistics, .inspector, .simulationControls])
        _game = State(initialValue: game)
        _sceneDebug = State(initialValue: debug)
        _controls = State(initialValue: DemoBotsInput(game: game) { debug.isPaused.toggle() })
    }

    public var body: some View {
        GeometryReader { _ in
            let layout = surfaceGeometry.map { DemoBotsSurfaceLayout(surface: $0) }
            ZStack(alignment: .topLeading) {
                Color(red: 0.025, green: 0.07, blue: 0.06)
                GameView(viewports: DemoBotsSurfaceLayout.viewports,
                         surfaceRegions: surfaceRegions,
                         debug: game.isInspecting ? sceneDebug : nil) { content in
                    game.build(in: content)
                    await game.prepareResources()
                } attachments: {
                    GameAttachment(id: "bot-status") { context in
                        if !game.isInspecting, let status = game.botStatuses[context.entity.id],
                           !status.isPlayer || status.isRecharging {
                            botStatus(charge: status.charge, isBad: status.isBad,
                                      isPlayer: status.isPlayer, isRecharging: status.isRecharging)
                        }
                    }
                }
                    .contentShape(Rectangle())
                    .gesture(SpatialTapGesture().onEnded { game.sendPlayer(toView: $0.location) })
                    .onGameSurfaceChange { surface in
                        controls.surfaceDidChange(surface)
                        surfaceGeometry = surface
                    }
                if let layout {
                    if game.phase == .home {
                        surfaceElement(in: layout.menu) { rect in
                            home(size: rect.size).allowsHitTesting(!game.isLoadingResources)
                        }
                    } else if game.isInspecting {
                        inspectionControls(layout: layout)
                    } else {
                        gameplayHUD(layout: layout)
                        if game.phase == .paused || game.phase == .won || game.phase == .lost {
                            Color.black.opacity(0.7).frame(maxWidth: .infinity, maxHeight: .infinity)
                            surfaceElement(in: layout.menu) { _ in
                                if game.phase == .paused { pauseMenu }
                                else { resultMenu }
                            }
                        }
                    }
                    if game.isLoadingResources {
                        surfaceElement(in: layout.menu) { _ in
                            ProgressView("Loading sprites…").padding(20)
                                .frame(maxWidth: .infinity, maxHeight: .infinity)
                                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16))
                        }
                    }
                }
            }
        }
        .ignoresSafeArea()
        .preferredColorScheme(.dark)
        .gameInput(controls.hub, isActive: scenePhase == .active && !showsHelp)
        .onChange(of: scenePhase) { _, phase in if phase != .active { controls.suspend() } }
        .onChange(of: scenePhase == .active && !showsHelp, initial: true) { _, active in
            controls.setInputActive(active)
        }
        .onChange(of: controls.feedbackState) { _, _ in
            controls.synchronizeContext()
            controls.synchronizeFeedback()
        }
        .onChange(of: sceneDebug.isAttached) { _, attached in
            if attached, game.isInspecting { sceneDebug.select(game.player) }
        }
        .onDisappear { controls.setInputActive(false); controls.suspend() }
        .overlay(alignment: .topLeading) {
            if showsHelp, let surfaceGeometry {
                let layout = DemoBotsSurfaceLayout(surface: surfaceGeometry)
                Color.black.opacity(0.7)
                surfaceElement(in: layout.menu) { _ in
                    ScrollView { instructions.frame(maxWidth: .infinity) }
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 20))
                }
            }
        }
#if os(iOS)
        .statusBarHidden()
#endif
    }

    private func home(size: CGSize) -> some View {
        ScrollView {
            VStack(spacing: 22) {
                Text("REBUILT WITH SPRITEUI")
                    .font(.system(size: 11, weight: .bold, design: .monospaced)).tracking(3)
                    .foregroundStyle(.mint.opacity(0.8))
                Image("DemoBotsLogo").resizable().scaledToFit().frame(maxWidth: 350, maxHeight: size.height < 500 ? 130 : 230)
                    .shadow(color: .green.opacity(0.15), radius: 35)
                VStack(spacing: 7) {
                    Text("Little robots. Big bugs.").font(.title2.bold())
                    Text("Get inside. Find the corrupted bots.\nBring them back with your Debug Beam.")
                        .font(.subheadline).foregroundStyle(.white.opacity(0.65)).multilineTextAlignment(.center)
                }
                HStack(spacing: 10) {
                    levelCard(1, title: "First contact", bots: "6 ground bots")
                    levelCard(2, title: "Circuit breaker", bots: "Ground + flying")
                    levelCard(3, title: "Core recovery", bots: "Final circuit")
                }
                Button { controls.confirmSelection() } label: {
                    HStack { Image(systemName: "play.fill"); Text("Enter Level \(controls.selectedLevel)").fontWeight(.bold) }
                        .frame(maxWidth: .infinity).padding(.vertical, 17)
                }
                .buttonStyle(.plain).foregroundStyle(.black)
                .background(Color(red: 0.7, green: 0.95, blue: 0.15), in: RoundedRectangle(cornerRadius: 16))
                .accessibilityIdentifier("start-game")
                inputPrompt(DemoBotsInput.confirm, title: "Confirm")
                if game.hasCheckpoint {
                    Button("Resume checkpoint", systemImage: "arrow.counterclockwise") { controls.loadCheckpoint() }
                        .buttonStyle(.bordered).tint(.mint)
                        .accessibilityLabel("Resume saved checkpoint")
                        .accessibilityIdentifier("checkpoint-resume")
                }
                checkpointFeedback
                Button("How to play", systemImage: "gamecontroller") { showsHelp = true }
                    .font(.subheadline).foregroundStyle(.white.opacity(0.8)).buttonStyle(.plain)
                if !game.message.isEmpty && game.message.hasPrefix("Couldn’t") {
                    Text(game.message).font(.caption).foregroundStyle(.orange).textSelection(.enabled)
                }
                Text("Based on Apple’s DemoBots sample · Artwork © Apple Inc.")
                    .font(.system(size: 10)).foregroundStyle(.white.opacity(0.35))
            }
            .padding(28).frame(maxWidth: 610).frame(maxWidth: .infinity)
            .padding(.vertical, 12)
        }
        .background(LinearGradient(colors: [Color(red: 0.02, green: 0.18, blue: 0.12), .black], startPoint: .topLeading, endPoint: .bottomTrailing))
    }

    private func levelCard(_ number: Int, title: String, bots: String) -> some View {
        Button { controls.selectedLevel = number } label: {
            VStack(alignment: .leading, spacing: 10) {
                Text(String(format: "%02d", number)).font(.system(size: 28, weight: .light, design: .monospaced))
                    .foregroundStyle(controls.selectedLevel == number ? .black : .mint)
                Text(title).font(.system(size: 12, weight: .semibold)).lineLimit(2).frame(height: 30, alignment: .top)
                Text(bots).font(.system(size: 9)).opacity(0.7).lineLimit(1).minimumScaleFactor(0.6)
            }
            .frame(maxWidth: .infinity, alignment: .leading).padding(12)
            .foregroundStyle(controls.selectedLevel == number ? .black : .white)
            .background(controls.selectedLevel == number ? Color(red: 0.7, green: 0.95, blue: 0.15) : Color.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 14))
        }.buttonStyle(.plain).accessibilityLabel("Level \(number): \(title)").accessibilityAddTraits(controls.selectedLevel == number ? .isSelected : [])
    }

    /// Rectangles use GameView's top-left coordinates. Clip each element so
    /// intrinsic text sizes and scrolling cannot paint across a reservation.
    @ViewBuilder private func surfaceElement<Content: View>(
        in rect: CGRect?, @ViewBuilder content: (CGRect) -> Content
    ) -> some View {
        if let rect {
            content(rect)
                .frame(width: rect.width, height: rect.height)
                .clipped()
                .contentShape(Rectangle())
                .position(x: rect.midX, y: rect.midY)
        }
    }

    private func gameplayHUD(layout: DemoBotsSurfaceLayout) -> some View {
        ZStack(alignment: .topLeading) {
            surfaceElement(in: layout.header) { _ in
                ViewThatFits(in: .horizontal) {
                    hudHeader(compact: false)
                    hudHeader(compact: true)
                }
                .padding(12).frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(.black.opacity(0.8), in: RoundedRectangle(cornerRadius: 20))
            }
            surfaceElement(in: layout.prompts) { _ in
                VStack(alignment: .leading, spacing: 4) {
                    inputPrompt(DemoBotsInput.fire, title: "Fire")
                    inputPrompt(DemoBotsInput.pause, title: "Pause")
                }.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
            surfaceElement(in: layout.radar) { _ in
                minimap.padding(9).background(.black.opacity(0.7), in: RoundedRectangle(cornerRadius: 12))
            }
            surfaceElement(in: layout.beamMeter) { _ in
                VStack(spacing: 6) {
                    Text(game.isRecharging ? "POWER RESTORING" : "DEBUG BEAM")
                        .font(.system(size: 9, weight: .bold, design: .monospaced)).tracking(2)
                    meter(value: game.beamFraction, color: .cyan).frame(height: 5)
                    meter(value: game.charge / 100, color: game.charge < 30 ? .red : .green).frame(height: 3)
                }
                .padding(10).background(.black.opacity(0.7), in: RoundedRectangle(cornerRadius: 10))
            }
            surfaceElement(in: layout.moveStick) { _ in
                BotThumbstick(label: "MOVE", symbol: "arrow.up.and.down.and.arrow.left.and.right", tint: .white,
                              isActive: game.phase == .playing) { vector, _ in controls.moveStick(vector) }
                    .id(controls.surfaceInputRevision)
            }
            surfaceElement(in: layout.aimStick) { _ in
                BotThumbstick(label: "AIM + DEBUG", symbol: "bolt.fill", tint: .cyan,
                              isActive: game.phase == .playing) { vector, pressed in controls.aimStick(vector, pressed: pressed) }
                    .id(controls.surfaceInputRevision)
            }
        }
        .allowsHitTesting(game.phase == .playing)
    }

    private func hudHeader(compact: Bool) -> some View {
        HStack(spacing: compact ? 8 : 12) {
            VStack(alignment: .leading, spacing: 6) {
                Text(compact ? "L0\(game.levelNumber)" : "LEVEL 0\(game.levelNumber)")
                    .font(.system(size: 10, weight: .bold, design: .monospaced))
                    .tracking(compact ? 0 : 2).foregroundStyle(.mint)
                Text(compact ? "\(game.totalBots - game.badBots)/\(game.totalBots)" : "\(game.totalBots - game.badBots) / \(game.totalBots) restored")
                    .font(.system(size: compact ? 12 : 18, weight: .bold, design: .rounded))
                    .accessibilityLabel("\(game.totalBots - game.badBots) of \(game.totalBots) restored")
            }
            Spacer(minLength: 0)
            Text(String(format: "%d:%02d", game.secondsLeft / 60, game.secondsLeft % 60))
                .font(.system(size: compact ? 18 : 26, weight: .medium, design: .monospaced)).monospacedDigit()
                .foregroundStyle(game.secondsLeft < 30 ? .red : .white)
            Button { controls.toggleInspection() } label: { Image(systemName: "ladybug").frame(width: 42, height: 42) }
                .buttonStyle(.plain).background(.white.opacity(0.12), in: Circle()).accessibilityLabel("Open scene tools")
            Button { controls.togglePause() } label: { Image(systemName: "pause.fill").frame(width: 42, height: 42) }
                .buttonStyle(.plain).background(.white.opacity(0.12), in: Circle()).accessibilityLabel("Pause game")
        }
        .fixedSize(horizontal: true, vertical: false)
    }

    private var minimap: some View {
        Canvas { context, size in
            let bounds = game.mapBounds
            context.stroke(Path(CGRect(origin: .zero, size: size)), with: .color(.mint.opacity(0.3)), lineWidth: 1)
            for dot in game.mapDots {
                let x = CGFloat((dot.position.x - bounds.x) / bounds.z) * size.width
                let y = (1 - CGFloat((dot.position.y - bounds.y) / bounds.w)) * size.height
                let radius: CGFloat = dot.player ? 3.5 : 2
                let rect = CGRect(x: x - radius, y: y - radius, width: radius * 2, height: radius * 2)
                context.fill(Path(ellipseIn: rect), with: .color(dot.player ? .cyan : (dot.bad ? .red : .green)))
            }
        }.accessibilityLabel("Radar: \(game.badBots) corrupted bots remaining")
    }

    private func meter(value: Float, color: Color) -> some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Capsule().fill(.white.opacity(0.12))
                Capsule().fill(color).frame(width: geometry.size.width * CGFloat(max(0, min(1, value))))
            }
        }
    }

    private func botStatus(charge: Float, isBad: Bool, isPlayer: Bool, isRecharging: Bool) -> some View {
        let label = isRecharging ? "Recharging" : (isBad ? "Corrupted" : "Restored")
        let color: Color = isPlayer ? .cyan : (isBad ? .red : .green)
        let fraction = max(0, min(1, charge))
        return VStack(spacing: 4) {
            Label(label, systemImage: isRecharging ? "bolt.fill" : (isBad ? "exclamationmark.triangle.fill" : "checkmark.circle.fill"))
                .font(.caption2.bold()).foregroundStyle(.white)
                .fixedSize()
            meter(value: fraction, color: color).frame(width: 76, height: 5)
        }
        .padding(.horizontal, 8).padding(.vertical, 6)
        .background(.black.opacity(0.85), in: RoundedRectangle(cornerRadius: 8))
        .allowsHitTesting(false)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(isPlayer ? "Player" : "Bot"), \(label.lowercased())")
        .accessibilityValue("Charge \(Int((fraction * 100).rounded())) percent")
    }

    @ViewBuilder private var checkpointFeedback: some View {
        if !game.checkpointMessage.isEmpty {
            Text(game.checkpointMessage)
                .font(.footnote).foregroundStyle(.white.opacity(0.8))
                .multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
                .accessibilityLabel("Checkpoint: \(game.checkpointMessage)")
        }
    }

    private var pauseMenu: some View {
        menu(title: "Taking a breather?", subtitle: "The circuit can wait.") {
            Button("Resume", systemImage: "play.fill") { controls.confirmSelection() }.buttonStyle(BotPrimaryButton())
            Button("Save checkpoint", systemImage: "square.and.arrow.down") { game.saveCheckpoint() }
                .buttonStyle(.bordered)
                .accessibilityLabel("Save checkpoint")
                .accessibilityIdentifier("checkpoint-save")
            Button("Restore checkpoint", systemImage: "arrow.counterclockwise") { controls.loadCheckpoint() }
                .buttonStyle(.bordered).disabled(!game.hasCheckpoint)
                .accessibilityLabel("Restore saved checkpoint")
                .accessibilityIdentifier("checkpoint-restore")
            checkpointFeedback
            Button("Scene tools", systemImage: "ladybug") { controls.toggleInspection() }.buttonStyle(.bordered)
            Toggle("Show bot paths", isOn: $game.showsPaths).tint(.mint)
            Toggle("Sound effects", isOn: $game.soundEnabled).tint(.mint)
            Button("Restart level") { controls.start(level: game.levelNumber) }.buttonStyle(.bordered)
            Button("Level select") { controls.home() }.buttonStyle(.plain).foregroundStyle(.secondary)
        }
    }
    private var resultMenu: some View {
        let won = game.phase == .won
        return menu(title: won ? (game.levelNumber == 3 ? "All systems go." : "Circuit restored!") : "Out of time.",
                    subtitle: won ? "Every bot is back on your side." : "\(game.badBots) bots still need debugging. Try another approach.") {
            Image(systemName: won ? "checkmark.seal.fill" : "clock.badge.exclamationmark")
                .font(.system(size: 56)).foregroundStyle(won ? .mint : .orange).padding(8)
            if won && game.levelNumber < 3 {
                Button("Next level", systemImage: "arrow.right") { controls.confirmSelection() }.buttonStyle(BotPrimaryButton())
            }
            Button(won ? "Play again" : "Try again", systemImage: "arrow.clockwise") { controls.start(level: game.levelNumber) }.buttonStyle(BotPrimaryButton())
            Button("Level select") { controls.home() }.buttonStyle(.plain).foregroundStyle(.secondary)
        }
    }
    private func menu<Content: View>(title: String, subtitle: String, @ViewBuilder content: @escaping () -> Content) -> some View {
        ScrollView {
            VStack(spacing: 20) {
                Text(title).font(.title.bold()).multilineTextAlignment(.center)
                Text(subtitle).font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center)
                content()
                inputPrompt(DemoBotsInput.confirm, title: "Confirm")
            }
            .fixedSize(horizontal: false, vertical: true)
            .padding(24).frame(maxWidth: 350)
            .frame(maxWidth: .infinity)
        }
        .scrollBounceBehavior(.basedOnSize)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 28))
    }
    @ViewBuilder private func inputPrompt(_ action: InputAction, title: String) -> some View {
        if let prompt = controls.prompt(for: action) {
            Label {
                Text("\(title): \(prompt.label)")
            } icon: {
                if let symbol = prompt.symbolName { Image(systemName: symbol) }
            }
            .font(.caption).foregroundStyle(.white.opacity(0.8))
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityLabel("\(title): \(prompt.label)")
        }
    }

    private var instructions: some View {
        VStack(alignment: .leading, spacing: 24) {
            Text("Field guide").font(.largeTitle.bold())
            Label("Move with the left stick, or tap the floor to walk there.", systemImage: "move.3d")
            Label("Hold the right stick to target a nearby visible bad bot. Drag to favor your aim; without a target, the beam fires where you face.", systemImage: "bolt.fill")
            Label("Keep the beam on a red bot until it turns green. Watch your beam’s charge.", systemImage: "battery.75percent")
            Label("GroundBots chase and infect. FlyingBots blast nearby bots—curing one can cure its neighbors too.", systemImage: "airplane")
            Label("Out of charge? You recover automatically. Restore all bots before the clock runs out.", systemImage: "clock")
            Text("Keyboard: WASD/arrows move · F/Space fires · P/Escape pauses · I opens scene tools").font(.caption).foregroundStyle(.secondary)
            Text("Gamepad: left stick/D-pad moves · right stick aims and fires · south button/right trigger fires · Menu pauses · South/Return confirms menus").font(.caption).foregroundStyle(.secondary)
            Button("Ready", systemImage: "checkmark") { showsHelp = false }.buttonStyle(BotPrimaryButton())
        }.padding(24).frame(maxWidth: 560)
    }

    private func inspectionControls(layout: DemoBotsSurfaceLayout) -> some View {
        ZStack(alignment: .topLeading) {
            surfaceElement(in: layout.inspectionHeader) { _ in
                HStack {
                    Button { controls.toggleInspection() } label: {
                        Image(systemName: "xmark").frame(width: 44, height: 44)
                            .background(.regularMaterial, in: Circle())
                    }
                    .buttonStyle(.plain).accessibilityLabel("Close scene tools")
                    Text("Scene tools").font(.headline)
                    Spacer(minLength: 0)
                }.padding(.horizontal, 8)
            }
            surfaceElement(in: layout.inspectionFooter) { _ in
                ScrollView(.horizontal) {
                    HStack(spacing: 14) {
                        Button("Player", systemImage: "scope") { sceneDebug.select(game.player) }
                        Button(sceneDebug.options.contains(.origins) ? "Less guides" : "More guides", systemImage: "square.dashed") {
                            let extras: SceneDebugOptions = [.origins, .bounds, .joints, .constraintTargets]
                            if sceneDebug.options.contains(.origins) { sceneDebug.options.subtract(extras) }
                            else { sceneDebug.options.formUnion(extras) }
                        }
                        Text("Player controls off").font(.caption).foregroundStyle(.secondary)
                    }.padding(10)
                }
                .font(.footnote).buttonStyle(.bordered)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
            }
        }.tint(.mint)
    }
}

private struct BotPrimaryButton: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.font(.headline).frame(maxWidth: .infinity).padding(15)
            .foregroundStyle(.black).background(.mint.opacity(configuration.isPressed ? 0.7 : 1), in: RoundedRectangle(cornerRadius: 13))
    }
}

private struct BotThumbstick: View {
    let label: String
    let symbol: String
    let tint: Color
    let isActive: Bool
    var changed: (SIMD2<Float>, Bool) -> Void
    @State private var offset = CGSize.zero
    @State private var pressed = false
    private let radius: CGFloat = 48

    var body: some View {
        VStack(spacing: 8) {
            ZStack {
                Circle().fill(.black.opacity(0.5))
                Circle().strokeBorder(tint.opacity(0.25), lineWidth: 1)
                Circle().strokeBorder(tint.opacity(0.1), lineWidth: 1).padding(18)
                Image(systemName: symbol).font(.system(size: 20)).foregroundStyle(tint.opacity(pressed ? 0.25 : 0.6))
                Circle().fill(tint.opacity(pressed ? 0.8 : 0.18)).frame(width: 47, height: 47)
                    .overlay(Circle().strokeBorder(tint.opacity(0.3))).offset(offset)
            }.frame(width: 126, height: 126).contentShape(Circle())
            .gesture(DragGesture(minimumDistance: 0)
                .onChanged { value in
                    pressed = true
                    var delta = CGSize(width: value.location.x - 63, height: value.location.y - 63)
                    let length = hypot(delta.width, delta.height)
                    if length > radius { delta = CGSize(width: delta.width / length * radius, height: delta.height / length * radius) }
                    offset = delta
                    changed([Float(delta.width / radius), -Float(delta.height / radius)], true)
                }
                .onEnded { _ in pressed = false; offset = .zero; changed(.zero, false) })
            .onChange(of: isActive) { _, active in
                if !active { pressed = false; offset = .zero; changed(.zero, false) }
            }
            .onDisappear { pressed = false; offset = .zero; changed(.zero, false) }
            Text(label).font(.system(size: 9, weight: .bold, design: .monospaced)).tracking(2).foregroundStyle(tint.opacity(0.75))
        }.accessibilityElement(children: .ignore).accessibilityLabel(label == "MOVE" ? "Movement joystick" : "Aim and fire Debug Beam")
    }
}
