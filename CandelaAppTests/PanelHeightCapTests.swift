import AppKit
import Testing

@Suite("Panel height cap") @MainActor
struct PanelHeightCapTests {
  @Test func aShowingBarIsAlreadyOutOfTheVisibleFrame() {
    let cap = StatusItemController.panelMaximumHeight(
      visibleHeight: 1350, frameMaxY: 1440, visibleMaxY: 1416, barThickness: 24)
    #expect(cap == CGFloat(1334))
  }

  @Test func anAutoHiddenBarStillComesOffTheCap() {
    // Same screen and Dock as above, bar auto-hidden: the visible frame grows
    // by the bar, and the cap must not.
    let cap = StatusItemController.panelMaximumHeight(
      visibleHeight: 1374, frameMaxY: 1440, visibleMaxY: 1440, barThickness: 24)
    #expect(cap == CGFloat(1334))
  }

  @Test func aTallerMeasuredBarWinsOverTheThickness() {
    // A notched built-in reports a bar taller than the status bar thickness;
    // nothing extra comes off once the visible frame excludes it.
    let cap = StatusItemController.panelMaximumHeight(
      visibleHeight: 1000, frameMaxY: 1117, visibleMaxY: 1080, barThickness: 24)
    #expect(cap == CGFloat(984))
  }

  @Test func theCapNeverDropsBelowOnePoint() {
    let cap = StatusItemController.panelMaximumHeight(
      visibleHeight: 20, frameMaxY: 44, visibleMaxY: 44, barThickness: 24)
    #expect(cap == CGFloat(1))
  }

  @Test func theHUDAllowanceUsesTheSameRule() {
    #expect(NSScreen.menuBarAllowance(frameMaxY: 1440, visibleMaxY: 1416, barThickness: 24) == CGFloat(24))
    #expect(NSScreen.menuBarAllowance(frameMaxY: 1440, visibleMaxY: 1440, barThickness: 24) == CGFloat(24))
    #expect(NSScreen.menuBarAllowance(frameMaxY: 1117, visibleMaxY: 1080, barThickness: 24) == CGFloat(37))
  }
}
