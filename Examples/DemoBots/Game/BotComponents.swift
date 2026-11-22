import Foundation
import SpriteUI

public enum DemoBotsPhase: Equatable, Sendable {
    case home, playing, paused, won, lost
}

enum BotKind: String, Codable, Sendable { case player, ground, flying }
enum BotMode: String, EntityState, Codable { case active, patrol, hunt, flee, zapped, recharging }

struct BotComponent: Component {
    var kind: BotKind
    var isBad = false
    var corruption: Float = 100
    var heading: Float = 0
    var patrol: [SIMD2<Float>] = []
    var goodPatrol: [SIMD2<Float>] = []
    var badPatrol: [SIMD2<Float>] = []
    var waypoint = 0
    var decisionDelay: Float = 0
    var attackCooldown: Float = 0
    var hitFlash: Float = 0
    var route: [SIMD2<Float>] = []
    var previousPosition = SIMD2<Float>.zero
}

/// Beam charge and cooldown are independent of whether a target is available.
struct DebugBeam: Equatable {
    static let capacity: Float = 2
    var remaining: Float = capacity
    var cooling = false
    var active = false

    mutating func advance(pressed: Bool, deltaTime: Float) {
        active = pressed && !cooling && remaining > 0
        if active {
            remaining = max(0, remaining - deltaTime)
            if remaining == 0 { cooling = true; active = false }
        } else {
            remaining = min(Self.capacity, remaining + deltaTime * 2)
            if remaining >= Self.capacity { cooling = false }
        }
    }
}

struct PlayerCharge: Equatable {
    var value: Float = 100
    var invulnerability: Float = 0
    var rechargeTime: Float = 0
    var recharging: Bool { rechargeTime > 0 }

    @discardableResult mutating func hit(_ amount: Float) -> Bool {
        guard !recharging, invulnerability <= 0 else { return false }
        value = max(0, value - amount)
        invulnerability = 0.75
        if value == 0 { rechargeTime = 3 }
        return true
    }

    mutating func advance(_ dt: Float) {
        invulnerability = max(0, invulnerability - dt)
        if recharging {
            rechargeTime = max(0, rechargeTime - dt)
            value = min(100, value + dt * (100 / 3))
            if rechargeTime == 0 { value = 100; invulnerability = 1 }
        }
    }
}

struct BotPerception: Sendable {
    var bad: Bool
    var corruption: Float
    var threatDistance: Float
    var targetDistance: Float
}
enum BotIntent: Hashable, Sendable { case patrol, hunt, flee }

enum BotBrain {
    static let rules = RuleSystem<BotPerception, BotIntent>(
        Rule(assert: .patrol, gradedBy: { _, _ in 0.15 }),
        Rule(assert: .hunt, gradedBy: { state, _ in
            state.bad ? max(0, 1 - Double(state.targetDistance) / 650) : 0
        }),
        Rule(assert: .flee, gradedBy: { state, _ in
            if state.bad { return state.corruption < 40 ? 0.9 : 0 }
            return max(0, 1 - Double(state.threatDistance) / 330)
        })
    )
    static func intent(for state: BotPerception) -> BotIntent { rules.evaluate(state).strongest ?? .patrol }
}

struct BotLevelConfiguration: Decodable {
    struct TaskBot: Decodable {
        var locomotion: BotKind
        var initialOrientation: String
        var startsBad: Bool
        var goodPathNodeNames: [String]
        var badPathNodeNames: [String]
    }
    var timeLimit: Double
    var initialPlayerBotOrientation: String
    var taskBotConfigurations: [TaskBot]

    static func load(_ number: Int) throws -> Self {
        let url = try DemoBotsResources.url("Level\(number)", extension: "plist")
        return try PropertyListDecoder().decode(Self.self, from: Data(contentsOf: url))
    }
}

enum DemoBotsResources {
    static func url(_ name: String, extension ext: String) throws -> URL {
        guard let url = Bundle.module.url(forResource: name, withExtension: ext) else {
            throw CocoaError(.fileNoSuchFile, userInfo: [NSFilePathErrorKey: "\(name).\(ext)"])
        }
        return url
    }
    static let animations: [String: [String: [String]]] = {
        guard let url = try? url("animation-frames", extension: "json"),
              let data = try? Data(contentsOf: url),
              let frames = try? JSONDecoder().decode([String: [String: [String]]].self, from: data)
        else { return [:] }
        return frames
    }()

    static func animationKey(for bot: BotComponent, mode: BotMode, moving: Bool) -> (prefix: String, direction: String) {
        let prefix: String
        switch bot.kind {
        case .player:
            prefix = mode == .recharging ? "PlayerBotInactive" : (bot.hitFlash > 0 ? "PlayerBotHit" : (moving ? "PlayerBotWalk" : "PlayerBotIdle"))
        case .ground:
            prefix = mode == .zapped ? "GroundBotZapped" : (bot.isBad ? "GroundBotBadWalk" : "GroundBotGoodWalk")
        case .flying:
            prefix = mode == .zapped ? "FlyingBotZapped" : (bot.isBad ? "FlyingBotBadWalk" : "FlyingBotGoodWalk")
        }
        let direction = (Int((bot.heading / (2 * .pi) * 16).rounded()) % 16 + 16) % 16
        return (prefix, animations[prefix]?[String(direction)] != nil ? String(direction) : "0")
    }

    static func heading(_ compass: String) -> Float {
        let names = ["East", "NorthEast", "North", "NorthWest", "West", "SouthWest", "South", "SouthEast"]
        return Float(names.firstIndex(of: compass) ?? 0) * .pi / 4
    }
}

// Separate query categories keep scenery, actors and decorative sprites distinct.
enum BotCollisionGroups {
    static let walls = CollisionGroup(rawValue: 1 << 8)
    static let actors = CollisionGroup(rawValue: 1 << 9)
}
