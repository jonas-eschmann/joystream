import ApplicationServices
import Foundation
import IOKit
import Security

func diagnostic(_ message: String) {
    FileHandle.standardError.write(Data(("joystream: " + message + "\n").utf8))
}
func output(_ message: String) throws {
    try FileHandle.standardOutput.write(contentsOf: Data((message + "\n").utf8))
}

func requireAuthorization() throws {
    var code: SecCode?
    var staticCode: SecStaticCode?
    var info: CFDictionary?
    guard SecCodeCopySelf([], &code) == errSecSuccess, let code,
          SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode,
          SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess,
          let entitlements = (info as? [String: Any])?[kSecCodeInfoEntitlementsDict as String] as? [String: Any],
          entitlements["com.apple.developer.hid.virtual.device"] as? Bool == true else {
        throw ServerError("Missing Apple Virtual HID entitlement. Build with an Apple-approved provisioning profile; see macos/README.md. An ad-hoc signature or sudo cannot grant it.")
    }
    guard AXIsProcessTrusted() else {
        throw ServerError("Allow JoystreamServer.app in System Settings > Privacy & Security > Accessibility, then restart joystream.")
    }
}

final class HIDDevice {
    private let queue = DispatchQueue(label: "joystream.hid")
    private let dryRun: Bool
    private var device: IOHIDUserDevice?
    private var watchdog: DispatchSourceTimer?
    private var state = PadState()
    private var lastInput = DispatchTime.now().uptimeNanoseconds
    private var holdingInput = false
    private var stopping = false
    private var exitStatus: Int32 = 0

    init(dryRun: Bool) { self.dryRun = dryRun }

    func start() throws {
        if !dryRun {
            try requireAuthorization()
            let properties: [String: Any] = [
                kIOHIDReportDescriptorKey: xboxDescriptor,
                kIOHIDVendorIDKey: 0x045e,
                kIOHIDProductIDKey: 0x0b13,
                kIOHIDVersionNumberKey: 0x050f,
                kIOHIDProductKey: "joystream",
                kIOHIDManufacturerKey: "joystream",
                kIOHIDTransportKey: kIOHIDTransportBluetoothLowEnergyValue,
                kIOHIDSerialNumberKey: "joystream-xbox-v1",
                kIOHIDPrimaryUsagePageKey: 1,
                kIOHIDPrimaryUsageKey: 5,
            ]
            // Create on activation, after get/set handlers are installed.
            guard let device = IOHIDUserDeviceCreateWithProperties(kCFAllocatorDefault, properties as CFDictionary, 1) else {
                throw ServerError("macOS refused the virtual device. Verify the server's Virtual HID profile and Accessibility permission.")
            }
            self.device = device
            IOHIDUserDeviceSetDispatchQueue(device, queue)
            IOHIDUserDeviceRegisterGetReportBlock(device) { [weak self] type, id, bytes, length in
                guard let self, type == kIOHIDReportTypeInput else { return kIOReturnUnsupported }
                let report: [UInt8]
                switch id {
                case 1: report = self.state.hid
                case 0x20: report = self.state.gip
                case 7: report = [7, 0x20, 0, 2, 0, 0x5b] // Guide remains released.
                default: return kIOReturnUnsupported
                }
                guard length.pointee >= report.count else { return kIOReturnNoSpace }
                report.withUnsafeBytes { source in
                    UnsafeMutableRawPointer(bytes).copyMemory(from: source.baseAddress!, byteCount: report.count)
                }
                length.pointee = report.count
                return kIOReturnSuccess
            }
            // No rumble hardware in the phone protocol. Acknowledge and ignore it.
            IOHIDUserDeviceRegisterSetReportBlock(device) { type, _, _, _ in
                type == kIOHIDReportTypeOutput ? kIOReturnSuccess : kIOReturnUnsupported
            }
            IOHIDUserDeviceSetCancelHandler(device) { [weak self] in
                guard let self else { return }
                self.device = nil
                exit(self.exitStatus)
            }
            IOHIDUserDeviceActivate(device)
        }
        try queue.sync { try send(PadState()) }
        let watchdog = DispatchSource.makeTimerSource(queue: queue)
        watchdog.schedule(deadline: .now() + .milliseconds(100), repeating: .milliseconds(100))
        watchdog.setEventHandler { [weak self] in
            guard let self, !self.stopping, self.holdingInput,
                  DispatchTime.now().uptimeNanoseconds - self.lastInput >= 500_000_000 else { return }
            do {
                try self.send(PadState())
                self.holdingInput = false
            } catch { self.fail(error) }
        }
        self.watchdog = watchdog
        watchdog.resume()
    }

    // Network handlers synchronously hand off to this queue, bounding pending
    // output. The watchdog runs independently of the network event loop.
    func apply(_ state: PadState) throws {
        try queue.sync {
            guard !stopping else { throw ServerError("Server is stopping.") }
            try send(state)
            lastInput = DispatchTime.now().uptimeNanoseconds
            holdingInput = true
        }
    }

    func reset() throws {
        try queue.sync {
            guard !stopping else { return }
            try send(PadState())
            holdingInput = false
        }
    }

    func shutdown(_ status: Int32) {
        queue.async { self.stop(status) }
    }

    private func send(_ state: PadState) throws {
        self.state = state
        if dryRun {
            let data = try JSONSerialization.data(withJSONObject: ["hid": state.hid, "gip": state.gip])
            try output(String(decoding: data, as: UTF8.self))
            return
        }
        guard let device else { throw ServerError("Virtual gamepad disappeared.") }
        for report in [state.hid, state.gip] {
            let result = report.withUnsafeBufferPointer { bytes in
                IOHIDUserDeviceHandleReportWithTimeStamp(device, mach_absolute_time(), bytes.baseAddress!, bytes.count)
            }
            guard result == kIOReturnSuccess else {
                throw ServerError(String(format: "HID report rejected (0x%08x).", result))
            }
        }
    }

    private func fail(_ error: Error) {
        diagnostic(String(describing: error))
        stop(1)
    }

    private func stop(_ status: Int32) {
        guard !stopping else { return }
        stopping = true
        exitStatus = status
        watchdog?.cancel()
        try? send(PadState())
        if let device { IOHIDUserDeviceCancel(device) }
        else { exit(status) }
    }
}
