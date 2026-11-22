@testable import Gameplay
import Testing

/// Tic-tac-toe on squares 0...8, X (player 0) first.
struct TicTacToe: GameModel {
    var cells: [Int?] = Array(repeating: nil, count: 9)
    var currentPlayer = 0

    init(_ layout: String = ".........") {
        let marks = Array(layout.filter { $0 != " " })
        cells = marks.map { $0 == "X" ? 0 : $0 == "O" ? 1 : nil }
        currentPlayer = cells.compactMap { $0 }.count % 2
    }

    private static let lines = [[0, 1, 2], [3, 4, 5], [6, 7, 8], [0, 3, 6], [1, 4, 7], [2, 5, 8], [0, 4, 8], [2, 4, 6]]

    var moves: [Int] { outcome == nil ? cells.indices.filter { cells[$0] == nil } : [] }

    func applying(_ square: Int) -> TicTacToe {
        var next = self
        next.cells[square] = currentPlayer
        next.currentPlayer = 1 - currentPlayer
        return next
    }

    var outcome: GameOutcome<Int>? {
        for line in Self.lines {
            if let player = cells[line[0]], cells[line[1]] == player, cells[line[2]] == player { return .win(player) }
        }
        return cells.contains(nil) ? nil : .draw
    }
}

/// Take 1–3 stones; whoever takes the last one wins.
struct Nim: GameModel {
    var stones: Int
    var currentPlayer = 0

    var moves: [Int] { stones == 0 ? [] : Array(1...min(3, stones)) }
    func applying(_ take: Int) -> Nim { Nim(stones: stones - take, currentPlayer: 1 - currentPlayer) }
    var outcome: GameOutcome<Int>? { stones == 0 ? .win(1 - currentPlayer) : nil }
}

@Suite struct MinimaxTests {
    @Test func takesTheWinningMove() {
        // X X .
        // O O .
        // . . .
        let board = TicTacToe("XX. OO. ...")
        #expect(Minimax(maxDepth: 3).bestMove(for: board) == 2)
    }

    @Test func blocksTheOpponent() {
        // X . .
        // O O .   O threatens 3-4-5; X has no win of its own.
        // . . X
        let board = TicTacToe("X.. OO. ..X")
        #expect(board.currentPlayer == 0)
        #expect(Minimax(maxDepth: 2).bestMove(for: board) == 5)
    }

    @Test func prefersTheFasterWin() {
        let scored = Minimax(maxDepth: 5).scoredMoves(for: TicTacToe("XX. OO. ..."))
        #expect(scored[0].move == 2)
        #expect(scored[0].score > scored[1].score, "winning now beats winning later")
        #expect(scored[0].score > 999_000)
    }

    @Test func pruningGivesTheSameScores() {
        var plain = Minimax(maxDepth: 9)
        plain.pruning = false
        for layout in [".........", "X... O....", "X.O .X. ..O", "XO. ... ..."] {
            let board = TicTacToe(layout)
            #expect(Minimax(maxDepth: 9).scoredMoves(for: board) == plain.scoredMoves(for: board))
        }
    }

    @Test func perfectPlayDraws() {
        var board = TicTacToe()
        let ai = Minimax(maxDepth: 9)
        while board.outcome == nil { board = board.applying(ai.bestMove(for: board)!) }
        #expect(board.outcome == .draw)
    }

    @Test func randomTieBreaksAreReproducible() {
        let ai = Minimax(maxDepth: 2)
        var a = SeededGenerator(seed: 5), b = SeededGenerator(seed: 5)
        let first = (0..<20).map { _ in ai.bestMove(for: TicTacToe(), using: &a) }
        let second = (0..<20).map { _ in ai.bestMove(for: TicTacToe(), using: &b) }
        #expect(first == second)
        #expect(Set(first.compactMap { $0 }).count > 1, "equal moves are picked at random")
    }

    @Test func randomMoveComesFromTheBest() {
        let ai = Minimax(maxDepth: 4)
        let board = Nim(stones: 7)
        let topTwo = ai.scoredMoves(for: board).prefix(2).map(\.move)
        var rng = SeededGenerator(seed: 2)
        for _ in 0..<30 {
            #expect(topTwo.contains(ai.randomMove(for: board, fromBest: 2, using: &rng)!))
        }
    }

    @Test func nothingToDoWhenTheGameIsOver() {
        let won = TicTacToe("XXX OO. ...")
        var rng = SeededGenerator(seed: 1)
        #expect(Minimax().bestMove(for: won) == nil)
        #expect(Minimax().bestMove(for: won, using: &rng) == nil)
        #expect(Minimax().scoredMoves(for: won).isEmpty)
    }

    @Test func leavesAMultipleOfFourInNim() {
        let ai = Minimax(maxDepth: 12)
        for stones in [5, 6, 7, 9, 10, 11] {
            #expect((stones - ai.bestMove(for: Nim(stones: stones))!) % 4 == 0)
        }
    }

    @Test func usesTheHeuristicAtTheDepthLimit() {
        struct Race: GameModel {
            var position = 0
            var currentPlayer = 0
            var moves: [Int] { [-1, 1] }
            func applying(_ step: Int) -> Race { Race(position: position + step, currentPlayer: currentPlayer) }
            var outcome: GameOutcome<Int>? { nil }
            func score(for player: Int) -> Double { Double(position) }
        }
        #expect(Minimax(maxDepth: 3).scoredMoves(for: Race()).map(\.score) == [3, 1])
    }
}

@Suite struct MonteCarloTreeSearchTests {
    @Test func takesTheWinningMove() {
        var rng = SeededGenerator(seed: 1)
        #expect(MonteCarloTreeSearch(iterations: 2000).bestMove(for: TicTacToe("XX. OO. ..."), using: &rng) == 2)
    }

    @Test func blocksTheOpponent() {
        // O threatens 3-4-5; X has no win of its own.
        var rng = SeededGenerator(seed: 3)
        let board = TicTacToe("X.. OO. ..X")
        #expect(MonteCarloTreeSearch(iterations: 3000).bestMove(for: board, using: &rng) == 5)
    }

    @Test func leavesAMultipleOfFourInNim() {
        var rng = SeededGenerator(seed: 8)
        let ai = MonteCarloTreeSearch(iterations: 3000)
        for stones in [5, 6, 7] {
            #expect((stones - ai.bestMove(for: Nim(stones: stones), using: &rng)!) % 4 == 0)
        }
    }

    @Test func isReproducibleWithASeed() {
        let ai = MonteCarloTreeSearch(iterations: 500)
        var a = SeededGenerator(seed: 11), b = SeededGenerator(seed: 11)
        #expect(ai.scoredMoves(for: TicTacToe(), using: &a) == ai.scoredMoves(for: TicTacToe(), using: &b))
    }

    @Test func reportsVisitsAndWinRates() {
        var rng = SeededGenerator(seed: 4)
        let scored = MonteCarloTreeSearch(iterations: 900).scoredMoves(for: TicTacToe(), using: &rng)
        #expect(scored.count == 9)
        #expect(scored.map(\.visits).reduce(0, +) == 900, "every game starts with one of the moves")
        #expect(scored.allSatisfy { (0...1).contains($0.score) })
        #expect(scored.map(\.visits) == scored.map(\.visits).sorted(by: >))
    }

    @Test func rolloutLimitCountsAsADraw() {
        var rng = SeededGenerator(seed: 6)
        let scored = MonteCarloTreeSearch(iterations: 200, maxRolloutLength: 0).scoredMoves(for: Nim(stones: 20), using: &rng)
        #expect(scored.allSatisfy { $0.score == 0.5 })
    }

    @Test func nothingToDoWhenTheGameIsOver() {
        var rng = SeededGenerator(seed: 1)
        #expect(MonteCarloTreeSearch().bestMove(for: Nim(stones: 0), using: &rng) == nil)
    }
}
