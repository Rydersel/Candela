import AppKit
import CandelaKit
import CoreGraphics
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers

@Suite("Wallpaper luminance cache") @MainActor
struct WallpaperLuminanceSourceTests {
  private let transform = PanelSpaceTransform(
    displaySize: CGSize(width: 1920, height: 1080), rotation: .standard)

  private func temporaryURL() -> URL {
    FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".png")
  }

  private func writeWhiteImage(to url: URL) throws {
    let context = try #require(CGContext(
      data: nil, width: 16, height: 16, bitsPerComponent: 8, bytesPerRow: 0,
      space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
    context.setFillColor(CGColor(gray: 1, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: 16, height: 16))
    let image = try #require(context.makeImage())
    let destination = try #require(CGImageDestinationCreateWithURL(
      url as CFURL, UTType.png.identifier as CFString, 1, nil))
    CGImageDestinationAddImage(destination, image, nil)
    #expect(CGImageDestinationFinalize(destination))
  }

  @Test("Unreadable wallpaper stays memoized after its file becomes readable")
  func failureIsMemoized() throws {
    let url = temporaryURL()
    defer { try? FileManager.default.removeItem(at: url) }
    try Data("not an image".utf8).write(to: url)
    let source = WallpaperLuminanceSource(wallpaperURL: { _ in url })
    #expect(source.panelGrid(for: 1, appearanceIsDark: false, through: transform) == nil)
    try writeWhiteImage(to: url)
    for _ in 0..<3 {
      #expect(source.panelGrid(for: 1, appearanceIsDark: false, through: transform) == nil)
    }
  }

  @Test("Each wallpaper identity component permits retry", arguments: ["url", "appearance", "size", "rotation"])
  func changedIdentityRetries(component: String) throws {
    let first = temporaryURL()
    let second = temporaryURL()
    defer {
      try? FileManager.default.removeItem(at: first)
      try? FileManager.default.removeItem(at: second)
    }
    var url = first
    let source = WallpaperLuminanceSource(wallpaperURL: { _ in url })
    #expect(source.panelGrid(for: 1, appearanceIsDark: false, through: transform) == nil)
    try writeWhiteImage(to: first)
    try writeWhiteImage(to: second)
    if component == "url" { url = second }
    let changed = PanelSpaceTransform(
      displaySize: component == "size" ? CGSize(width: 1080, height: 1920) : transform.displaySize,
      rotation: component == "rotation" ? .ninety : .standard)
    let cells = try #require(source.panelGrid(
      for: 1, appearanceIsDark: component == "appearance", through: changed))
    #expect(cells.count == 240)
    #expect(cells.allSatisfy { abs($0 - 1) < 0.000001 })
    try Data("unreadable again".utf8).write(to: url)
    #expect(source.panelGrid(
      for: 1, appearanceIsDark: component == "appearance", through: changed) == cells)
  }

  @Test("Successful cache retains sampled luminance until explicitly invalidated")
  func successfulCacheAndInvalidation() throws {
    let url = temporaryURL()
    defer { try? FileManager.default.removeItem(at: url) }
    try writeWhiteImage(to: url)
    let source = WallpaperLuminanceSource(wallpaperURL: { _ in url })
    let cells = try #require(source.panelGrid(for: 1, appearanceIsDark: false, through: transform))
    #expect(cells.count == 240)
    #expect(cells.allSatisfy { abs($0 - 1) < 0.000001 })
    try Data("unreadable".utf8).write(to: url)
    #expect(source.panelGrid(for: 1, appearanceIsDark: false, through: transform) == cells)
    source.invalidate()
    #expect(source.panelGrid(for: 1, appearanceIsDark: false, through: transform) == nil)
    try writeWhiteImage(to: url)
    #expect(source.panelGrid(for: 1, appearanceIsDark: false, through: transform) == nil)
    source.invalidate()
    #expect(source.panelGrid(for: 1, appearanceIsDark: false, through: transform) == cells)
  }

  @Test("Window observation skips wallpaper while comparison consumes its luminance")
  func consumers() throws {
    _ = NSApplication.shared
    let url = temporaryURL()
    defer { try? FileManager.default.removeItem(at: url) }
    try writeWhiteImage(to: url)
    var requestedDisplays: [CGDirectDisplayID] = []
    let source = WallpaperLuminanceSource(wallpaperURL: {
      requestedDisplays.append($0)
      return url
    })
    let coordinator = OledCareCoordinator(wallpaper: source, windowList: { _ in [] })
    let key = UUID().uuidString
    // A controlled empty desktop makes the wallpaper the entire model input.
    let surface: CGDirectDisplayID = 0xFFFF_FFFE
    coordinator.observeWindows(for: key, on: surface, through: transform)
    #expect(requestedDisplays.isEmpty)
    #expect(coordinator.modelComparison(for: key).pairCount == 0)
    let target = OledTelemetryTarget(panel: surface, topology: MirrorTopology([]))
    coordinator.bookComparisonPair(
      for: key, on: target, measured: Array(repeating: 0.5, count: 240), through: transform)
    #expect(requestedDisplays == [surface])
    let comparison = coordinator.modelComparison(for: key)
    #expect(comparison.pairCount == 1)
    #expect(comparison.modelledCells.allSatisfy { abs($0 - 60) < 0.000001 })
    #expect(comparison.measuredCells.allSatisfy { abs($0 - 30) < 0.000001 })
  }
}
