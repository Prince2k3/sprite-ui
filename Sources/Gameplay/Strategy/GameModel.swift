/// A turn-based game that ``Minimax`` and ``MonteCarloTreeSearch`` can play,
/// in place of `GKGameModel`.
///
/// Unlike `GKGameModel`, a model is a value: ``applying(_:)`` returns the next
/// position instead of changing this one, so strategists never copy or undo moves,
/// and a model can be handed to a background task to think.
///
/// ```swift
/// struct Nim: GameModel {
///     var stones = 10
///     var currentPlayer = 0
///
///     var moves: [Int] { stones == 0 ? [] : Array(1...min(3, stones)) }
///
///     func applying(_ take: Int) -> Nim {
///         Nim(stones: stones - take, currentPlayer: 1 - currentPlayer)
///     }
///
///     // Whoever takes the last stone wins.
///     var outcome: GameOutcome<Int>? { stones == 0 ? .win(1 - currentPlayer) : nil }
/// }
/// ```
public protocol GameModel: Sendable {
    associatedtype Player: Hashable & Sendable
    associatedtype Move: Hashable & Sendable

    /// Whose turn it is.
    var currentPlayer: Player { get }

    /// The current player's legal moves. Strategists try them in this order, so
    /// listing likely-good moves first makes ``Minimax`` faster.
    var moves: [Move] { get }

    /// The position after the current player makes `move`.
    func applying(_ move: Move) -> Self

    /// How the game ended, or `nil` while it's still going.
    var outcome: GameOutcome<Player>? { get }

    /// How good this unfinished position looks for `player`; higher is better.
    ///
    /// ``Minimax`` uses it where it stops looking ahead. Keep it well inside
    /// ±1,000,000, which is reserved for wins and losses. Counting `player`'s
    /// threats minus the opponents' usually works well. The default is 0.
    func score(for player: Player) -> Double
}

extension GameModel {
    public func score(for player: Player) -> Double { 0 }
}

/// How a game ended.
public enum GameOutcome<Player: Hashable & Sendable>: Hashable, Sendable {
    case win(Player)
    case draw

    /// The winner, or `nil` for a draw.
    public var winner: Player? {
        if case .win(let player) = self { player } else { nil }
    }
}

extension GameOutcome: Codable where Player: Codable {}

/// A move and how good a strategist thinks it is.
public struct ScoredMove<Move: Hashable & Sendable>: Hashable, Sendable {
    public var move: Move
    /// ``Minimax``: the score the move leads to with best play.
    /// ``MonteCarloTreeSearch``: the share of simulated games it won, 0 to 1.
    public var score: Double
    /// ``MonteCarloTreeSearch``: how many simulated games started with this move.
    /// ``Minimax``: always 0.
    public var visits: Int

    public init(move: Move, score: Double, visits: Int = 0) {
        self.move = move
        self.score = score
        self.visits = visits
    }
}
