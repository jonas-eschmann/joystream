import XCTest
import Network
@testable import Joystream

final class GamepadTests: XCTestCase {
    func testAddresses() {
        let cases = [
            "192.168.1.10": "ws://192.168.1.10:8000/ws",
            " 100.64.0.5:9000 ": "ws://100.64.0.5:9000/ws",
            "http://linux.local:8000/": "ws://linux.local:8000/ws",
            "http://linux:8000/index.html": "ws://linux:8000/ws",
            "ws://linux:8080/ws": "ws://linux:8080/ws",
            "https://example.com": "wss://example.com:443/ws",
            "wss://example.com:8443/gamepad": "wss://example.com:8443/gamepad",
            "[::1]:8000": "ws://[::1]:8000/ws"
        ]
        for (input, expected) in cases {
            XCTAssertEqual(ServerAddress.url(from: input)?.absoluteString, expected, input)
        }
        for invalid in ["", " ", "foo bar", "ftp://linux", "http://", "linux:0", "linux:65536",
                        "linux:abc", "http://user:password@linux", "linux?query=1", "linux#fragment"] {
            XCTAssertNil(ServerAddress.url(from: invalid), invalid)
        }
    }

    func testProtocolAndStickClamping() throws {
        var state = GamepadState()
        XCTAssertEqual(state.values.count, 12)
        XCTAssertTrue(state.values.values.allSatisfy { $0 == 0 })
        state.setStick("l", dx: 30, dy: -40, radius: 50)
        state.setStick("r", dx: 100, dy: 100, radius: 50)
        state.setButton("a", pressed: true)
        let payload = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(state.message.utf8)) as? [String: Double])
        XCTAssertEqual(payload["lx"], 0.6)
        XCTAssertEqual(payload["ly"], -0.8)
        XCTAssertEqual(payload["rx"], 0.707)
        XCTAssertEqual(payload["ry"], 0.707)
        XCTAssertEqual(payload["a"], 1)
        state.setButton("a", pressed: false)
        state.setStick("l", dx: 0, dy: 0, radius: 50)
        XCTAssertEqual(state.values["a"], 0)
        XCTAssertEqual(state.values["lx"], 0)
        XCTAssertEqual(state.values["ly"], 0)
    }

    func testWebSocketHeartbeatReconnectAndStop() throws {
        // Real WebSocket listener: no Linux uinput device or external packages needed.
        let parameters = NWParameters.tcp
        let websocket = NWProtocolWebSocket.Options()
        websocket.autoReplyPing = true
        parameters.defaultProtocolStack.applicationProtocols.insert(websocket, at: 0)
        let listener = try NWListener(using: parameters, on: .any)
        let ready = expectation(description: "listener ready")
        listener.stateUpdateHandler = { if case .ready = $0 { ready.fulfill() } }
        var connections: [NWConnection] = []
        var messages: [[String: Double]] = []
        var received: (([String: Double]) -> Void)?
        func receive(_ connection: NWConnection) {
            connection.receiveMessage { data, _, _, error in
                if let data, let state = try? JSONSerialization.jsonObject(with: data) as? [String: Double] {
                    messages.append(state)
                    received?(state)
                }
                if error == nil { receive(connection) }
            }
        }
        listener.newConnectionHandler = { connection in
            connections.append(connection)
            connection.start(queue: .main)
            receive(connection)
        }
        listener.start(queue: .main)
        wait(for: [ready], timeout: 3)
        let port = try XCTUnwrap(listener.port)
        let client = GamepadClient()
        defer {
            received = nil
            client.stop()
            listener.cancel()
            connections.forEach { $0.cancel() }
        }
        let heartbeat = expectation(description: "neutral heartbeats")
        heartbeat.expectedFulfillmentCount = 3
        received = { state in
            XCTAssertEqual(Set(state.keys), Set(GamepadState().values.keys))
            XCTAssertTrue(state.values.allSatisfy { $0 == 0 })
            heartbeat.fulfill()
        }
        client.start(URL(string: "ws://127.0.0.1:\(port.rawValue)/ws")!)
        wait(for: [heartbeat], timeout: 3)
        received = nil

        let input = expectation(description: "button and axis state")
        var held = GamepadState()
        held.setButton("a", pressed: true)
        held.setStick("l", dx: 50, dy: -50, radius: 100)
        received = { state in
            if state["a"] == 1 && state["lx"] == 0.5 && state["ly"] == -0.5 {
                received = nil
                input.fulfill()
            }
        }
        client.update(held)
        wait(for: [input], timeout: 2)

        let reconnected = expectation(description: "reconnect resets held input")
        received = { state in
            if connections.count > 1 {
                XCTAssertTrue(state.values.allSatisfy { $0 == 0 })
                received = nil
                reconnected.fulfill()
            }
        }
        connections.first?.cancel()
        wait(for: [reconnected], timeout: 5)
        client.stop()
        XCTAssertFalse(client.connected)
        let connectionCount = connections.count
        let stopped = expectation(description: "no background reconnect")
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.3) { stopped.fulfill() }
        wait(for: [stopped], timeout: 2)
        XCTAssertEqual(connections.count, connectionCount)
    }
}
