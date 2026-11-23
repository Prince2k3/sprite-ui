import Foundation

extension DecisionTree {
    /// Learns a tree from examples.
    ///
    /// Each example is a set of answers and the action that was right for them.
    /// The tree asks first about whatever separates the actions best (the most
    /// information gain, as in ID3), then repeats for each branch.
    ///
    /// - Flags and text are split by value, one branch each.
    /// - Numbers are split at the threshold that separates the actions best, so a
    ///   few examples like `distance: 30` and `distance: 200` learn `distance < 115`.
    ///   A number can be asked about again further down with a new threshold.
    /// - A missing answer is grouped with the `otherwise` branch.
    ///
    /// ```swift
    /// let tree = DecisionTree(learningFrom: [
    ///     ["hungry": true,  "distance": 40],
    ///     ["hungry": true,  "distance": 300],
    ///     ["hungry": false, "distance": 50],
    /// ], actions: [Move.eat, .eat, .flee])
    /// ```
    ///
    /// Learning is deterministic: the same examples always give the same tree.
    ///
    /// - Parameters:
    ///   - examples: The answers for each example.
    ///   - actions: The right action for each example, in the same order.
    ///   - maxDepth: The most questions on any path. `nil` asks as many as needed.
    ///     Where it stops early, the leaf takes the most common action.
    public init(learningFrom examples: [DecisionAnswers], actions: [Action], maxDepth: Int? = nil) {
        precondition(!examples.isEmpty, "Learning a decision tree needs at least one example")
        precondition(examples.count == actions.count, "Give one action per example")
        let attributes = Set(examples.flatMap(\.keys)).sorted()
        let learner = Learner(examples: examples, actions: actions)
        self.init(learner.grow(Array(examples.indices), attributes: attributes, depth: 0, maxDepth: maxDepth))
    }
}

private struct Learner<Action: Hashable & Sendable> {
    let examples: [DecisionAnswers]
    let actions: [Action]

    /// One way to split the rows: each branch's rows, then the `otherwise` rows.
    struct Split {
        var attribute: String
        var branches: [(DecisionCondition, [Int])]
        var otherwise: [Int]
        /// Whether the attribute is used up (flags and text) or can be asked again (numbers).
        var consumesAttribute: Bool
        var gain: Double
    }

    func grow(_ rows: [Int], attributes: [String], depth: Int, maxDepth: Int?) -> DecisionNode<Action> {
        let leaf = DecisionNode<Action>.action(majority(rows))
        if Set(rows.map { actions[$0] }).count == 1 { return leaf }
        if let maxDepth, depth >= maxDepth { return leaf }

        let parentEntropy = entropy(rows)
        var best: Split?
        for attribute in attributes {
            guard let split = bestSplit(rows, on: attribute, parentEntropy: parentEntropy) else { continue }
            // Strictly greater, so ties go to the attribute that sorts first.
            if split.gain > (best?.gain ?? 1e-9) { best = split }
        }
        guard let best else { return leaf }

        let remaining = best.consumesAttribute ? attributes.filter { $0 != best.attribute } : attributes
        let branches = best.branches.map { condition, subset in
            DecisionBranch(condition, grow(subset, attributes: remaining, depth: depth + 1, maxDepth: maxDepth))
        }
        let otherwise: DecisionNode<Action> = best.otherwise.isEmpty
            ? leaf
            : grow(best.otherwise, attributes: remaining, depth: depth + 1, maxDepth: maxDepth)
        return Self.simplified(.question(attribute: best.attribute, branches: branches, otherwise: otherwise))
    }

    private func bestSplit(_ rows: [Int], on attribute: String, parentEntropy: Double) -> Split? {
        let answered = rows.filter { examples[$0][attribute] != nil }
        guard !answered.isEmpty else { return nil }
        let isNumeric = answered.allSatisfy { examples[$0][attribute]?.number != nil }
        return isNumeric
            ? numericSplit(rows, on: attribute, parentEntropy: parentEntropy)
            : categoricalSplit(rows, on: attribute, parentEntropy: parentEntropy)
    }

    /// One branch per answer, in the order answers first appear.
    private func categoricalSplit(_ rows: [Int], on attribute: String, parentEntropy: Double) -> Split? {
        var order: [DecisionValue] = []
        var groups: [DecisionValue: [Int]] = [:]
        var missing: [Int] = []
        for row in rows {
            guard let value = examples[row][attribute] else { missing.append(row); continue }
            if groups[value] == nil { order.append(value) }
            groups[value, default: []].append(row)
        }
        let parts = order.map { groups[$0]! } + (missing.isEmpty ? [] : [missing])
        guard parts.count > 1 else { return nil }
        return Split(
            attribute: attribute,
            branches: order.map { (.equals($0), groups[$0]!) },
            otherwise: missing,
            consumesAttribute: true,
            gain: parentEntropy - weightedEntropy(parts, total: rows.count)
        )
    }

    /// Below a threshold, or otherwise. Tries the midpoint between each pair of
    /// neighboring values and keeps the best.
    private func numericSplit(_ rows: [Int], on attribute: String, parentEntropy: Double) -> Split? {
        let numbered = rows.compactMap { row in examples[row][attribute]?.number.map { (row, $0) } }
            .sorted { $0.1 < $1.1 }
        let missing = rows.filter { examples[$0][attribute] == nil }
        var bestThreshold: Double?
        var bestGain = -Double.infinity
        for i in 1..<max(numbered.count, 1) where numbered[i].1 > numbered[i - 1].1 {
            let below = numbered[..<i].map(\.0)
            let rest = numbered[i...].map(\.0) + missing
            let gain = parentEntropy - weightedEntropy([below, rest], total: rows.count)
            if gain > bestGain + 1e-12 {
                bestGain = gain
                bestThreshold = (numbered[i].1 + numbered[i - 1].1) / 2
            }
        }
        guard let threshold = bestThreshold else { return nil }
        let below = numbered.filter { $0.1 < threshold }.map(\.0)
        let rest = numbered.filter { $0.1 >= threshold }.map(\.0) + missing
        return Split(
            attribute: attribute,
            branches: [(.below(threshold), below)],
            otherwise: rest,
            consumesAttribute: false,
            gain: bestGain
        )
    }

    /// The most common action in `rows`. Ties go to the one seen first.
    private func majority(_ rows: [Int]) -> Action {
        var counts: [Action: Int] = [:]
        var order: [Action] = []
        for row in rows {
            let action = actions[row]
            if counts[action] == nil { order.append(action) }
            counts[action, default: 0] += 1
        }
        var best = order[0]
        for action in order.dropFirst() where counts[action]! > counts[best]! { best = action }
        return best
    }

    private func entropy(_ rows: [Int]) -> Double {
        var counts: [Action: Int] = [:]
        for row in rows { counts[actions[row], default: 0] += 1 }
        let total = Double(rows.count)
        return counts.values.reduce(0) { sum, count in
            let p = Double(count) / total
            return sum - p * log2(p)
        }
    }

    private func weightedEntropy(_ parts: [[Int]], total: Int) -> Double {
        parts.reduce(0) { $0 + Double($1.count) / Double(total) * entropy($1) }
    }

    /// Collapses a question whose every outcome is the same action.
    private static func simplified(_ node: DecisionNode<Action>) -> DecisionNode<Action> {
        guard case .question(_, let branches, let otherwise) = node else { return node }
        let outcomes = branches.map(\.node) + (otherwise.map { [$0] } ?? [])
        if let first = outcomes.first, case .action = first, outcomes.allSatisfy({ $0 == first }) {
            return first
        }
        return node
    }
}
