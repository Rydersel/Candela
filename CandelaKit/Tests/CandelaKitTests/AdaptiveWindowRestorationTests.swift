import CoreGraphics
import Foundation
import Testing
@testable import CandelaKit

@Suite("Adaptive window restoration")
struct AdaptiveWindowRestorationTests {
  private let start = Date(timeIntervalSince1970: 1_000)
  private func window(_ id: UInt32, _ x: Double = 0, layer: Int = 0) -> WindowSnapshot {
    WindowSnapshot(windowID: id, ownerPID: 7, ownerName: "Editor",
      bounds: CGRect(x: x, y: 0, width: 100, height: 100), layer: layer)
  }

  @Test func exactHitTestingRespectsEdgesOcclusionAndChrome() {
    var restore = AdaptiveWindowRestoration()
    let windows = [window(2, 50), window(1)]
    let edge = restore.update(pointer: CGPoint(x: 0.1, y: 0.1), windows: windows, at: start)
    #expect(edge[1] == 0)
    #expect(edge[2] == nil)
    restore = AdaptiveWindowRestoration()
    let overlap = restore.update(pointer: CGPoint(x: 75, y: 50), windows: windows, at: start)
    #expect(overlap[2] == 0)
    #expect(overlap[1] == nil)
    restore = AdaptiveWindowRestoration()
    #expect(restore.update(pointer: CGPoint(x: 75, y: 50),
      windows: [window(3, layer: 10)] + windows, at: start).isEmpty)
    #expect(restore.update(pointer: CGPoint(x: -1, y: 50), windows: windows, at: start).isEmpty)
  }

  @Test func parkedPointerStaysClearAndLeavingStartsGraceThenFade() {
    var restore = AdaptiveWindowRestoration()
    let windows = [window(1)]
    let point = CGPoint(x: 50, y: 50)
    #expect(restore.update(pointer: point, windows: windows, at: start)[1] == 0)
    #expect(!restore.isReturning)
    #expect(restore.update(pointer: point, windows: windows, at: start.addingTimeInterval(60))[1] == 0)
    #expect(restore.update(pointer: nil, windows: windows, at: start.addingTimeInterval(61))[1] == 0)
    #expect(restore.isReturning)
    #expect(restore.update(pointer: nil, windows: windows, at: start.addingTimeInterval(63))[1] == 0)
    #expect(restore.update(pointer: nil, windows: windows, at: start.addingTimeInterval(63.5))[1] == 0.5)
    #expect(restore.update(pointer: nil, windows: windows, at: start.addingTimeInterval(64))[1] == nil)
    #expect(!restore.isReturning)
  }

  @Test func crossingWindowsKeepsSeparateGraceAndReentryClearsImmediately() {
    var restore = AdaptiveWindowRestoration()
    let windows = [window(1), window(2, 100)]
    _ = restore.update(pointer: CGPoint(x: 50, y: 50), windows: windows, at: start)
    let crossed = restore.update(pointer: CGPoint(x: 150, y: 50), windows: windows,
      at: start.addingTimeInterval(1))
    #expect(crossed[1] == 0 && crossed[2] == 0)
    let returned = restore.update(pointer: CGPoint(x: 50, y: 50), windows: windows,
      at: start.addingTimeInterval(3.5))
    #expect(returned[1] == 0 && returned[2] == 0)
    let fading = restore.update(pointer: CGPoint(x: 50, y: 50), windows: windows,
      at: start.addingTimeInterval(6))
    #expect(fading[1] == 0 && fading[2] == 0.5)
  }

  @Test func closedWindowsAreForgottenAndClockReversalDoesNotJumpToDim() {
    var restore = AdaptiveWindowRestoration()
    _ = restore.update(pointer: CGPoint(x: 50, y: 50), windows: [window(1)], at: start)
    _ = restore.update(pointer: nil, windows: [window(1)], at: start.addingTimeInterval(1))
    #expect(restore.update(pointer: nil, windows: [window(1)], at: start.addingTimeInterval(-1))[1] == 0)
    #expect(restore.update(pointer: nil, windows: [], at: start).isEmpty)
    #expect(!restore.isReturning)
    #expect(restore.update(pointer: nil, windows: [window(1)], at: start).isEmpty)
  }
}
