// Regenerate from the repository root:
// swift Demo/Tools/make-drawing.swift Demo/SpriteUIDemo/Drawing.sks
import Foundation
import SpriteKit

let scene = SKScene(size: CGSize(width: 360, height: 500))
scene.name = "drawing-lab"; scene.anchorPoint = CGPoint(x: 0.5, y: 0.5)
@discardableResult func label(_ name: String, _ text: String, at position: CGPoint, size: CGFloat, color: SKColor = .white, parent: SKNode? = nil) -> SKLabelNode {
    let node = SKLabelNode(fontNamed: "HelveticaNeue-Medium"); node.name = name; node.text = text
    node.fontSize = size; node.fontColor = color; node.verticalAlignmentMode = .center
    node.zPosition = 2
    node.position = position; (parent ?? scene).addChild(node); return node
}
label("title", "VECTOR LAB", at: CGPoint(x: 0, y: 205), size: 28, color: .cyan)
let paragraph = label("paragraph", "Labels and paths, loaded from a scene. Tap a marker or the title.", at: CGPoint(x: 0, y: 148), size: 15)
paragraph.numberOfLines = 0; paragraph.preferredMaxLayoutWidth = 300; paragraph.lineBreakMode = .byWordWrapping
let card = SKShapeNode(rectOf: CGSize(width: 300, height: 110), cornerRadius: 16)
card.name = "card"; card.position = CGPoint(x: 0, y: 40)
card.fillColor = SKColor(red: 0.03, green: 0.1, blue: 0.16, alpha: 1)
card.strokeColor = .cyan; card.lineWidth = 1.5; scene.addChild(card)
label("status", "VITALS 75%", at: CGPoint(x: 0, y: 15), size: 20, parent: card)
let track = SKShapeNode(rect: CGRect(x: -120, y: -30, width: 240, height: 8), cornerRadius: 4)
track.fillColor = .darkGray; track.strokeColor = .clear; track.zPosition = 0.5; card.addChild(track)
let health = SKShapeNode(rect: CGRect(x: -120, y: -30, width: 180, height: 8), cornerRadius: 4)
health.name = "health"; health.fillColor = .cyan; health.strokeColor = .clear; health.zPosition = 1; card.addChild(health)
let shapes = [SKShapeNode(circleOfRadius: 25), SKShapeNode(rectOf: CGSize(width: 50, height: 50), cornerRadius: 10), SKShapeNode(circleOfRadius: 25)]
for (i, shape) in shapes.enumerated() {
    shape.name = ["orb", "tile", "ring"][i]; shape.position = CGPoint(x: (i - 1) * 100, y: -90)
    shape.fillColor = i == 2 ? .clear : [.cyan, .orange][i]
    shape.strokeColor = i == 2 ? .systemPink : .clear; shape.lineWidth = 4; scene.addChild(shape)
    label("caption", ["FILL", "ROUND", "OUTLINE"][i], at: CGPoint(x: 0, y: -45), size: 11, color: .lightGray, parent: shape)
}
let curve = CGMutablePath(); curve.move(to: CGPoint(x: -135, y: -200))
curve.addCurve(to: CGPoint(x: 0, y: -200), control1: CGPoint(x: -90, y: -135), control2: CGPoint(x: -45, y: -265))
curve.addQuadCurve(to: CGPoint(x: 135, y: -200), control: CGPoint(x: 70, y: -130))
let wave = SKShapeNode(path: curve); wave.name = "curve"; wave.strokeColor = .orange; wave.lineWidth = 3; wave.lineCap = .round; scene.addChild(wave)
let url = URL(fileURLWithPath: CommandLine.arguments[1])
try NSKeyedArchiver.archivedData(withRootObject: scene, requiringSecureCoding: false).write(to: url)
