// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "JoystreamServer",
    platforms: [.macOS(.v15)],
    dependencies: [
        .package(url: "https://github.com/apple/swift-nio.git", exact: "2.102.0"),
    ],
    targets: [
        .executableTarget(
            name: "JoystreamServer",
            dependencies: [
                .product(name: "NIOCore", package: "swift-nio"),
                .product(name: "NIOPosix", package: "swift-nio"),
                .product(name: "NIOHTTP1", package: "swift-nio"),
                .product(name: "NIOWebSocket", package: "swift-nio"),
            ],
            path: ".",
            exclude: ["README.md", "THIRD_PARTY_NOTICES.md", "build.swift", "run.sh", "verify.swift"],
            sources: ["main.swift", "Server.swift", "HIDDevice.swift", "Reports.swift", "XboxDescriptor.swift"],
            linkerSettings: [.unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"])]
        ),
    ],
    swiftLanguageModes: [.v5]
)
