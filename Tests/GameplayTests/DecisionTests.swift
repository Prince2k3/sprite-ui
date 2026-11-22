import Foundation
import Gameplay
import Testing

enum Move: String, Hashable, Codable, Sendable { case attack, chase, patrol, rest, eat, flee }

@Suite struct DecisionTreeTests {
    let guardTree = DecisionTree<Move>(
        .ask("canSeePlayer",
            .when(true, .ask("distance",
                .when(.below(60), .action(.attack)),
                otherwise: .action(.chase))),
            otherwise: .random([(3, .action(.patrol)), (1, .action(.rest))]))
    )

    @Test func followsMatchingBranches() {
        var rng = SeededGenerator(seed: 1)
        #expect(guardTree.decide(["canSeePlayer": true, "distance": 20], using: &rng) == .attack)
        #expect(guardTree.decide(["canSeePlayer": true, "distance": 60], using: &rng) == .chase)
        #expect(guardTree.decide(["canSeePlayer": true], using: &rng) == .chase, "missing answer takes otherwise")
    }

    @Test func returnsNilWithoutMatchOrOtherwise() {
        let tree = DecisionTree<Move>(.ask("weather", .when("rain", .action(.rest))))
        #expect(tree.decide(["weather": "sun"]) == nil)
        #expect(tree.decide([:]) == nil)
        #expect(tree.decide(["weather": "rain"]) == .rest)
    }

    @Test func conditionsMatch() {
        #expect(DecisionCondition.below(5).matches(4.9))
        #expect(!DecisionCondition.below(5).matches(5))
        #expect(DecisionCondition.atLeast(5).matches(5))
        #expect(DecisionCondition.within(1..<3).matches(2))
        #expect(!DecisionCondition.within(1..<3).matches(3))
        #expect(!DecisionCondition.below(5).matches("4"), "text is not a number")
        #expect(DecisionCondition.oneOf(["a", "b"]).matches("b"))
        #expect(DecisionCondition(integerLiteral: 2).matches(2.0))
    }

    @Test func randomBranchesFollowWeights() {
        var rng = SeededGenerator(seed: 9)
        var counts: [Move: Int] = [:]
        for _ in 0..<4000 { counts[guardTree.decide(["canSeePlayer": false], using: &rng)!, default: 0] += 1 }
        let patrolShare = Double(counts[.patrol]!) / 4000
        #expect(abs(patrolShare - 0.75) < 0.03)
        #expect(counts.keys.sorted { $0.rawValue < $1.rawValue } == [.patrol, .rest])
    }

    @Test func randomPicksAreReproducible() {
        var a = SeededGenerator(seed: 4), b = SeededGenerator(seed: 4)
        let first = (0..<50).map { _ in guardTree.decide(["canSeePlayer": false], using: &a) }
        let second = (0..<50).map { _ in guardTree.decide(["canSeePlayer": false], using: &b) }
        #expect(first == second)
    }

    @Test func listsReachableActions() {
        #expect(guardTree.actions == [.attack, .chase, .patrol, .rest])
    }

    @Test func describesItselfAsText() {
        #expect(guardTree.description == """
        canSeePlayer?
        ├─ true → distance?
        │  ├─ < 60 → attack
        │  └─ otherwise → chase
        └─ otherwise → random
           ├─ 75% → patrol
           └─ 25% → rest
        """)
    }

    @Test func roundTripsThroughCodable() throws {
        let data = try JSONEncoder().encode(guardTree)
        #expect(try JSONDecoder().decode(DecisionTree<Move>.self, from: data) == guardTree)
    }
}

@Suite struct DecisionLearningTests {
    @Test func learnsACategoricalRule() {
        let tree = DecisionTree(learningFrom: [
            ["hungry": true, "tired": false],
            ["hungry": true, "tired": true],
            ["hungry": false, "tired": true],
            ["hungry": false, "tired": false],
        ], actions: [Move.eat, .eat, .rest, .patrol])
        #expect(tree.decide(["hungry": true, "tired": true]) == .eat)
        #expect(tree.decide(["hungry": false, "tired": true]) == .rest)
        #expect(tree.decide(["hungry": false, "tired": false]) == .patrol)
        if case .question(let first, _, _) = tree.root {
            #expect(first == "hungry", "the most informative question comes first")
        } else {
            Issue.record("expected a question at the root")
        }
    }

    @Test func learnsNumericThresholds() {
        let tree = DecisionTree(learningFrom: [
            ["distance": 10], ["distance": 30], ["distance": 50],
            ["distance": 90], ["distance": 150], ["distance": 400],
        ], actions: [Move.attack, .attack, .attack, .chase, .chase, .patrol])
        #expect(tree.decide(["distance": 0]) == .attack)
        #expect(tree.decide(["distance": 69]) == .attack)
        #expect(tree.decide(["distance": 71]) == .chase)
        #expect(tree.decide(["distance": 250]) == .chase)
        #expect(tree.decide(["distance": 300]) == .patrol)
    }

    @Test func reproducesEveryConsistentExample() {
        var rng = SeededGenerator(seed: 3)
        var examples: [DecisionAnswers] = []
        var actions: [Move] = []
        for _ in 0..<200 {
            let visible = rng.chance(0.5)
            let distance = Double(Int.random(in: 0..<300, using: &rng))
            let food = Double(Int.random(in: 0...10, using: &rng)) / 10
            examples.append(["visible": .bool(visible), "distance": .number(distance), "food": .number(food)])
            actions.append(visible && distance < 80 ? .flee : food < 0.3 ? .eat : visible ? .chase : .patrol)
        }
        let tree = DecisionTree(learningFrom: examples, actions: actions)
        for (answers, action) in zip(examples, actions) {
            #expect(tree.decide(answers) == action)
        }
    }

    @Test func maxDepthLimitsQuestions() {
        let examples: [DecisionAnswers] = [["a": true, "b": true], ["a": true, "b": false], ["a": false, "b": true]]
        let tree = DecisionTree(learningFrom: examples, actions: [Move.eat, .rest, .rest], maxDepth: 1)
        func depth(_ node: DecisionNode<Move>) -> Int {
            switch node {
            case .action: 0
            case .question(_, let branches, let otherwise):
                1 + (branches.map { depth($0.node) } + [otherwise.map(depth) ?? 0]).max()!
            case .weighted(let choices): 1 + choices.map { depth($0.node) }.max()!
            }
        }
        #expect(depth(tree.root) == 1)
        let unlimited = DecisionTree(learningFrom: examples, actions: [Move.eat, .rest, .rest])
        #expect(depth(unlimited.root) == 2)
    }

    @Test func conflictingExamplesTakeTheMajority() {
        let tree = DecisionTree(learningFrom: [["x": 1], ["x": 1], ["x": 1]], actions: [Move.rest, .eat, .eat])
        #expect(tree.root == .action(.eat))
    }

    @Test func missingAnswersGoToOtherwise() {
        let tree = DecisionTree(learningFrom: [
            ["weather": "rain"], ["weather": "sun"], [:],
        ], actions: [Move.rest, .patrol, .chase])
        #expect(tree.decide(["weather": "rain"]) == .rest)
        #expect(tree.decide(["weather": "sun"]) == .patrol)
        #expect(tree.decide([:]) == .chase)
    }

    @Test func learningIsDeterministic() {
        let examples: [DecisionAnswers] = (0..<40).map { ["n": .number(Double($0 % 7)), "flag": .bool($0 % 3 == 0)] }
        let actions = (0..<40).map { $0 % 7 < 3 ? Move.eat : $0 % 3 == 0 ? .rest : .patrol }
        #expect(DecisionTree(learningFrom: examples, actions: actions) == DecisionTree(learningFrom: examples, actions: actions))
    }
}

@Suite struct RuleSystemTests {
    struct Critter { var food: Double; var playerDistance: Double }
    enum Mood: Hashable, Sendable { case hungry, scared, starving, calm }

    @Test func factsAddUpAndClamp() {
        var facts = Facts<Mood>()
        facts.assert(.hungry, grade: 0.4)
        facts.assert(.hungry, grade: 0.4)
        #expect(abs(facts[.hungry] - 0.8) < 1e-12)
        facts.assert(.hungry, grade: 0.5)
        #expect(facts[.hungry] == 1)
        facts.retract(.hungry, grade: 0.25)
        #expect(facts[.hungry] == 0.75)
        facts.retract(.hungry)
        #expect(facts[.hungry] == 0)
        #expect(facts.asserted.isEmpty)
    }

    @Test func fuzzyAndOr() {
        var facts = Facts<Mood>()
        facts.assert(.hungry, grade: 0.7)
        facts.assert(.scared, grade: 0.2)
        #expect(facts.all(.hungry, .scared) == 0.2)
        #expect(facts.any(.hungry, .scared) == 0.7)
        #expect(facts.all(.hungry, .calm) == 0)
        #expect(facts.strongest == .hungry)
    }

    @Test func strongestBreaksTiesByFirstAsserted() {
        var facts = Facts<Mood>()
        facts.assert(.scared, grade: 0.5)
        facts.assert(.hungry, grade: 0.5)
        #expect(facts.strongest == .scared)
        #expect(Facts<Mood>().strongest == nil)
    }

    @Test func rulesChainUntilNothingNewFires() {
        let system = RuleSystem<Critter, Mood>(
            Rule(when: { _, facts in facts[.hungry] > 0.8 }, assert: .starving),
            Rule(assert: .hungry, gradedBy: { critter, _ in 1 - critter.food }),
            Rule(assert: .scared, gradedBy: { critter, _ in 1 - critter.playerDistance / 100 })
        )
        let facts = system.evaluate(Critter(food: 0.1, playerDistance: 500))
        #expect(abs(facts[.hungry] - 0.9) < 1e-12)
        #expect(facts[.starving] == 1, "a later rule's fact lets an earlier rule fire")
        #expect(facts[.scared] == 0, "negative grades assert nothing")
        #expect(system.evaluate(Critter(food: 0.5, playerDistance: 50))[.starving] == 0)
    }

    @Test func eachRuleFiresOncePerEvaluation() {
        let system = RuleSystem<Critter, Mood>(
            Rule(when: { _, _ in true }, assert: .hungry, grade: 0.1)
        )
        #expect(abs(system.evaluate(Critter(food: 1, playerDistance: 1))[.hungry] - 0.1) < 1e-12)
    }

    @Test func higherSalienceRunsFirst() {
        // Without salience, "calm" would be asserted before "scared" exists.
        let system = RuleSystem<Critter, Mood>(
            Rule(when: { _, facts in facts[.scared] == 0 }, assert: .calm),
            Rule(salience: 10, when: { critter, _ in critter.playerDistance < 50 }, assert: .scared)
        )
        let near = system.evaluate(Critter(food: 1, playerDistance: 10))
        #expect(near[.scared] == 1)
        #expect(near[.calm] == 0)
        let far = system.evaluate(Critter(food: 1, playerDistance: 100))
        #expect(far[.calm] == 1)
    }

    @Test func retractRulesLowerGrades() {
        let system = RuleSystem<Critter, Mood>(
            Rule(salience: 1, assert: .hungry, gradedBy: { _, _ in 1 }),
            Rule(when: { critter, _ in critter.playerDistance < 50 }, retract: .hungry, grade: 0.6)
        )
        #expect(abs(system.evaluate(Critter(food: 0, playerDistance: 10))[.hungry] - 0.4) < 1e-12)
    }

    @Test func startsFromGivenFacts() {
        var start = Facts<Mood>()
        start.assert(.scared)
        let system = RuleSystem<Critter, Mood>(
            Rule(when: { _, facts in facts[.scared] > 0 }, retract: .scared)
        )
        #expect(system.evaluate(Critter(food: 1, playerDistance: 1), startingWith: start)[.scared] == 0)
    }

    @Test func factsEqualityIgnoresOrder() {
        var a = Facts<Mood>(), b = Facts<Mood>()
        a.assert(.hungry); a.assert(.scared)
        b.assert(.scared); b.assert(.hungry)
        #expect(a == b)
    }
}
