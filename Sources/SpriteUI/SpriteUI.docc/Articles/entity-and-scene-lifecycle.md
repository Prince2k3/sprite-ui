# Keeping a scene together

A player's name should move with the player. When the player leaves the level, the name should leave too. A parent and child relationship lets the scene express both rules without updating two unrelated objects.

## Give related objects a parent

An ``SpriteUI/Entity`` holds components and can have children. A child's position is relative to its parent, so a label placed 30 points above a player keeps that offset as the player moves.

Build the pair first, then add the player to the ``SpriteUI/World``. Adding the parent brings its children into the world too.

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

The world has a hidden `root` entity. `world.entities` gives you its top-level children; `world.allEntities` includes their descendants. `GameViewContent.scene` and `UpdateContext.scene` refer to the same world available as `world`.

`removeFromParent()` detaches an entity and its children from the world. Your code may still hold those objects, so detaching is useful when moving content between scenes or saving it for later.

`addChild(_:)` keeps the child's local transform. Moving it to another parent can therefore change where it appears. When it should stay in the same place on screen, use `setParent(_:preservingWorldTransform:)` and handle a rejected conversion.

Names help you find scene content with `findEntity(named:)`. They need not be unique. Keep an object reference or ID when you need to identify one particular player.

## Hide a group without losing its state

Imagine temporarily disabling a squad while a menu is open. Set the squad parent's `isEnabled` to `false`. Its children keep their components and their own enabled flags, but stop participating while their ancestor is disabled.

These properties answer progressively wider questions:

| Property | Question |
| --- | --- |
| `isEnabled` | Is this entity's own switch on? |
| `isEnabledInHierarchy` | Are its switch and all ancestor switches on? |
| `isActive` | Is it also attached to a world? |

Ordinary ``SpriteUI/EntityQuery`` results include active entities. When inspecting or resetting disabled content, ask for it with `includingDisabled: true`. This helper counts inactive entities without including the hidden root.

```swift
import SpriteUI

@MainActor
func dormantEntityCount(in world: World) -> Int {
    let everything = EntityQuery(includingDisabled: true)
    return world.performQuery(everything).filter { !$0.isActive }.count
}
```

Re-enabling the parent restores children whose own switches are on. It leaves individually disabled children disabled. Ordinary deactivation suspends presentation, input, and playback advancement; releasing an instance to an ``SpriteUI/EntityPool`` performs additional cleanup.

## Keep match rules with the match

Health belongs on a character. A movement multiplier shared by the whole match belongs to the world. Store such data in `world.resources`, the component set on the hidden root, so systems can read it without a singleton or a visible placeholder entity.

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

Use `components.set(_:)` or the typed subscript to write component changes. If you read a value component into a local variable, changing that copy takes effect only after you assign it back.

To stop the scene's clock, use `world.isPaused`. It pauses simulation, backend physics, and actions while component edits can still render and SwiftUI controls remain usable. `timeScale` changes the pace of scene time; zero stops ordinary simulation. Disabling a group instead selects which entities participate.

## Keep an event handler alive

Suppose the UI counts activation changes. Subscribing returns an ``SpriteUI/EventSubscription``. Retain that token for as long as you want to receive events; dropping it cancels delivery.

This observer stores its token and uses a weak capture so the handler does not keep the observer alive.

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

The scene must retain the `ActivationObserver` too. Its `stop()` method ends observation before the scene releases it.

Use the subscription's `on:` argument to listen to one entity. For your own events, publish with `from: entity` so those subscribers can receive them. Filtering uses the supplied event sources, rather than searching the event's stored properties.

Handlers run synchronously on the main actor. A handler can change the hierarchy or publish another event. If your rule continues after publishing, check any scene relationships it still relies on.

## Spawn another copy

Once the player and label form a hierarchy, you can copy them together. `clone()` makes a detached copy with fresh IDs, preserving child order, names, local transforms, and enabled flags. Add it to the world when it is ready.

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

Components decide how they copy through `cloned()`. Value data uses the default copy. A component containing mutable reference storage should make an independent copy or return `nil` to leave that runtime state out. Immutable resources can remain shared.

The copy does not inherit active actions, playback, or event subscriptions. Start those behaviors for the new instance. A ``SpriteUI/PrefabResource`` packages a hierarchy for repeated spawning using the same rules.

If one copied child stores another child's ID, adopt ``SpriteUI/EntityReferencingComponent`` so the reference follows the copy. <doc:saving-and-debugging> shows that small component in full.

## Keep in mind

Preserving a scene transform can fail for a singular transform, unsupported shear, or an invalid hierarchy; the operation leaves the hierarchy unchanged on failure. A world time scale must be finite and nonnegative.

Standard snapshots omit `world.resources` because they omit the hidden root. Save persistent match settings separately or on a saved entity. Cloning an entity subclass copies its components; other properties keep their initializer defaults.

## Next lesson

Read <doc:systems-and-input> to make active entities respond to time and gestures. When repeated spawning becomes part of the game, <doc:rendering-and-resources> shows how to share resources and reuse instances.
