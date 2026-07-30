// swift-tools-version: 6.0
import PackageDescription

let package = Package(
  name: "CandelaKit",
  platforms: [.macOS(.v14)],
  products: [
    .library(name: "CandelaKit", targets: ["CandelaKit"]),
    .executable(name: "candela-probe", targets: ["CandelaProbe"]),
  ],
  targets: [
    .target(name: "CandelaPrivateAPIs",
            linkerSettings: [.linkedFramework("CoreDisplay")]),
    .target(name: "CandelaKit", dependencies: ["CandelaPrivateAPIs"]),
    .executableTarget(name: "CandelaProbe", dependencies: ["CandelaKit"]),
    .testTarget(name: "CandelaKitTests", dependencies: ["CandelaKit"]),
  ]
)
