// swift-tools-version: 5.9
import PackageDescription
let package = Package(
    name: "EarthPro",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "EarthPro", targets: ["EarthPro"])],
    targets: [
        .executableTarget(name: "EarthPro", resources: [.process("Resources")]),
        .testTarget(name: "EarthProTests", dependencies: ["EarthPro"])
    ]
)
