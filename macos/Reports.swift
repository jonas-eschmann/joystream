import Foundation

struct PadState {
    static let axisKeys = ["lx", "ly", "rx", "ry"]
    static let buttonKeys = ["a", "b", "x", "y", "l1", "r1", "select", "start"]
    var axes = [Double](repeating: 0, count: 4)
    var buttons = Set<String>()

    init() {}

    init(json: Data) throws {
        guard let object = try JSONSerialization.jsonObject(with: json) as? [String: Any] else {
            throw ServerError("State must be a JSON object.")
        }
        for (index, key) in Self.axisKeys.enumerated() {
            guard let value = (object[key] ?? 0) as? NSNumber, value.doubleValue.isFinite else {
                throw ServerError("Invalid axis: \(key)")
            }
            axes[index] = min(1, max(-1, value.doubleValue))
        }
        for key in Self.buttonKeys {
            guard let value = (object[key] ?? 0) as? NSNumber, [0.0, 1.0].contains(value.doubleValue) else {
                throw ServerError("Invalid button: \(key)")
            }
            if value.boolValue { buttons.insert(key) }
        }
    }

    // Xbox Series BLE report for Apple's GameController driver. Wire layout
    // follows WaveBird (MIT); see THIRD_PARTY_NOTICES.md and XboxDescriptor.swift.
    var hid: [UInt8] {
        var report = [UInt8](repeating: 0, count: 17)
        report[0] = 1
        for index in 0..<4 {
            // Our protocol is down-positive; Apple's Xbox driver is up-positive.
            let value = axes[index] * (index % 2 == 1 ? -1 : 1)
            put(UInt16(((value + 1) * 32767.5).rounded()), in: &report, at: 1 + index * 2)
        }
        // SDL's GIP reader also sees this BLE report. It interprets byte 1 as
        // flags; clearing FRAGMENT avoids treating an axis as a fragmented packet.
        report[1] &= 0x7f
        for (key, bit) in [("a", 0), ("b", 1), ("x", 3), ("y", 4), ("l1", 6), ("r1", 7)] {
            if buttons.contains(key) { report[14] |= 1 << bit }
        }
        if buttons.contains("select") { report[15] |= 0x04 }
        if buttons.contains("start") { report[15] |= 0x08 }
        // Triggers, D-pad, Guide, stick clicks, and Share remain neutral.
        return report
    }

    // GIP input for SDL's HIDAPI Xbox driver, on the same virtual device.
    var gip: [UInt8] {
        var report = [UInt8](repeating: 0, count: 19)
        report[0] = 0x20
        report[3] = 0x0f
        for (key, bit) in [("start", 2), ("select", 3), ("a", 4), ("b", 5), ("x", 6), ("y", 7)] {
            if buttons.contains(key) { report[4] |= 1 << bit }
        }
        if buttons.contains("l1") { report[5] |= 0x10 }
        if buttons.contains("r1") { report[5] |= 0x20 }
        for index in 0..<4 {
            let value = UInt16(bitPattern: Int16((axes[index] * 32767).rounded()))
            put(value, in: &report, at: 10 + index * 2)
        }
        return report
    }

    private func put(_ value: UInt16, in report: inout [UInt8], at offset: Int) {
        report[offset] = UInt8(value & 0xff)
        report[offset + 1] = UInt8(value >> 8)
    }
}

struct ServerError: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}
