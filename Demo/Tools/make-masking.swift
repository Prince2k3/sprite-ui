// swift Demo/Tools/make-masking.swift Demo/SpriteUIDemo/Masking.sks
import Foundation
import SpriteKit

let scene = SKScene(size: CGSize(width: 360, height: 420))
scene.name = "masking-scene"; scene.anchorPoint = CGPoint(x: 0.5, y: 0.5)
let room = SKCropNode(); room.name = "masked-room"
let aperture = SKShapeNode(rectOf: CGSize(width: 300, height: 300), cornerRadius: 30)
aperture.fillColor = .white; aperture.strokeColor = .clear; aperture.lineWidth = 0; room.maskNode = aperture
scene.addChild(room)
let background = SKSpriteNode(color: SKColor(red: 0.025, green: 0.08, blue: 0.15, alpha: 1), size: CGSize(width: 320, height: 320))
background.zPosition = -20; room.addChild(background)
for i in -5...5 {
    let horizontal = SKSpriteNode(color: SKColor.cyan.withAlphaComponent(0.25), size: CGSize(width: 320, height: 1))
    horizontal.position.y = CGFloat(i) * 30; horizontal.zPosition = -19; room.addChild(horizontal)
    let vertical = SKSpriteNode(color: SKColor.cyan.withAlphaComponent(0.25), size: CGSize(width: 1, height: 320))
    vertical.position.x = CGFloat(i) * 30; vertical.zPosition = -19; room.addChild(vertical)
}
let panel = SKCropNode(); panel.name = "inner-mask"; panel.position = CGPoint(x: 70, y: 65); panel.zPosition = -10
let inner = SKShapeNode(circleOfRadius: 50); inner.fillColor = .white; inner.strokeColor = .clear; panel.maskNode = inner
for i in -4...4 {
    let stripe = SKSpriteNode(color: i.isMultiple(of: 2) ? .systemPink : .purple, size: CGSize(width: 160, height: 12))
    stripe.position.y = CGFloat(i) * 15; stripe.zRotation = .pi / 5; panel.addChild(stripe)
}
let caption = SKLabelNode(fontNamed: "HelveticaNeue-Bold"); caption.text = "NESTED"; caption.fontSize = 13
caption.verticalAlignmentMode = .center; caption.zPosition = 5; panel.addChild(caption); room.addChild(panel)
let url = URL(fileURLWithPath: CommandLine.arguments[1])
try NSKeyedArchiver.archivedData(withRootObject: scene, requiringSecureCoding: false).write(to: url)
