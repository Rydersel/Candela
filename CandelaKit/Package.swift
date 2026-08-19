// swift-tools-version: 6.0
import PackageDescription

let package = Package(
  name: "CandelaKit",
  platforms: [.macOS(.v14)],
  products: [
    .library(name: "CandelaKit", targets: ["CandelaKit"]),
    .executable(name: "candela-probe", targets: ["CandelaProbe"]),
    .executable(name: "candela-model-capture", targets: ["CandelaModelCapture"]),
    .executable(name: "candela-model-fit", targets: ["CandelaModelFit"]),
    .executable(name: "candela-paint", targets: ["CandelaPaint"]),
  ],
  targets: [
    .target(name: "CandelaPrivateAPIs",
            linkerSettings: [.linkedFramework("CoreDisplay")]),
    .target(name: "CandelaKit", dependencies: ["CandelaPrivateAPIs"]),
    .executableTarget(name: "CandelaProbe", dependencies: ["CandelaKit"]),
    // Tool targets, not the engine: MP5 records that §4's import restriction
    // binds the CandelaKit library target, which is what stays UI-free.
    .executableTarget(name: "CandelaModelCapture", dependencies: ["CandelaKit"]),
    .executableTarget(name: "CandelaModelFit", dependencies: ["CandelaKit"]),
    .executableTarget(name: "CandelaPaint", dependencies: ["CandelaKit"]),
    .testTarget(name: "CandelaKitTests", dependencies: ["CandelaKit"]),
  ]
)
