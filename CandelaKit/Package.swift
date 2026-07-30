// swift-tools-version: 6.0
import PackageDescription

let package = Package(
  name: "CandelaKit",
  platforms: [.macOS(.v14)],
  products: [
    .library(name: "CandelaKit", targets: ["CandelaKit"]),
  ],
  targets: [
    .target(name: "CandelaPrivateAPIs",
            linkerSettings: [.linkedFramework("CoreDisplay")]),
    .target(name: "CandelaKit", dependencies: ["CandelaPrivateAPIs"]),
    .testTarget(name: "CandelaKitTests", dependencies: ["CandelaKit"]),
  ]
)
