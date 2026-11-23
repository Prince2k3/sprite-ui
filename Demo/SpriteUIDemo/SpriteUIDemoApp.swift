import SwiftUI

@main
struct SpriteUIDemoApp: App {
    var body: some Scene {
        WindowGroup {
            TabView {
                Group {
                    Tab("Animation", systemImage: "wand.and.stars") { DemoView() }
                    Tab("Debug", systemImage: "ladybug") { DebugDemoView() }
                    Tab("Players", systemImage: "person.2") { PlayerInputDemoView() }
                    Tab("Viewports", systemImage: "rectangle.split.2x1") { ViewportDemoView() }
                    Tab("Layers", systemImage: "square.3.layers.3d") { RenderLayersDemoView() }
                    Tab("Parallax", systemImage: "mountain.2") { ParallaxDemoView() }
                }
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
                Tab("Materials", systemImage: "paintpalette") { MaterialDemoView() }
                Tab("Lighting", systemImage: "lightbulb") { LightingDemoView() }
                Tab("Rendering", systemImage: "square.3.layers.3d") { RenderGroupDemoView() }
                Tab("Text & Shapes", systemImage: "textformat") { TextShapeDemoView() }
                Tab("Masking", systemImage: "circle.lefthalf.filled") { MaskDemoView() }
                Group {
                    Tab("Attachments", systemImage: "text.bubble") { AttachmentDemoView() }
                    Tab("Timelines", systemImage: "timeline.selection") { TimelineDemoView() }
                    Tab("Pooling", systemImage: "arrow.triangle.2.circlepath") { PoolingDemoView() }
                    Tab("Prefabs", systemImage: "square.on.square") { PrefabDemoView() }
                    Tab("Joints", systemImage: "link") { JointDemoView() }
                    Tab("Characters", systemImage: "figure.walk") { CharacterDemoView() }
                    Tab("Collision", systemImage: "scope") { CollisionDemoView() }
                    Group {
                        Tab("Resources", systemImage: "play.square.stack") { ResourcesDemoView() }
                        Tab("API", systemImage: "square.stack.3d.down.right") { APIConsolidationDemoView() }
                        Tab("Tiles", systemImage: "square.grid.3x3") { TileMapDemoView() }
                        Tab("Constraints", systemImage: "scope") { ConstraintDemoView() }
                        Tab("Manipulation", systemImage: "hand.draw") { ManipulationDemoView() }
                    }
                }
            }
        }
    }
}
