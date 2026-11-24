import ECSCore
import Foundation
import Gameplay
import GameplayECS

/// An initial-state archive that cannot be restored by the default replay provider.
public enum InputReplayWorldStateError: Error, Equatable, Sendable {
    /// The scene has been released.
    case unavailableWorld
    /// The initial-state format is newer than this implementation.
    case unsupportedVersion(Int)
    /// A saved component type has not been registered in this process.
    case unregisteredComponent(String)
    /// The saved hierarchy or root pose is malformed.
    case invalidState
}

extension InputReplayController {
    /// Creates a replay controller using registered entity snapshots and the
    /// scene's complete random-generator state as its starting state.
    ///
    /// Register authoritative `Codable` entity components before recording or
    /// loading. Root pose is saved, but root resources, installed system state,
    /// subscriptions, and external services remain application-owned. Use the
    /// designated capture/restore initializer when those contain game state.
    /// The optional checksum must project stable custom simulation state; native
    /// physics, presentation, object identities, and frame clocks are unsuitable.
    /// Capture scene references weakly if the controller is held by that scene.
    public convenience init(world: World, input: InputController, maximumFrames: Int = 36_000,
                            checksum: (@MainActor () throws -> Data)? = nil) {
        self.init(world: world, input: input, maximumFrames: maximumFrames,
                  captureState: { [weak world] in
                      guard let world else { throw InputReplayWorldStateError.unavailableWorld }
                      let archive = ReplayWorldState(version: 1,
                          snapshot: try world.snapshot().jsonData(),
                          rootTransform: world.root.transform, random: world.random)
                      let encoder = JSONEncoder()
                      encoder.outputFormatting = [.sortedKeys]
                      return try encoder.encode(archive)
                  }, restoreState: { [weak world] data in
                      guard let world else { throw InputReplayWorldStateError.unavailableWorld }
                      // Validate the entire envelope and registration requirements
                      // before removing any existing entities. Ordinary snapshots
                      // deliberately skip unknown components; replays must not.
                      let decoder = JSONDecoder()
                      let archive = try decoder.decode(ReplayWorldState.self, from: data)
                      guard archive.version == 1 else {
                          throw InputReplayWorldStateError.unsupportedVersion(archive.version)
                      }
                      let index = try decoder.decode(ReplaySnapshotIndex.self, from: archive.snapshot)
                      var identifiers: Set<Entity.ID> = []
                      try index.validate(identifiers: &identifiers)
                      let pose = archive.rootTransform
                      guard pose.translation.x.isFinite, pose.translation.y.isFinite,
                            pose.rotation.isFinite, pose.scale.x.isFinite,
                            pose.scale.y.isFinite, pose.zPosition.isFinite else {
                          throw InputReplayWorldStateError.invalidState
                      }
                      let snapshot = try WorldSnapshot(data: archive.snapshot)
                      guard snapshot.version == 1 else { throw InputReplayWorldStateError.invalidState }
                      world.root.transform = pose
                      world.restore(snapshot)
                      // Attachment callbacks may draw random numbers while the
                      // tree is restored. The recording resumes the exact saved
                      // stream after attachment, rather than reseeding it.
                      world.random = archive.random
                  }, checksum: checksum)
    }
}

private struct ReplayWorldState: Codable {
    let version: Int
    let snapshot: Data
    let rootTransform: Transform
    let random: SeededGenerator
}

private struct ReplaySnapshotIndex: Decodable {
    let entities: [ReplayEntityIndex]

    func validate(identifiers: inout Set<Entity.ID>) throws {
        for entity in entities { try entity.validate(identifiers: &identifiers) }
    }
}

private struct ReplayEntityIndex: Decodable {
    let id: Entity.ID
    let components: [ReplayComponentIndex]
    let children: [ReplayEntityIndex]

    private enum CodingKeys: CodingKey { case id, components, children }

    init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(Entity.ID.self, forKey: .id)
        components = try values.decode([ReplayComponentIndex].self, forKey: .components)
        children = try values.decodeIfPresent([ReplayEntityIndex].self, forKey: .children) ?? []
    }

    func validate(identifiers: inout Set<Entity.ID>) throws {
        guard id > 0, identifiers.insert(id).inserted else { throw InputReplayWorldStateError.invalidState }
        var types: Set<String> = []
        for component in components {
            guard types.insert(component.type).inserted else { throw InputReplayWorldStateError.invalidState }
            guard ComponentRegistry.isRegistered(named: component.type) else {
                throw InputReplayWorldStateError.unregisteredComponent(component.type)
            }
        }
        for child in children { try child.validate(identifiers: &identifiers) }
    }
}

private struct ReplayComponentIndex: Decodable { let type: String }
