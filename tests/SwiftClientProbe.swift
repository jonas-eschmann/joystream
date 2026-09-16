// Run the iPhone app's actual networking code against the standalone server.
import Foundation

@main
struct ClientProbe {
    static func main() {
        let client = GamepadClient()
        var started = false
        client.onStatus = { _, connected in
            guard connected, !started else { return }
            started = true
            var state = GamepadState()
            state.setButton("start", pressed: true)
            state.setStick("l", dx: 0, dy: -1, radius: 1)
            client.update(state)
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.1) {
                client.stop()
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { exit(0) }
            }
        }
        client.start(URL(string: CommandLine.arguments[1])!)
        DispatchQueue.main.asyncAfter(deadline: .now() + 6) { exit(1) }
        withExtendedLifetime(client) { RunLoop.main.run() }
    }
}
