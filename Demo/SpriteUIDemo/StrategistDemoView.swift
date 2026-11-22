import SpriteUI
import SwiftUI

/// The Strategists milestone: Connect Four against `Minimax` or `MonteCarloTreeSearch`.
/// Tap a column to drop a red disc; the AI thinks on a background task and shows
/// how it rated every column.
struct StrategistDemoView: View {
    @State private var scene = StrategistScene()
    @State private var size = CGSize(width: 400, height: 600)

    var body: some View {
        VStack(spacing: 0) {
            GameView { content in
                scene.build(in: content)
            }
            .onGeometryChange(for: CGSize.self) { $0.size } action: { size = $0 }
            .gesture(SpatialTapGesture().onEnded { tap in
                let x = Float(tap.location.x - size.width / 2)
                scene.tapColumn(at: x)
            })
            .overlay(alignment: .top) {
                Text(scene.caption)
                    .font(.caption.bold())
                    .padding(.horizontal, 10).padding(.vertical, 5)
                    .background(.ultraThinMaterial, in: .capsule)
                    .padding(.top, 8)
            }
            .overlay {
                // The AI's rating of each column, just above the board.
                HStack(spacing: 0) {
                    ForEach(0..<ConnectFour.columns, id: \.self) { column in
                        Text(scene.ratings[column] ?? "")
                            .font(.system(size: 11, weight: .semibold, design: .monospaced))
                            .foregroundStyle(scene.bestColumn == column ? .yellow : .secondary)
                            .frame(width: CGFloat(StrategistScene.cell))
                    }
                }
                .offset(y: -CGFloat(StrategistScene.cell) * 3.5 - 14)
                .allowsHitTesting(false)
            }

            VStack(spacing: 10) {
                Picker("Strategist", selection: $scene.strategist) {
                    ForEach(StrategistScene.Strategist.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)

                Picker("Difficulty", selection: $scene.difficulty) {
                    ForEach(StrategistScene.Difficulty.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)

                HStack {
                    Text(scene.settingText)
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("AI moves first") { scene.newGame(aiFirst: true) }
                    Button("New game") { scene.newGame(aiFirst: false) }
                }
                .buttonStyle(.bordered)
                .tint(.orange)
                .font(.footnote)
            }
            .padding()
        }
        .background(Color.black)
        .preferredColorScheme(.dark)
    }
}

// MARK: Game

/// Connect Four as a `GameModel`. Player 0 is red (you), player 1 is yellow (the AI).
struct ConnectFour: GameModel {
    static let columns = 7, rows = 6
    /// Center columns first: they're usually best, which lets alpha-beta prune more.
    static let columnOrder = [3, 2, 4, 1, 5, 0, 6]

    /// Row-major from the bottom row; -1 is empty.
    private(set) var cells = [Int8](repeating: -1, count: columns * rows)
    private(set) var currentPlayer = 0
    private(set) var winner: Int?
    /// The four cells that won, if any.
    private(set) var winningCells: [Int] = []
    private var filled = 0

    subscript(column: Int, row: Int) -> Int? {
        let value = cells[row * Self.columns + column]
        return value < 0 ? nil : Int(value)
    }

    /// The row a disc dropped in `column` lands on, or `nil` if it's full.
    func landingRow(in column: Int) -> Int? {
        (0..<Self.rows).first { self[column, $0] == nil }
    }

    var moves: [Int] {
        guard outcome == nil else { return [] }
        return Self.columnOrder.filter { self[$0, Self.rows - 1] == nil }
    }

    func applying(_ column: Int) -> ConnectFour {
        var next = self
        guard let row = landingRow(in: column) else { return next }
        next.cells[row * Self.columns + column] = Int8(currentPlayer)
        next.filled += 1
        next.winningCells = next.line(through: column, row)
        if !next.winningCells.isEmpty { next.winner = currentPlayer }
        next.currentPlayer = 1 - currentPlayer
        return next
    }

    var outcome: GameOutcome<Int>? {
        if let winner { return .win(winner) }
        return filled == Self.columns * Self.rows ? .draw : nil
    }

    /// Open lines of four: three of yours with a gap scores 5, two scores 2,
    /// the opponent's the same but negative. Center discs add 3.
    func score(for player: Int) -> Double {
        var total = 0.0
        for window in Self.windows {
            var mine = 0, theirs = 0
            for index in window {
                let value = cells[index]
                if value == Int8(player) { mine += 1 } else if value >= 0 { theirs += 1 }
            }
            if theirs == 0 { total += mine == 3 ? 5 : mine == 2 ? 2 : 0 }
            if mine == 0 { total -= theirs == 3 ? 5 : theirs == 2 ? 2 : 0 }
        }
        for row in 0..<Self.rows {
            if let owner = self[3, row] { total += owner == player ? 3 : -3 }
        }
        return total
    }

    /// The winning four through a newly placed disc, or empty.
    private func line(through column: Int, _ row: Int) -> [Int] {
        guard let player = self[column, row] else { return [] }
        for (dc, dr) in [(1, 0), (0, 1), (1, 1), (1, -1)] {
            var run = [(column, row)]
            for sign in [1, -1] {
                var c = column + sign * dc, r = row + sign * dr
                while (0..<Self.columns).contains(c), (0..<Self.rows).contains(r), self[c, r] == player {
                    run.append((c, r))
                    c += sign * dc; r += sign * dr
                }
            }
            if run.count >= 4 { return run.map { $0.1 * Self.columns + $0.0 } }
        }
        return []
    }

    /// Every horizontal, vertical, and diagonal run of four cells.
    private static let windows: [[Int]] = {
        var windows: [[Int]] = []
        for row in 0..<rows {
            for column in 0..<columns {
                for (dc, dr) in [(1, 0), (0, 1), (1, 1), (1, -1)] {
                    let cells = (0..<4).map { (column + dc * $0, row + dr * $0) }
                    if cells.allSatisfy({ (0..<columns).contains($0.0) && (0..<rows).contains($0.1) }) {
                        windows.append(cells.map { $0.1 * columns + $0.0 })
                    }
                }
            }
        }
        return windows
    }()
}

// MARK: Scene

@MainActor
@Observable
final class StrategistScene {
    enum Strategist: String, CaseIterable { case minimax = "Minimax", monteCarlo = "Monte Carlo" }
    enum Difficulty: String, CaseIterable { case easy = "Easy", medium = "Medium", hard = "Hard" }

    static let cell: Float = 48
    static let human = 0, ai = 1

    // Reactions live in the view's `onChange`, not `didSet` (see MazeScene).
    var strategist = Strategist.minimax
    var difficulty = Difficulty.medium
    private(set) var game = ConnectFour()
    private(set) var thinking = false
    /// The AI's rating of each column from its last move.
    private(set) var ratings: [Int: String] = [:]
    private(set) var bestColumn: Int?

    var caption: String {
        switch game.outcome {
        case .win(Self.human)?: "You win! 🎉"
        case .win?: "\(strategist.rawValue) wins"
        case .draw?: "Draw"
        case nil: thinking ? "\(strategist.rawValue) is thinking…" : "Your turn: tap a column"
        }
    }

    var settingText: String {
        switch strategist {
        case .minimax: "looks \(minimax.maxDepth) moves ahead"
        case .monteCarlo: "\(monteCarlo.iterations) random games per move"
        }
    }

    private var minimax: Minimax {
        let depth = switch difficulty { case .easy: 2; case .medium: 4; case .hard: 6 }
        return Minimax(maxDepth: depth)
    }

    private var monteCarlo: MonteCarloTreeSearch {
        let iterations = switch difficulty { case .easy: 300; case .medium: 1500; case .hard: 6000 }
        return MonteCarloTreeSearch(iterations: iterations)
    }

    @ObservationIgnored private var content: GameViewContent?
    @ObservationIgnored private var discs: [Entity] = []
    @ObservationIgnored private var rng = SeededGenerator(seed: 21)
    /// Bumped by New game so a reply still being worked out is thrown away.
    @ObservationIgnored private var generation = 0

    private static let disc = SpriteImage.disc(diameter: 64)

    func build(in content: GameViewContent) {
        self.content = content
        let board = Entity(
            name: "board",
            components: SpriteComponent(
                color: Color(red: 0.1, green: 0.25, blue: 0.75),
                size: [Self.cell * Float(ConnectFour.columns) + 12, Self.cell * Float(ConnectFour.rows) + 12]
            )
        )
        board.transform.zPosition = 1
        content.add(board)
        for column in 0..<ConnectFour.columns {
            for row in 0..<ConnectFour.rows {
                let hole = Entity(
                    name: "hole \(column),\(row)",
                    components: SpriteComponent(image: Self.disc, size: [Self.cell - 8, Self.cell - 8],
                                                tint: .black, tintAmount: 1)
                )
                hole.position = Self.point(column, row)
                hole.transform.zPosition = 2
                content.add(hole)
            }
        }
    }

    static func point(_ column: Int, _ row: Int) -> SIMD2<Float> {
        [(Float(column) - 3) * cell, (Float(row) - 2.5) * cell]
    }

    func tapColumn(at x: Float) {
        let column = Int((x / Self.cell + 3).rounded())
        guard !thinking, game.outcome == nil, game.currentPlayer == Self.human,
              (0..<ConnectFour.columns).contains(column), game.moves.contains(column)
        else { return }
        play(column)
        if game.outcome == nil { think() }
    }

    func newGame(aiFirst: Bool) {
        generation += 1
        thinking = false
        for disc in discs { content?.remove(disc) }
        discs.removeAll()
        game = ConnectFour()
        ratings = [:]
        bestColumn = nil
        if aiFirst {
            // You pass, so yellow opens.
            game = ConnectFour().passingTurn()
            think()
        }
    }

    private func play(_ column: Int) {
        guard let row = game.landingRow(in: column) else { return }
        let player = game.currentPlayer
        game = game.applying(column)

        let disc = Entity(
            name: "disc",
            components: SpriteComponent(image: Self.disc, size: [Self.cell - 8, Self.cell - 8],
                                        tint: player == Self.human ? .red : .yellow, tintAmount: 1)
        )
        // Starts above the board and falls into place.
        disc.position = [Self.point(column, row).x, Self.cell * 4]
        disc.transform.zPosition = 3
        content?.add(disc)
        discs.append(disc)
        let fall = Double(Self.cell * 4 - Self.point(column, row).y) / 900
        withAnimation(.easeIn(duration: fall)) {
            disc.position = Self.point(column, row)
        } completion: { [weak self] in
            self?.highlightWin()
        }
    }

    private func think() {
        thinking = true
        let game = self.game
        let strategist = self.strategist
        let minimax = self.minimax, monteCarlo = self.monteCarlo
        let seed = rng.split()
        let generation = self.generation
        Task {
            let (move, scored) = await Task.detached(priority: .userInitiated) {
                var moveRNG = seed
                switch strategist {
                case .minimax:
                    let scored = minimax.scoredMoves(for: game)
                    let top = scored.first?.score
                    let move = scored.filter { $0.score == top }.randomElement(using: &moveRNG)?.move
                    return (move, scored)
                case .monteCarlo:
                    let scored = monteCarlo.scoredMoves(for: game, using: &moveRNG)
                    return (scored.first?.move, scored)
                }
            }.value
            guard generation == self.generation, let move else { return }
            ratings = Dictionary(uniqueKeysWithValues: scored.map { ($0.move, Self.rating($0, strategist)) })
            bestColumn = move
            thinking = false
            play(move)
        }
    }

    private static func rating(_ scored: ScoredMove<Int>, _ strategist: Strategist) -> String {
        switch strategist {
        case .minimax:
            if scored.score > 900_000 { "win" } else if scored.score < -900_000 { "lose" } else { "\(Int(scored.score))" }
        case .monteCarlo:
            "\(Int((scored.score * 100).rounded()))%"
        }
    }

    /// Fades every disc except the winning four.
    private func highlightWin() {
        guard !game.winningCells.isEmpty else { return }
        let winners = Set(game.winningCells.map { Self.point($0 % ConnectFour.columns, $0 / ConnectFour.columns) })
        withAnimation(.easeOut(duration: 0.4)) {
            for disc in discs where !winners.contains(disc.position) {
                disc.components[SpriteComponent.self]?.opacity = 0.3
            }
        }
    }
}

extension ConnectFour {
    /// The same board with the other player to move.
    func passingTurn() -> ConnectFour {
        var copy = self
        copy.currentPlayer = 1 - currentPlayer
        return copy
    }
}

extension SpriteImage {
    /// A white, antialiased disc to tint with `SpriteComponent`'s color.
    static func disc(diameter: Int) -> SpriteImage {
        let radius = Float(diameter) / 2
        var pixels: [UInt8] = []
        pixels.reserveCapacity(diameter * diameter * 4)
        for y in 0..<diameter {
            for x in 0..<diameter {
                let dx = Float(x) + 0.5 - radius, dy = Float(y) + 0.5 - radius
                let coverage = min(max(radius - (dx * dx + dy * dy).squareRoot(), 0), 1)
                pixels += [255, 255, 255, UInt8(coverage * 255)]
            }
        }
        return SpriteImage(width: diameter, height: diameter, pixels: pixels)
    }
}
