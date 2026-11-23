/// Picks moves by looking every possible reply a fixed number of turns ahead.
///
/// It assumes each opponent always makes the reply that's worst for the player
/// it's choosing for, and uses alpha-beta pruning to skip lines that can't
/// change the answer. Where it stops looking, it asks the model's
/// ``GameModel/score(for:)``.
///
/// ```swift
/// let ai = Minimax(maxDepth: 6)
/// if let move = ai.bestMove(for: board, using: &rng) {
///     board = board.applying(move)
/// }
/// ```
///
/// With more than two players, every other player counts as an opponent.
public struct Minimax: Sendable, Hashable, Codable {
    /// How many moves ahead to look, counting both sides. At least 1.
    public var maxDepth: Int

    /// Turns off alpha-beta pruning. Results are identical; only slower. For tests.
    var pruning = true

    static let winScore = 1_000_000.0

    public init(maxDepth: Int = 4) {
        self.maxDepth = max(1, maxDepth)
    }

    private enum CodingKeys: String, CodingKey { case maxDepth }

    /// Every legal move with the score it leads to for the current player,
    /// best first. Equal scores keep the model's move order. Empty when the game is over.
    ///
    /// A win scores close to +1,000,000 (higher for faster wins), a loss close to
    /// −1,000,000 (higher for slower losses), and a draw 0.
    public func scoredMoves<Model: GameModel>(for model: Model) -> [ScoredMove<Model.Move>] {
        guard model.outcome == nil else { return [] }
        let me = model.currentPlayer
        let scored = model.moves.map { move in
            ScoredMove(move: move, score: search(model.applying(move), root: me, depth: maxDepth - 1, ply: 1,
                                                 alpha: -.infinity, beta: .infinity))
        }
        return scored.enumerated()
            .sorted { $0.element.score != $1.element.score ? $0.element.score > $1.element.score : $0.offset < $1.offset }
            .map(\.element)
    }

    /// The best move, choosing randomly between equally good ones.
    /// Returns `nil` when the game is over.
    public func bestMove<Model: GameModel, G: RandomNumberGenerator>(
        for model: Model, using generator: inout G
    ) -> Model.Move? {
        let scored = scoredMoves(for: model)
        guard let top = scored.first?.score else { return nil }
        return scored.prefix { $0.score == top }.randomElement(using: &generator)?.move
    }

    /// The best move. Ties go to the move listed first by the model.
    public func bestMove<Model: GameModel>(for model: Model) -> Model.Move? {
        scoredMoves(for: model).first?.move
    }

    /// A random move from the `count` best.
    /// Use it to make an easier opponent.
    public func randomMove<Model: GameModel, G: RandomNumberGenerator>(
        for model: Model, fromBest count: Int, using generator: inout G
    ) -> Model.Move? {
        scoredMoves(for: model).prefix(max(1, count)).randomElement(using: &generator)?.move
    }

    /// The score of `model` for `root`, looking `depth` more moves ahead.
    private func search<Model: GameModel>(
        _ model: Model, root: Model.Player, depth: Int, ply: Int, alpha: Double, beta: Double
    ) -> Double {
        if let outcome = model.outcome {
            switch outcome {
            case .draw: return 0
            case .win(let winner):
                // Prefer winning sooner and losing later.
                return winner == root ? Self.winScore - Double(ply) : -Self.winScore + Double(ply)
            }
        }
        let moves = model.moves
        if depth <= 0 || moves.isEmpty { return model.score(for: root) }

        var alpha = alpha, beta = beta
        if model.currentPlayer == root {
            var best = -Double.infinity
            for move in moves {
                best = max(best, search(model.applying(move), root: root, depth: depth - 1, ply: ply + 1,
                                        alpha: alpha, beta: beta))
                alpha = max(alpha, best)
                if pruning && alpha >= beta { break }
            }
            return best
        } else {
            var best = Double.infinity
            for move in moves {
                best = min(best, search(model.applying(move), root: root, depth: depth - 1, ply: ply + 1,
                                        alpha: alpha, beta: beta))
                beta = min(beta, best)
                if pruning && alpha >= beta { break }
            }
            return best
        }
    }
}
