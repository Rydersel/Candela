import AppKit
import SwiftUI
import Testing

@Suite("Onboarding float lifecycle") @MainActor
struct OnboardingFloatLifecycleTests {
  // Reduce Motion is read-only in SwiftUI's environment. Exercise the same
  // float gate through `active`, without changing the machine's preferences.
  @Test(.enabled("The float transition requires Reduce Motion to be off") {
    await MainActor.run { !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }
  })
  func stoppingAndResumingFloatKeepsTheCompletedCheckmarkVisible() async throws {
    let update = RenderUpdate()
    let host = NSHostingView(rootView: Content(active: true, update: update))
    let window = NSWindow(
      contentRect: NSRect(x: -10000, y: -10000, width: 100, height: 100),
      styleMask: [.borderless], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.contentView = host
    defer {
      window.contentView = nil
      window.close()
    }

    // Never order the window on screen. The reference is the real completed
    // stroke; a new child whose drawing restarts has no white stroke yet.
    var completedWhitePixels: Int?
    for active in [true, false, true] {
      host.rootView = Content(active: active, update: update)
      for _ in 0..<100 {
        host.layoutSubtreeIfNeeded()
        if update.appliedActive == active { break }
        try await Task.sleep(for: .milliseconds(10))
      }
      try #require(update.appliedActive == active)
      if let completedWhitePixels {
        let pixels = try whitePixels(in: host)
        // Count coverage, not positions: floating shifts the stroke and its
        // antialiasing, but must not erase it or replay the draw-in.
        #expect(pixels >= completedWhitePixels * 4 / 5)
      } else {
        try await Task.sleep(for: .milliseconds(1100))
        let pixels = try whitePixels(in: host)
        try #require(pixels > 50, "The offscreen host must render a completed white stroke")
        completedWhitePixels = pixels
      }
    }
  }

  private func whitePixels(in host: NSView) throws -> Int {
    host.layoutSubtreeIfNeeded()
    let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
    host.cacheDisplay(in: host.bounds, to: bitmap)
    var count = 0
    for y in 0..<bitmap.pixelsHigh {
      for x in 0..<bitmap.pixelsWide {
        guard let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else { continue }
        if color.alphaComponent > 0.5, color.redComponent > 0.7,
          color.greenComponent > 0.7, color.blueComponent > 0.7
        {
          count += 1
        }
      }
    }
    return count
  }

  private final class RenderUpdate {
    var appliedActive: Bool?
  }

  private struct Content: View {
    let active: Bool
    let update: RenderUpdate

    var body: some View {
      AnimatedCheckmark(accent: Color(red: 0, green: 1, blue: 0), floatActive: active)
        .frame(width: 68, height: 68)
        .frame(width: 100, height: 100)
        .background(.black)
        .onChange(of: active, initial: true) { update.appliedActive = active }
    }
  }
}
