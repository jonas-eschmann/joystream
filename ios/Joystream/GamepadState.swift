import Foundation

struct GamepadState {
    static let buttons = ["a", "b", "x", "y", "l1", "r1", "select", "start"]
    private(set) var values = Dictionary(uniqueKeysWithValues:
        (["lx", "ly", "rx", "ry"] + buttons).map { ($0, 0.0) })

    mutating func setButton(_ key: String, pressed: Bool) {
        guard Self.buttons.contains(key) else { return }
        values[key] = pressed ? 1 : 0
    }

    mutating func setStick(_ side: String, dx: Double, dy: Double, radius: Double) {
        guard ["l", "r"].contains(side), radius > 0 else { return }
        let scale = max(radius, hypot(dx, dy))
        values[side + "x"] = (dx / scale * 1000).rounded() / 1000
        values[side + "y"] = (dy / scale * 1000).rounded() / 1000
    }

    var message: String {
        // Only finite, normalized axes and 0/1 button values enter this dictionary.
        String(data: try! JSONSerialization.data(withJSONObject: values), encoding: .utf8)!
    }
}

enum ServerAddress {
    static func url(from input: String) -> URL? {
        let input = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !input.isEmpty, !input.contains(where: { $0.isWhitespace }),
              var parts = URLComponents(string: input.contains("://") ? input : "ws://" + input),
              let host = parts.host, !host.isEmpty,
              parts.user == nil, parts.password == nil,
              parts.query == nil, parts.fragment == nil else { return nil }
        switch parts.scheme?.lowercased() {
        case "http", "ws": parts.scheme = "ws"
        case "https", "wss": parts.scheme = "wss"
        default: return nil
        }
        if let port = parts.port, !(1...65535).contains(port) { return nil }
        if parts.port == nil { parts.port = parts.scheme == "wss" ? 443 : 8000 }
        if parts.path.isEmpty || parts.path == "/" || parts.path == "/index.html" {
            parts.path = "/ws"
        }
        return parts.url
    }
}
