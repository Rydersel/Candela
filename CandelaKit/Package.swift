// swift-tools-version: 6.0
import PackageDescription

let package = Package(
  name: "CandelaKit",
  platforms: [.macOS(.v14)],
  products: [
    .library(name: "CandelaKit", targets: ["CandelaKit"]),
  ],
  targets: [
    .target(name: "CandelaKit"),
    .testTarget(name: "CandelaKitTests", dependencies: ["CandelaKit"]),
  ]
)
