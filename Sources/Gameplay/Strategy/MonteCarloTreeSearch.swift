import Foundation

/// Picks moves by playing many quick random games and favoring the moves that
/// win most often.
///
/// Unlike ``Minimax`` it needs no ``GameModel/score(for:)``, so it suits games
/// that are hard to score or have too many moves to look far ahead. More
/// ``iterations`` play better but take longer.
///
/// ```swift
/// let ai = MonteCarloTreeSearch(iterations: 2000)
/// var rng = SeededGenerator(seed: 7)
/// let move = ai.bestMove(for: board, using: &rng)
/// ```
///
/// Each iteration walks down the tree of moves tried so far, picking the child
/// with the best UCT score, adds one untried move, plays randomly to the end,
/// and records the result on the way back up. The answer is the most-tried move.
public struct MonteCarloTreeSearch: Sendable, Hashable, Codable {
    /// How many random games to play per decision.
    public var iterations: Int
    /// How much to try less-explored moves rather than the best so far.
    /// √2 is the textbook value.
    public var exploration: Double
    /// Stops a random game after this many moves and counts it as a draw.
    /// `nil` plays every game to the end.
    public var maxRolloutLength: Int?

    public init(iterations: Int = 1000, exploration: Double = 2.0.squareRoot(), maxRolloutLength: Int? = nil) {
        self.iterations = max(1, iterations)
        self.exploration = exploration
        self.maxRolloutLength = maxRolloutLength
    }

    /// The most-tried move, or `nil` when the game is over.
    public func bestMove<Model: GameModel, G: RandomNumberGenerator>(
        for model: Model, using generator: inout G
    ) -> Model.Move? {
        scoredMoves(for: model, using: &generator).first?.move
    }

    /// Every legal move with how often it was tried (``ScoredMove/visits``) and the
    /// share of those games the current player won (``ScoredMove/score``, draws
    /// count half), most-tried first. Empty when the game is over.
    public func scoredMoves<Model: GameModel, G: RandomNumberGenerator>(
        for model: Model, using generator: inout G
    ) -> [ScoredMove<Model.Move>] {
        guard model.outcome == nil, !model.moves.isEmpty else { return [] }
        var tree = [Node(model: model, parent: nil, move: nil, mover: nil)]

        for _ in 0..<iterations {
            // 1. Selection: follow the best UCT child while every move has been tried.
            var index = 0
            while tree[index].untried.isEmpty, !tree[index].children.isEmpty {
                index = bestChild(of: index, in: tree)
            }
            // 2. Expansion: add one untried move.
            if !tree[index].untried.isEmpty {
                let pick = Int.random(in: 0..<tree[index].untried.count, using: &generator)
                let move = tree[index].untried.remove(at: pick)
                let parent = tree[index].model
                tree.append(Node(model: parent.applying(move), parent: index, move: move, mover: parent.currentPlayer))
                tree[index].children.append(tree.count - 1)
                index = tree.count - 1
            }
            // 3. Simulation: play randomly to the end.
            let outcome = rollout(from: tree[index].model, using: &generator)
            // 4. Backpropagation: credit each node from the view of the player who moved into it.
            var current: Int? = index
            while let i = current {
                tree[i].visits += 1
                if let mover = tree[i].mover {
                    switch outcome {
                    case .win(let winner)?: tree[i].reward += winner == mover ? 1 : 0
                    case .draw?, nil: tree[i].reward += 0.5
                    }
                }
                current = tree[i].parent
            }
        }

        let root = tree[0]
        // Moves never tried (only possible with fewer iterations than moves) come last.
        let tried = root.children.map { tree[$0] }
        let scored = tried.map { node in
            ScoredMove(move: node.move!, score: node.reward / Double(node.visits), visits: node.visits)
        }
        .sorted { $0.visits != $1.visits ? $0.visits > $1.visits : $0.score > $1.score }
        return scored + root.untried.map { ScoredMove(move: $0, score: 0, visits: 0) }
    }

    private struct Node<Model: GameModel> {
        let model: Model
        let parent: Int?
        let move: Model.Move?
        /// The player who made `move`; rewards are from their side.
        let mover: Model.Player?
        var children: [Int] = []
        var untried: [Model.Move]
        var visits = 0
        var reward = 0.0

        init(model: Model, parent: Int?, move: Model.Move?, mover: Model.Player?) {
            self.model = model
            self.parent = parent
            self.move = move
            self.mover = mover
            self.untried = model.outcome == nil ? model.moves : []
        }
    }

    private func bestChild<Model>(of index: Int, in tree: [Node<Model>]) -> Int {
        let logVisits = log(Double(tree[index].visits))
        var best = tree[index].children[0]
        var bestValue = -Double.infinity
        for child in tree[index].children {
            let node = tree[child]
            let visits = Double(node.visits)
            let value = node.reward / visits + exploration * (logVisits / visits).squareRoot()
            if value > bestValue { best = child; bestValue = value }
        }
        return best
    }

    /// Plays random moves until the game ends; `nil` if ``maxRolloutLength`` runs out first.
    private func rollout<Model: GameModel, G: RandomNumberGenerator>(
        from model: Model, using generator: inout G
    ) -> GameOutcome<Model.Player>? {
        var model = model
        var length = 0
        while true {
            if let outcome = model.outcome { return outcome }
            if let limit = maxRolloutLength, length >= limit { return nil }
            guard let move = model.moves.randomElement(using: &generator) else { return .draw }
            model = model.applying(move)
            length += 1
        }
    }
}

