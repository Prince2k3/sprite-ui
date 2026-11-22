import SwiftUI

@main
struct SpriteUIDemoApp: App {
    var body: some Scene {
        WindowGroup {
            TabView {
                Tab("Animation", systemImage: "wand.and.stars") { DemoView() }
                Group {
                    Tab("Random", systemImage: "dice") { RandomDemoView() }
                    Tab("States", systemImage: "arrow.triangle.branch") { StateMachineDemoView() }
                    Tab("Paths", systemImage: "point.topleft.down.to.point.bottomright.curvepath") { PathfindingDemoView() }
                    Tab("Spatial", systemImage: "circle.dotted.circle") { SpatialDemoView() }
                    Tab("Steering", systemImage: "bird") { SteeringDemoView() }
                    Tab("Noise", systemImage: "cloud") { NoiseDemoView() }
                    Tab("Decisions", systemImage: "questionmark.diamond") { DecisionDemoView() }
                    Tab("Strategists", systemImage: "circle.grid.3x3.fill") { StrategistDemoView() }
                    Tab("Obstacles", systemImage: "square.on.square.dashed") { ObstacleDemoView() }
                }
                Tab("Physics", systemImage: "circle.bottomhalf.filled") { PhysicsDemoView() }
                Tab("Scenes", systemImage: "square.stack.3d.up") { SceneDemoView() }
                Group {
                    Tab("Timelines", systemImage: "timeline.selection") { TimelineDemoView() }
                    Tab("Pooling", systemImage: "arrow.triangle.2.circlepath") { PoolingDemoView() }
                    Tab("Prefabs", systemImage: "square.on.square") { PrefabDemoView() }
                    Tab("Joints", systemImage: "link") { JointDemoView() }
                    Tab("Characters", systemImage: "figure.walk") { CharacterDemoView() }
                    Tab("Collision", systemImage: "scope") { CollisionDemoView() }
                    Tab("Resources", systemImage: "play.square.stack") { ResourcesDemoView() }
                    Tab("API", systemImage: "square.stack.3d.down.right") { APIConsolidationDemoView() }
                    Tab("Tiles", systemImage: "square.grid.3x3") { TileMapDemoView() }
                }
            }
        }
    }
}
