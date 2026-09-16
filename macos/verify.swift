// Read-only GameController probe. Run while the signed Swift server is active.
import Foundation
import GameController

func observe(_ controller: GCController) {
    print("Controller:", controller.vendorName ?? "unknown", "category:", controller.productCategory)
    guard let gamepad = controller.extendedGamepad else {
        print("  No extended gamepad profile.")
        return
    }
    gamepad.valueChangedHandler = { pad, _ in
        let buttons = [("A", pad.buttonA), ("B", pad.buttonB), ("X", pad.buttonX), ("Y", pad.buttonY),
                       ("L1", pad.leftShoulder), ("R1", pad.rightShoulder), ("Start", pad.buttonMenu)]
        var held = buttons.filter { $0.1.isPressed }.map { $0.0 }
        if pad.buttonOptions?.isPressed == true { held.append("Select") }
        print(String(format: "L=(%.3f, %.3f) R=(%.3f, %.3f) buttons=%@",
                     pad.leftThumbstick.xAxis.value, pad.leftThumbstick.yAxis.value,
                     pad.rightThumbstick.xAxis.value, pad.rightThumbstick.yAxis.value,
                     held.joined(separator: ",")))
    }
}

let observer = NotificationCenter.default.addObserver(forName: .GCControllerDidConnect, object: nil, queue: .main) {
    if let controller = $0.object as? GCController { observe(controller) }
}
GCController.controllers().forEach(observe)
print("Listening for gamepad input for 15 seconds. Press buttons on the phone.")
RunLoop.main.run(until: Date().addingTimeInterval(15))
NotificationCenter.default.removeObserver(observer)
if GCController.controllers().isEmpty {
    print("No GameController found. Check the server's signing, profile and Accessibility access.")
    exit(1)
}
