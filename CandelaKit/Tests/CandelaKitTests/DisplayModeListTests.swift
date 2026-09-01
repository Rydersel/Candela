import Foundation
import Testing
@testable import CandelaKit

/// The pickers rendered rows a person cannot tell apart. Measured on the rig
/// 2026-08-17: the Dell published pairs whose CGS descriptors are byte-identical
/// apart from the mode number, and the built-in published none, its apparent pairs
/// being the NTSC rates (59.9 against 60.0) that must stay apart.
@Suite("Duplicate mode rows")
struct DisplayModeListTests {
  private func mode(
    _ id: Int32, _ lw: Int, _ lh: Int, px: Int? = nil, py: Int? = nil,
    hz: Double = 60, native: Bool = false, provenance: ModeProvenance = .coreGraphics
  ) -> DisplayMode {
    DisplayMode(
      ioModeID: id, logicalWidth: lw, logicalHeight: lh,
      pixelWidth: px ?? lw, pixelHeight: py ?? lh, refreshHz: hz,
      isNative: native, provenance: provenance)
  }

  @Test("two rows alike in every rendered field collapse to one")
  func identicalRowsCollapse() {
    // The Dell's 2160x3840 pair, ids 230 and 231.
    let list = [mode(230, 2160, 3840, hz: 120), mode(231, 2160, 3840, hz: 120)]
    let deduped = DisplayModeList.deduplicated(list)
    #expect(deduped.count == 1)
    #expect(deduped.first?.ioModeID == 230)
  }

  /// The trap this fix had to avoid: a refresh comparison coarse enough to merge
  /// 59.9 into 60 erases a real choice on the built-in, which offers both.
  @Test("NTSC and its round neighbour are different rows")
  func ntscRatesStayApart() {
    let list = [mode(127, 3024, 1964, hz: 60.0), mode(128, 3024, 1964, hz: 59.9)]
    #expect(DisplayModeList.deduplicated(list).count == 2)
  }

  @Test("a HiDPI row is not merged into the 1x row of the same logical size")
  func hiDPIStaysApart() {
    let list = [
      mode(178, 1440, 2560, px: 2880, py: 5120, hz: 120),
      mode(179, 1440, 2560, hz: 120),
    ]
    #expect(DisplayModeList.deduplicated(list).count == 2)
  }

  @Test("differing refresh, logical size or framebuffer all survive")
  func genuinelyDifferentRowsSurvive() {
    let list = [
      mode(1, 1920, 1080, hz: 60),
      mode(2, 1920, 1080, hz: 120),
      mode(3, 1600, 900, hz: 60),
      mode(4, 1920, 1080, px: 3840, py: 2160, hz: 60),
    ]
    #expect(DisplayModeList.deduplicated(list).count == 4)
  }

  /// Where only one member of a pair carries `kDisplayModeNativeFlag`, that one has
  /// to survive: the revelation pass and the scaled-size model read `isNative` to
  /// find the panel's own timing.
  @Test("the native row wins a collapse regardless of id order")
  func nativeRowWins() {
    let lowIDNotNative = [mode(10, 3440, 1440, hz: 175), mode(11, 3440, 1440, hz: 175, native: true)]
    let survivor = DisplayModeList.deduplicated(lowIDNotNative).first
    #expect(survivor?.ioModeID == 11)
    #expect(survivor?.isNative == true)
  }

  /// Revelation dedupes on ID and admits HiDPI only, so this collision cannot happen
  /// today. If it ever does, the published row wins: it applies through public API.
  @Test("a published row outranks a revealed row of the same geometry")
  func publishedOutranksRevealed() {
    let list = [
      mode(300, 1920, 1080, px: 3840, py: 2160, hz: 60, provenance: .coreGraphicsServices),
      mode(301, 1920, 1080, px: 3840, py: 2160, hz: 60, provenance: .coreGraphics),
    ]
    let survivor = DisplayModeList.deduplicated(list).first
    #expect(survivor?.ioModeID == 301)
    #expect(survivor?.provenance == .coreGraphics)
  }

  @Test("order is otherwise preserved, and a list with nothing to collapse is unchanged")
  func orderIsPreserved() {
    let list = [
      mode(5, 1600, 900, hz: 60),
      mode(1, 1920, 1080, hz: 60),
      mode(2, 1920, 1080, hz: 60),
      mode(9, 1280, 720, hz: 60),
    ]
    let deduped = DisplayModeList.deduplicated(list)
    #expect(deduped.map(\.ioModeID) == [5, 1, 9])
    let alreadyUnique = [mode(1, 1920, 1080), mode(2, 1600, 900)]
    #expect(DisplayModeList.deduplicated(alreadyUnique) == alreadyUnique)
  }

  @Test("three rows alike collapse to one, not to two")
  func triplesCollapseFully() {
    let list = [mode(7, 800, 600), mode(8, 800, 600), mode(9, 800, 600)]
    #expect(DisplayModeList.deduplicated(list).map(\.ioModeID) == [7])
  }

  @Test("an empty list is empty")
  func emptyIsEmpty() {
    #expect(DisplayModeList.deduplicated([]).isEmpty)
  }

  // MARK: - Resolving the live mode against a collapsed list

  @Test("the live mode resolves by id when its own row survived")
  func resolvesByID() {
    let list = [mode(179, 1440, 2560, hz: 120), mode(230, 2160, 3840, hz: 120)]
    #expect(DisplayModeList.resolve(mode(230, 2160, 3840, hz: 120), in: list)?.ioModeID == 230)
  }

  /// The regression this exists for: a display RUNNING the twin that was
  /// collapsed away. `CGDisplayCopyDisplayMode` still answers with the live id,
  /// so an id-only lookup returns nothing and the picker loses its current row.
  @Test("the live mode resolves to the survivor when its own id was collapsed")
  func resolvesToSurvivorAfterCollapse() {
    let full = [mode(178, 1440, 2560, px: 2880, py: 5120, hz: 120),
                mode(181, 1440, 2560, px: 2880, py: 5120, hz: 120)]
    let collapsed = DisplayModeList.deduplicated(full)
    #expect(collapsed.map(\.ioModeID) == [178])
    let live = mode(181, 1440, 2560, px: 2880, py: 5120, hz: 120)
    #expect(DisplayModeList.resolve(live, in: collapsed)?.ioModeID == 178)
  }

  @Test("a mode with no row at all resolves to nothing")
  func resolvesToNothingWhenAbsent() {
    let list = [mode(1, 1920, 1080, hz: 60)]
    #expect(DisplayModeList.resolve(mode(99, 800, 600, hz: 60), in: list) == nil)
  }

  /// The fallback must not reach across a real difference: a live 59.9 must not
  /// resolve to the 60.0 row just because no exact id matched.
  @Test("the fallback does not cross a genuine difference")
  func fallbackRespectsRealDifferences() {
    let list = [mode(127, 3024, 1964, hz: 60.0)]
    #expect(DisplayModeList.resolve(mode(128, 3024, 1964, hz: 59.9), in: list) == nil)
  }
}
