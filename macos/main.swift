import Foundation
import Darwin

let usage = """
Usage: JoystreamServer [--host ADDRESS] [--port PORT] [--dry-run]
       JoystreamServer --check
       JoystreamServer --encode | --descriptor

Serves the browser client and /ws directly. Defaults: 0.0.0.0:8000.
  --check       Create a neutral gamepad, then remove it and exit.
  --dry-run     Run the real HTTP/WebSocket server and print HID reports;
                creates no gamepad and needs no entitlement or Accessibility.
  --encode      Encode JSON lines from stdin for diagnostics.
  --descriptor  Print the HID descriptor for diagnostics.
  --help        Show this help.
"""

struct Options {
    var host = "0.0.0.0"
    var port = 8000
    var mode = "server"
    var dryRun = false

    init(_ arguments: [String]) throws {
        var index = 0
        var networkOptions = false
        while index < arguments.count {
            let argument = arguments[index]
            switch argument {
            case "--host", "--port":
                index += 1
                guard index < arguments.count else { throw ServerError("Missing value for \(argument).") }
                if argument == "--host" {
                    guard !arguments[index].isEmpty else { throw ServerError("Host cannot be empty.") }
                    host = arguments[index]
                } else {
                    guard let value = Int(arguments[index]), (0...65535).contains(value) else {
                        throw ServerError("Port must be between 0 and 65535.")
                    }
                    port = value
                }
                networkOptions = true
            case "--check", "--encode", "--descriptor", "--help", "-h":
                guard mode == "server" else { throw ServerError("Choose only one diagnostic mode.") }
                mode = argument == "-h" ? "--help" : argument
            case "--dry-run": dryRun = true
            default: throw ServerError("Unknown argument: \(argument)")
            }
            index += 1
        }
        if mode != "server" && mode != "--help" && (networkOptions || dryRun) {
            throw ServerError("Network options and --dry-run are only used when serving.")
        }
    }
}

func serverURLs(host: String, port: Int) -> [String] {
    func url(_ address: String) -> String {
        "http://\(address.contains(":") ? "[\(address)]" : address):\(port)"
    }
    guard host == "0.0.0.0" || host == "::" else { return [url(host)] }
    var interfaces: UnsafeMutablePointer<ifaddrs>?
    guard getifaddrs(&interfaces) == 0 else { return [url("127.0.0.1")] }
    defer { freeifaddrs(interfaces) }
    var addresses = Set<String>()
    var current = interfaces
    while let interface = current {
        defer { current = interface.pointee.ifa_next }
        guard let address = interface.pointee.ifa_addr,
              address.pointee.sa_family == UInt8(AF_INET),
              interface.pointee.ifa_flags & UInt32(IFF_UP) != 0,
              interface.pointee.ifa_flags & UInt32(IFF_LOOPBACK) == 0 else { continue }
        var name = [CChar](repeating: 0, count: Int(NI_MAXHOST))
        if getnameinfo(address, socklen_t(address.pointee.sa_len), &name, socklen_t(name.count), nil, 0, NI_NUMERICHOST) == 0 {
            addresses.insert(String(cString: name))
        }
    }
    return (addresses.isEmpty ? [host == "::" ? "::1" : "127.0.0.1"] : addresses.sorted()).map(url)
}

signal(SIGPIPE, SIG_IGN)
var device: HIDDevice?
do {
    let options = try Options(Array(CommandLine.arguments.dropFirst()))
    switch options.mode {
    case "--help": print(usage)
    case "--descriptor":
        try output(String(decoding: JSONSerialization.data(withJSONObject: Array(xboxDescriptor)), as: UTF8.self))
    case "--encode":
        while let line = readLine() {
            let state = try PadState(json: Data(line.utf8))
            try output(String(decoding: JSONSerialization.data(withJSONObject: ["hid": state.hid, "gip": state.gip]), as: UTF8.self))
        }
    default:
        let pad = HIDDevice(dryRun: options.dryRun)
        device = pad
        try pad.start()
        if options.mode == "--check" {
            try output("Virtual gamepad created; removing it.")
            pad.shutdown(0)
            dispatchMain()
        }
        let server = try GamepadServer(device: pad)
        let port = try server.start(host: options.host, port: options.port)
        if options.dryRun { diagnostic("Dry run: network server active; no virtual gamepad is created.") }
        for url in serverURLs(host: options.host, port: port) { diagnostic("Open \(url) on your phone") }
        try output("JOYSTREAM_SERVER_READY \(port)")
        var signals: [DispatchSourceSignal] = []
        for number in [SIGINT, SIGTERM] {
            signal(number, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: number, queue: .global())
            source.setEventHandler { server.shutdown() }
            signals.append(source)
            source.resume()
        }
        withExtendedLifetime((server, signals)) { dispatchMain() }
    }
} catch {
    diagnostic(String(describing: error))
    if let device {
        device.shutdown(1)
        dispatchMain()
    }
    exit(1)
}
