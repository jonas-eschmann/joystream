import UIKit

final class GamepadView: UIView {
    var onChange: ((GamepadState) -> Void)?
    var enabled = false { didSet { if !enabled { reset() } } }
    private(set) var state = GamepadState()
    private enum Input {
        case stick(String, CGPoint)
        case button(String)
    }
    private var touches: [UITouch: Input] = [:]
    private var buttons: [(key: String, frame: CGRect, color: UIColor)] = []
    private var origins: [String: CGPoint] = [:]
    private var radius: CGFloat { bounds.height * 0.16 }
    private var area: CGRect { bounds.inset(by: safeAreaInsets) }

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = UIColor(white: 0.065, alpha: 1)
        isMultipleTouchEnabled = true
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func reset() {
        touches.removeAll()
        origins.removeAll()
        state = GamepadState()
        setNeedsDisplay()
        onChange?(state)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        reset()
        let unit = area.height
        func frame(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat) -> CGRect {
            CGRect(x: area.minX + x * area.width - w * unit / 2,
                   y: area.minY + y * unit - h * unit / 2, width: w * unit, height: h * unit)
        }
        buttons = [
            ("l1", frame(0.14, 0.10, 0.26, 0.09), .darkGray),
            ("r1", frame(0.86, 0.10, 0.26, 0.09), .darkGray),
            ("select", frame(0.43, 0.10, 0.15, 0.08), .darkGray),
            ("start", frame(0.57, 0.10, 0.15, 0.08), .darkGray),
            ("y", frame(0.81, 0.28, 0.12, 0.12), .systemYellow),
            ("a", frame(0.81, 0.50, 0.12, 0.12), .systemGreen),
            ("x", frame(0.81 - unit * 0.11 / area.width, 0.39, 0.12, 0.12), .systemBlue),
            ("b", frame(0.81 + unit * 0.11 / area.width, 0.39, 0.12, 0.12), .systemRed)
        ]
    }

    override func draw(_ rect: CGRect) {
        for side in ["l", "r"] {
            let origin = origins[side] ?? CGPoint(x: area.minX + area.width * (side == "l" ? 0.22 : 0.78),
                                                 y: area.minY + area.height * 0.73)
            let color: UIColor = origins[side] == nil ? .darkGray : .systemCyan
            let base = UIBezierPath(ovalIn: CGRect(x: origin.x - radius, y: origin.y - radius,
                                                   width: radius * 2, height: radius * 2))
            UIColor(white: 0.11, alpha: 1).setFill()
            base.fill()
            color.setStroke()
            base.lineWidth = 2
            base.stroke()
            let knobRadius = radius * 0.44
            let center = CGPoint(x: origin.x + CGFloat(state.values[side + "x"]!) * radius,
                                 y: origin.y + CGFloat(state.values[side + "y"]!) * radius)
            color.setFill()
            UIBezierPath(ovalIn: CGRect(x: center.x - knobRadius, y: center.y - knobRadius,
                                       width: knobRadius * 2, height: knobRadius * 2)).fill()
        }
        for button in buttons {
            let pressed = state.values[button.key] == 1
            let path = UIBezierPath(roundedRect: button.frame, cornerRadius: button.frame.height / 2)
            (pressed ? button.color : UIColor(white: 0.11, alpha: 1)).setFill()
            path.fill()
            button.color.setStroke()
            path.lineWidth = 2
            path.stroke()
            let font = UIFont.systemFont(ofSize: area.height * (button.key.count > 1 ? 0.031 : 0.045),
                                         weight: .bold)
            let attributes: [NSAttributedString.Key: Any] = [
                .font: font, .foregroundColor: pressed ? UIColor.black : UIColor.lightGray
            ]
            let label = button.key.uppercased() as NSString
            let size = label.size(withAttributes: attributes)
            label.draw(at: CGPoint(x: button.frame.midX - size.width / 2,
                                   y: button.frame.midY - size.height / 2), withAttributes: attributes)
        }
    }

    override func touchesBegan(_ newTouches: Set<UITouch>, with event: UIEvent?) {
        guard enabled else { return }
        for touch in newTouches {
            let point = touch.location(in: self)
            if let button = buttons.first(where: { $0.frame.contains(point) }) {
                touches[touch] = .button(button.key)
                state.setButton(button.key, pressed: true)
            } else {
                let side = point.x < bounds.midX ? "l" : "r"
                guard origins[side] == nil else { continue }
                touches[touch] = .stick(side, point)
                origins[side] = point
                state.setStick(side, dx: 0, dy: 0, radius: Double(radius))
            }
        }
        changed()
    }

    override func touchesMoved(_ movedTouches: Set<UITouch>, with event: UIEvent?) {
        for touch in movedTouches {
            if case let .stick(side, origin) = touches[touch] {
                let point = touch.location(in: self)
                state.setStick(side, dx: Double(point.x - origin.x), dy: Double(point.y - origin.y),
                               radius: Double(radius))
            }
        }
        changed()
    }

    override func touchesEnded(_ endedTouches: Set<UITouch>, with event: UIEvent?) {
        for touch in endedTouches {
            switch touches.removeValue(forKey: touch) {
            case let .stick(side, _):
                origins[side] = nil
                state.setStick(side, dx: 0, dy: 0, radius: Double(radius))
            case let .button(key):
                // A second finger holding the same button still counts as pressed.
                let held = touches.values.contains { if case .button(key) = $0 { return true }; return false }
                state.setButton(key, pressed: held)
            case nil: break
            }
        }
        changed()
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        touchesEnded(touches, with: event)
    }

    private func changed() {
        setNeedsDisplay()
        onChange?(state)
    }
}
