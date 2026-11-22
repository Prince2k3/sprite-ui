import SpriteUI
import SwiftUI
import simd

/// A complete SpriteUI game host. The game itself never creates an SKNode or
/// imports GameplayKit: its entities are rendered by GameView's backend.
public struct DemoBotsView: View {
    @State private var game = DemoBotsSession()
    @State private var selectedLevel = 1
    @State private var showsHelp = false
    @State private var keyboard = Set<String>()
    @Environment(\.scenePhase) private var scenePhase

    public init() {}

    public var body: some View {
        GeometryReader { geometry in
            ZStack {
                Color(red: 0.025, green: 0.07, blue: 0.06)
                GameView { content in game.build(in: content) }
                    .contentShape(Rectangle())
                    .gesture(SpatialTapGesture().onEnded { game.sendPlayer(toView: $0.location) })
                    .onGeometryChange(for: CGSize.self) { $0.size } action: { game.resize($0) }
                if game.phase == .home { home(size: geometry.size) }
                else {
                    gameplayHUD(size: geometry.size)
                    if game.phase == .paused { pauseMenu }
                    if game.phase == .won || game.phase == .lost { resultMenu }
                }
            }
        }
        .ignoresSafeArea()
        .preferredColorScheme(.dark)
        .focusable()
        .focusEffectDisabled()
        .onKeyPress(phases: [.down, .repeat, .up]) { press in
            let key: String
            switch press.key {
            case .upArrow: key = "w"
            case .downArrow: key = "s"
            case .leftArrow: key = "a"
            case .rightArrow: key = "d"
            default: key = String(press.key.character).lowercased()
            }
            if press.phase == .up { keyboard.remove(key) } else { keyboard.insert(key) }
            if press.phase == .down && (key == "p" || press.key == .escape) {
                game.phase == .playing ? game.pause() : game.resume()
                return .handled
            }
            let known = ["w", "a", "s", "d", "f", " "]
            guard known.contains(key) || [.upArrow, .downArrow, .leftArrow, .rightArrow].contains(press.key) else { return .ignored }
            let x = (keyboard.contains("d") ? 1 : 0) - (keyboard.contains("a") ? 1 : 0)
            let y = (keyboard.contains("w") ? 1 : 0) - (keyboard.contains("s") ? 1 : 0)
            game.move([Float(x), Float(y)])
            game.aim(.zero, firing: keyboard.contains("f") || keyboard.contains(" "))
            return .handled
        }
        .onChange(of: scenePhase) { _, phase in if phase != .active { keyboard = []; game.pause() } }
        .sheet(isPresented: $showsHelp) { instructions }
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
                Button { game.start(level: selectedLevel) } label: {
                    HStack { Image(systemName: "play.fill"); Text("Enter Level \(selectedLevel)").fontWeight(.bold) }
                        .frame(maxWidth: .infinity).padding(.vertical, 17)
                }
                .buttonStyle(.plain).foregroundStyle(.black)
                .background(Color(red: 0.7, green: 0.95, blue: 0.15), in: RoundedRectangle(cornerRadius: 16))
                .accessibilityIdentifier("start-game")
                Button("How to play", systemImage: "gamecontroller") { showsHelp = true }
                    .font(.subheadline).foregroundStyle(.white.opacity(0.8)).buttonStyle(.plain)
                if !game.message.isEmpty && game.message.hasPrefix("Couldn’t") {
                    Text(game.message).font(.caption).foregroundStyle(.orange).textSelection(.enabled)
                }
                Text("Based on Apple’s DemoBots sample · Artwork © Apple Inc.")
                    .font(.system(size: 10)).foregroundStyle(.white.opacity(0.35))
            }
            .padding(28).frame(maxWidth: 610).frame(maxWidth: .infinity)
            .padding(.top, size.height < 500 ? 10 : 65)
        }
        .background(LinearGradient(colors: [Color(red: 0.02, green: 0.18, blue: 0.12), .black], startPoint: .topLeading, endPoint: .bottomTrailing))
    }

    private func levelCard(_ number: Int, title: String, bots: String) -> some View {
        Button { selectedLevel = number } label: {
            VStack(alignment: .leading, spacing: 10) {
                Text(String(format: "%02d", number)).font(.system(size: 28, weight: .light, design: .monospaced))
                    .foregroundStyle(selectedLevel == number ? .black : .mint)
                Text(title).font(.system(size: 12, weight: .semibold)).lineLimit(2).frame(height: 30, alignment: .top)
                Text(bots).font(.system(size: 9)).opacity(0.7).lineLimit(1).minimumScaleFactor(0.6)
            }
            .frame(maxWidth: .infinity, alignment: .leading).padding(12)
            .foregroundStyle(selectedLevel == number ? .black : .white)
            .background(selectedLevel == number ? Color(red: 0.7, green: 0.95, blue: 0.15) : Color.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 14))
        }.buttonStyle(.plain).accessibilityLabel("Level \(number): \(title)").accessibilityAddTraits(selectedLevel == number ? .isSelected : [])
    }

    private func gameplayHUD(size: CGSize) -> some View {
        VStack(spacing: 0) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("LEVEL 0\(game.levelNumber)").font(.system(size: 10, weight: .bold, design: .monospaced)).tracking(2).foregroundStyle(.mint)
                    Text("\(game.totalBots - game.badBots) / \(game.totalBots) restored").font(.system(size: 18, weight: .bold, design: .rounded))
                }
                Spacer()
                Text(String(format: "%d:%02d", game.secondsLeft / 60, game.secondsLeft % 60))
                    .font(.system(size: 26, weight: .medium, design: .monospaced)).monospacedDigit()
                    .foregroundStyle(game.secondsLeft < 30 ? .red : .white)
                Button { game.pause() } label: { Image(systemName: "pause.fill").frame(width: 42, height: 42) }
                    .buttonStyle(.plain).background(.white.opacity(0.12), in: Circle()).accessibilityLabel("Pause game")
            }
            .padding(16).background(.black.opacity(0.8), in: RoundedRectangle(cornerRadius: 20))
            HStack {
                if game.isRecharging {
                    Text("RECHARGING…").font(.system(size: 12, weight: .bold, design: .monospaced))
                        .padding(10).background(.black.opacity(0.8), in: Capsule()).foregroundStyle(.cyan)
                }
                Spacer()
                minimap.frame(width: 85, height: 96).padding(9).background(.black.opacity(0.7), in: RoundedRectangle(cornerRadius: 12))
            }.padding(.top, 8)
            Spacer(minLength: 0)
            VStack(spacing: 6) {
                Text(game.isRecharging ? "POWER RESTORING" : "DEBUG BEAM")
                    .font(.system(size: 9, weight: .bold, design: .monospaced)).tracking(2)
                meter(value: game.beamFraction, color: .cyan).frame(width: 125, height: 5)
                meter(value: game.charge / 100, color: game.charge < 30 ? .red : .green).frame(width: 125, height: 3)
            }
            .padding(10).background(.black.opacity(0.7), in: RoundedRectangle(cornerRadius: 10))
            .padding(.bottom, 10)
            HStack(alignment: .bottom) {
                BotThumbstick(label: "MOVE", symbol: "arrow.up.and.down.and.arrow.left.and.right", tint: .white) { vector, _ in game.move(vector) }
                Spacer()
                BotThumbstick(label: "AIM + DEBUG", symbol: "bolt.fill", tint: .cyan) { vector, pressed in game.aim(vector, firing: pressed) }
            }
        }
        .padding(.horizontal, size.width > 650 ? 32 : 20)
        .padding(.top, size.width > size.height ? 18 : 60)
        .padding(.bottom, size.width > size.height ? 18 : 40)
        .allowsHitTesting(game.phase == .playing)
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

    private var pauseMenu: some View {
        menu(title: "Taking a breather?", subtitle: "The circuit can wait.") {
            Button("Resume", systemImage: "play.fill") { game.resume() }.buttonStyle(BotPrimaryButton())
            Toggle("Show bot paths", isOn: $game.showsPaths).tint(.mint)
            Toggle("Sound effects", isOn: $game.soundEnabled).tint(.mint)
            Button("Restart level") { game.start(level: game.levelNumber) }.buttonStyle(.bordered)
            Button("Level select") { game.home() }.buttonStyle(.plain).foregroundStyle(.secondary)
        }
    }
    private var resultMenu: some View {
        let won = game.phase == .won
        return menu(title: won ? (game.levelNumber == 3 ? "All systems go." : "Circuit restored!") : "Out of time.",
                    subtitle: won ? "Every bot is back on your side." : "\(game.badBots) bots still need debugging. Try another approach.") {
            Image(systemName: won ? "checkmark.seal.fill" : "clock.badge.exclamationmark")
                .font(.system(size: 56)).foregroundStyle(won ? .mint : .orange).padding(8)
            if won && game.levelNumber < 3 {
                Button("Next level", systemImage: "arrow.right") { game.start(level: game.levelNumber + 1) }.buttonStyle(BotPrimaryButton())
            }
            Button(won ? "Play again" : "Try again", systemImage: "arrow.clockwise") { game.start(level: game.levelNumber) }.buttonStyle(BotPrimaryButton())
            Button("Level select") { game.home() }.buttonStyle(.plain).foregroundStyle(.secondary)
        }
    }
    private func menu<Content: View>(title: String, subtitle: String, @ViewBuilder content: () -> Content) -> some View {
        ZStack {
            Color.black.opacity(0.7).ignoresSafeArea()
            VStack(spacing: 20) {
                Text(title).font(.title.bold())
                Text(subtitle).font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center)
                content()
            }.padding(28).frame(maxWidth: 350).background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 28)).padding(20)
        }
    }
    private var instructions: some View {
        VStack(alignment: .leading, spacing: 24) {
            Text("Field guide").font(.largeTitle.bold())
            Label("Move with the left stick, or tap the floor to walk there.", systemImage: "move.3d")
            Label("Hold the right stick to fire. Drag it to aim; press its center to target the nearest visible bad bot.", systemImage: "bolt.fill")
            Label("Keep the beam on a red bot until it turns green. Watch your beam’s charge.", systemImage: "battery.75percent")
            Label("GroundBots chase and infect. FlyingBots blast nearby bots—curing one can cure its neighbors too.", systemImage: "airplane")
            Label("Out of charge? You recover automatically. Restore all bots before the clock runs out.", systemImage: "clock")
            Text("Keyboard: WASD to move · F or Space to debug · P to pause").font(.caption).foregroundStyle(.secondary)
            Button("Ready", systemImage: "checkmark") { showsHelp = false }.buttonStyle(BotPrimaryButton())
        }.padding(30).frame(maxWidth: 560).presentationDetents([.large])
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
            Text(label).font(.system(size: 9, weight: .bold, design: .monospaced)).tracking(2).foregroundStyle(tint.opacity(0.75))
        }.accessibilityElement(children: .ignore).accessibilityLabel(label == "MOVE" ? "Movement joystick" : "Aim and fire Debug Beam")
    }
}
