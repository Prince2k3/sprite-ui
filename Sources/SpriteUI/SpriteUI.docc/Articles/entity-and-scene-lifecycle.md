# Entity and scene lifecycle

Choose owners for scene data, control activation, and keep copies and event handlers predictable.

## Build a hierarchy before attaching it

An ``SpriteUI/Entity`` is an identity, a component set, and an ordered collection of children. A ``SpriteUI/World`` has a hidden `root` entity; `world.entities` contains its top-level children, and `world.allEntities` includes descendants. `GameViewContent.scene` and `UpdateContext.scene` are conveniences for the same `World` exposed as `world`.

Build related entities while detached, then attach the complete root. Children inherit their parent's transform and activation. This helper adds a character with a locally offset label to any world:

```swift
import SpriteUI
import SwiftUI

@MainActor
func addLabeledPlayer(to world: World) -> Entity {
    let player = Entity(
        name: "player",
        components: SpriteComponent(color: .cyan, size: [32, 32])
    )
    let label = Entity(components: TextComponent("Player"))
    label.position = [0, 30]
    player.addChild(label)
    world.addEntity(player)
    return player
}
```

Removing a parent removes its subtree from the world. `removeFromParent()` detaches an entity; it does not destroy an object that your code still retains. Moving between parents with `addChild(_:)` preserves local component values, which can change the resulting scene pose. Use the throwing `setParent(_:preservingWorldTransform:)` operation when the scene pose must be retained. A transform that would require unsupported shear, a singular reference frame, or an invalid hierarchy can reject the operation without partially changing it.

Use `findEntity(named:)` for hierarchical lookup. Names are labels, not unique identities; use an entity ID or object reference when ambiguity matters.

## Distinguish enabled, inherited, and active state

| Property | Meaning |
| --- | --- |
| `isEnabled` | This entity's local switch |
| `isEnabledInHierarchy` | This entity and all ancestors are enabled |
| `isActive` | The entity belongs to a world and is enabled throughout its hierarchy |

Disabling a parent leaves descendant local flags intact. A child that was disabled before its parent was re-enabled remains disabled. Default ``SpriteUI/EntityQuery`` results include only active entities; set `includingDisabled: true` for inspection, reset, or editor work.

Disabled entities remain in the hierarchy with their IDs and components. The backend suspends their presentation activity and input; ordinary deactivation suspends playback rather than discarding the playback request. An ``SpriteUI/EntityPool`` release has stronger cleanup semantics, described in <doc:rendering-and-resources>.

This function counts dormant entities without accidentally including the hidden root:

```swift
import SpriteUI

@MainActor
func dormantEntityCount(in world: World) -> Int {
    let everything = EntityQuery(includingDisabled: true)
    return world.performQuery(everything).filter { !$0.isActive }.count
}
```

Activation changes publish ``SpriteUI/WorldEvents/DidChangeEntityActivation``. Attachment does not erase a local disabled flag. Restore and pool reuse can replace or reactivate objects, so a retained entity reference alone is insufficient proof that an old user interaction still applies.

## Store data at the scope that owns it

Put per-character data on that character. Put scene-wide component resources in `world.resources`, which is the component set on the world's hidden root. Systems can read resources without needing a special visible entity or a process-wide singleton.

```swift
import SpriteUI

struct MatchRules: Component {
    var movementMultiplier: Float
}

@MainActor
func configureMatch(_ world: World) {
    world.resources.set(MatchRules(movementMultiplier: 1.25))
    world.physics.gravity = [0, -9.8]
    world.timeScale = 1
}
```

Mutate components through `components.set(_:)` or the typed subscript so the world and backend receive changes. Reading a value component into a local variable and changing only that local copy does not update the entity; assign it back. World resources are useful runtime state, but the standard world snapshot captures top-level entities and their children, not the hidden root. Save persistent match-wide settings separately or put them on an explicit saved entity; see <doc:saving-and-debugging>.

`world.isPaused` pauses simulation, backend physics, and actions. Component edits can still render while paused, and app UI can still change. `timeScale = 0` freezes ordinary simulation without removing scene data. Time scale accepts finite, nonnegative values. Disabling an entity and pausing a world solve different ownership problems: activation selects participating content, while pause controls advancement of the scene clock.

## Retain subscriptions for their intended lifetime

``SpriteUI/EventSubscription`` is the lifetime token for an event handler. Store it on a scene owner or system. Dropping the token cancels delivery; keeping only the closure is insufficient. Explicit `cancel()` ends delivery while you still retain the token.

This scene observer owns its token and uses a weak capture so its closure does not retain the observer:

```swift
import SpriteUI

@MainActor
final class ActivationObserver {
    private var subscription: EventSubscription?
    private(set) var changeCount = 0

    init(world: World) {
        subscription = world.subscribe(
            to: WorldEvents.DidChangeEntityActivation.self
        ) { [weak self] _ in
            self?.changeCount += 1
        }
    }

    func stop() {
        subscription?.cancel()
        subscription = nil
    }
}
```

The app must also retain the `ActivationObserver` for as long as it needs these events. A subscription can filter to a particular entity with `on:`. Filtering uses the source entities supplied to `world.publish`, rather than scanning an event payload for an entity property. For your own events, publish with `from: entity` when entity-specific subscribers should receive them. A multi-source event reaches a subscriber on either source once.

Handlers run synchronously on the main actor. They can publish another event or change the hierarchy, so game logic that continues after publication should re-check assumptions. World additions report parents before children, while removals report children before parents. Subscribe to ``SpriteUI/ComponentEvents`` when component addition or removal is the relevant boundary; do not treat those events as a general SwiftUI observation mechanism.

## Clone data, then reconnect runtime behavior

`entity.clone()` creates a detached recursive copy with fresh IDs, preserved child order, names, local transforms, and local enabled flags. `clone(recursive: false)` copies only the entity. Add the copy to a world explicitly.

```swift
import SpriteUI

@MainActor
func spawnCopy(of prototype: Entity, in world: World) -> Entity {
    let instance = prototype.clone()
    instance.position = [120, 0]
    world.addEntity(instance)
    return instance
}
```

Every component controls its copy through `cloned()`. The default is a value copy; custom mutable reference storage needs a deep copy, or can return `nil` to omit runtime state. Immutable resources can stay shared. Entity subclasses are constructed through their required initializer; properties outside components keep initializer defaults.

Actions, event subscriptions, and active playback are not cloned. Reconnect those behaviors after spawning. A ``SpriteUI/PrefabResource`` captures a reusable hierarchy using the same copying rules; its instances also start detached with fresh IDs.

For components containing entity IDs, adopt ``SpriteUI/EntityReferencingComponent``. Cloning creates the destination hierarchy first and then remaps internal references, so one copied child can point at another copied child. References outside the copied subtree remain external. The same hook supports snapshot restoration; <doc:saving-and-debugging> shows a complete component example.

## Continue building

Use <doc:systems-and-input> to act on active entities each frame. Use <doc:rendering-and-resources> to reuse hierarchies in bounded pools, and <doc:saving-and-debugging> to separate persistent data from scene runtime state.
