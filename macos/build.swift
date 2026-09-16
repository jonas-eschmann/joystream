#!/usr/bin/env swift
import Foundation

let entitlement = "com.apple.developer.hid.virtual.device"
let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().standardizedFileURL
let files = FileManager.default

struct BuildError: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}

@discardableResult
func run(_ arguments: [String], capture: Bool = false) throws -> Data {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: arguments[0])
    process.arguments = Array(arguments.dropFirst())
    let pipe = capture ? Pipe() : nil
    if let pipe { process.standardOutput = pipe }
    try process.run()
    let data = pipe?.fileHandleForReading.readDataToEndOfFile() ?? Data()
    process.waitUntilExit()
    guard process.terminationStatus == 0 else { throw BuildError("\(arguments[0]) failed (exit \(process.terminationStatus)).") }
    return data
}

func plist(_ data: Data) throws -> [String: Any] {
    guard let object = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else {
        throw BuildError("Invalid property list.")
    }
    return object
}

func writePlist(_ object: [String: Any], to path: URL) throws {
    try PropertyListSerialization.data(fromPropertyList: object, format: .xml, options: 0).write(to: path)
}

func profileSettings(_ profile: [String: Any]) throws -> (String, [String: Any]) {
    guard let expiration = profile["ExpirationDate"] as? Date, expiration > Date() else {
        throw BuildError("The provisioning profile has expired.")
    }
    guard let allowed = profile["Entitlements"] as? [String: Any], allowed[entitlement] as? Bool == true else {
        throw BuildError("The profile does not grant the Apple Virtual HID entitlement.")
    }
    guard let appID = allowed["com.apple.application-identifier"] as? String,
          let prefix = (profile["ApplicationIdentifierPrefix"] as? [String])?.first,
          appID.hasPrefix(prefix + "."), !appID.contains("*"), appID.count > prefix.count + 1 else {
        throw BuildError("Use a macOS profile for an explicit JoystreamServer App ID.")
    }
    guard let team = allowed["com.apple.developer.team-identifier"] as? String, !team.isEmpty else {
        throw BuildError("The profile has no development team identifier.")
    }
    return (String(appID.dropFirst(prefix.count + 1)), [
        entitlement: true,
        "com.apple.application-identifier": appID,
        "com.apple.developer.team-identifier": team,
    ])
}

func path(_ value: String) -> URL {
    URL(fileURLWithPath: (value as NSString).expandingTildeInPath).standardizedFileURL.resolvingSymlinksInPath()
}

func build() throws {
    let arguments = Array(CommandLine.arguments.dropFirst())
    if arguments == ["--help"] || arguments == ["-h"] {
        print("Usage: ./macos/run.sh build (--profile FILE --identity NAME | --unsigned) [--output PATH.app]")
        return
    }
    var profile: URL?
    var identity: String?
    var destination: URL?
    var unsigned = false
    var index = 0
    while index < arguments.count {
        let argument = arguments[index]
        switch argument {
        case "--unsigned": unsigned = true
        case "--profile", "--identity", "--output":
            index += 1
            guard index < arguments.count, !arguments[index].isEmpty else { throw BuildError("Missing value for \(argument).") }
            if argument == "--profile" { profile = path(arguments[index]) }
            else if argument == "--identity" { identity = arguments[index] }
            else { destination = path(arguments[index]) }
        default: throw BuildError("Unknown argument: \(argument)")
        }
        index += 1
    }
    guard unsigned != (profile != nil) else { throw BuildError("Choose --unsigned or --profile FILE --identity NAME.") }
    guard unsigned ? identity == nil : identity != nil else { throw BuildError("--identity is required with --profile and cannot be used with --unsigned.") }
    var bundleID = "local.joystream.server.diagnostics"
    var entitlements: [String: Any]?
    if let profile {
        let decoded = try run(["/usr/bin/security", "cms", "-D", "-i", profile.path], capture: true)
        (bundleID, entitlements) = try profileSettings(plist(decoded))
    }
    let name = unsigned ? "JoystreamServer-Diagnostics.app" : "JoystreamServer.app"
    let output = destination ?? root.appendingPathComponent(".build/\(name)")
    guard output.pathExtension == "app" else { throw BuildError("--output must be an .app path.") }
    guard !unsigned || output.lastPathComponent != "JoystreamServer.app" else {
        throw BuildError("Use a separate diagnostics app so an unsigned build cannot replace the live server.")
    }
    if files.fileExists(atPath: output.path) {
        let info = try plist(Data(contentsOf: output.appendingPathComponent("Contents/Info.plist")))
        guard info["CFBundleIdentifier"] as? String == bundleID,
              info["CFBundleExecutable"] as? String == "JoystreamServer" else {
            throw BuildError("The output path already contains a different app. Choose another --output path.")
        }
    }

    try run(["/usr/bin/xcrun", "swift", "build", "--package-path", root.path, "-c", "release", "--force-resolved-versions"])
    let binaryDirectory = try run(["/usr/bin/xcrun", "swift", "build", "--package-path", root.path, "-c", "release", "--show-bin-path"], capture: true)
    let binary = URL(fileURLWithPath: String(decoding: binaryDirectory, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines))
        .appendingPathComponent("JoystreamServer")
    try files.createDirectory(at: output.deletingLastPathComponent(), withIntermediateDirectories: true)
    let temporary = output.deletingLastPathComponent().appendingPathComponent("joystream-build-\(UUID().uuidString)")
    try files.createDirectory(at: temporary, withIntermediateDirectories: true)
    defer { try? files.removeItem(at: temporary) }
    let app = temporary.appendingPathComponent(output.lastPathComponent)
    let contents = app.appendingPathComponent("Contents")
    let executable = contents.appendingPathComponent("MacOS/JoystreamServer")
    let resources = contents.appendingPathComponent("Resources")
    try files.createDirectory(at: executable.deletingLastPathComponent(), withIntermediateDirectories: true)
    try files.createDirectory(at: resources, withIntermediateDirectories: true)
    try files.copyItem(at: binary, to: executable)
    try files.copyItem(at: root.deletingLastPathComponent().appendingPathComponent("index.html"), to: resources.appendingPathComponent("index.html"))
    try files.copyItem(at: root.appendingPathComponent("THIRD_PARTY_NOTICES.md"), to: resources.appendingPathComponent("THIRD_PARTY_NOTICES.md"))
    for item in try files.contentsOfDirectory(at: binary.deletingLastPathComponent(), includingPropertiesForKeys: nil)
        where item.pathExtension == "bundle" {
        try files.copyItem(at: item, to: resources.appendingPathComponent(item.lastPathComponent))
    }
    // Ship the licenses for the statically linked Swift package dependencies.
    let licenses = resources.appendingPathComponent("Licenses")
    try files.createDirectory(at: licenses, withIntermediateDirectories: true)
    for dependency in ["swift-nio", "swift-atomics", "swift-collections", "swift-system"] {
        let checkout = root.appendingPathComponent(".build/checkouts/\(dependency)")
        for file in ["LICENSE.txt", "LICENSE", "NOTICE.txt", "NOTICE"] {
            let source = checkout.appendingPathComponent(file)
            if files.fileExists(atPath: source.path) {
                try files.copyItem(at: source, to: licenses.appendingPathComponent("\(dependency)-\(file)"))
            }
        }
    }
    let nio = root.appendingPathComponent(".build/checkouts/swift-nio")
    try files.copyItem(at: nio.appendingPathComponent("Sources/CNIOLLHTTP/LICENSE"), to: licenses.appendingPathComponent("llhttp-MIT.txt"))
    let sha = try String(contentsOf: nio.appendingPathComponent("Sources/CNIOSHA1/c_nio_sha1.c"), encoding: .utf8)
    if let end = sha.range(of: "#include") {
        try String(sha[..<end.lowerBound]).write(to: licenses.appendingPathComponent("sha1-BSD.txt"), atomically: true, encoding: .utf8)
    }
    try writePlist([
        "CFBundleIdentifier": bundleID, "CFBundleName": "JoystreamServer",
        "CFBundleDisplayName": "JoystreamServer", "CFBundleExecutable": "JoystreamServer",
        "CFBundlePackageType": "APPL", "CFBundleShortVersionString": "1.0", "CFBundleVersion": "1",
        "LSMinimumSystemVersion": "15.0", "LSUIElement": true,
        "NSLocalNetworkUsageDescription": "Joystream accepts gamepad input from your iPhone on the local network.",
    ], to: contents.appendingPathComponent("Info.plist"))
    var signing = ["/usr/bin/codesign", "--force", "--sign", identity ?? "-", "--options", "runtime"]
    // Swift 6.2's Span compatibility library is needed on older supported Macs.
    // Let the toolchain find, copy, and sign the required compatibility dylibs.
    let frameworks = contents.appendingPathComponent("Frameworks")
    try files.createDirectory(at: frameworks, withIntermediateDirectories: true)
    try run(["/usr/bin/xcrun", "swift-stdlib-tool", "--copy", "--scan-executable", executable.path,
             "--platform", "macosx", "--destination", frameworks.path, "--sign", identity ?? "-"])
    if let profile, let entitlements {
        try files.copyItem(at: profile, to: contents.appendingPathComponent("embedded.provisionprofile"))
        let file = temporary.appendingPathComponent("entitlements.plist")
        try writePlist(entitlements, to: file)
        signing += ["--entitlements", file.path]
    }
    try run(signing + [app.path])
    try run(["/usr/bin/codesign", "--verify", "--strict", app.path])
    // Compilation/signing errors leave the existing app untouched.
    if files.fileExists(atPath: output.path) { try files.removeItem(at: output) }
    try files.moveItem(at: app, to: output)
    print(output.path)
    if unsigned { print("Diagnostics only: ./macos/run.sh diagnostics") }
    else { print("Grant this app Accessibility access, then run its Contents/MacOS/JoystreamServer --check.") }
}

// Command-line entry point.
do { try build() }
catch {
    FileHandle.standardError.write(Data("JoystreamServer build failed: \(error)\n".utf8))
    exit(1)
}
