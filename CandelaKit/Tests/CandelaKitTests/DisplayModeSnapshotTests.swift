import CoreGraphics
import Foundation
import Testing
@testable import CandelaKit

/// Shaped like the real configurator: `nativePixels(for:)` looks into its own
/// mode list, so a snapshot answering from a sorted view would disagree with it.
private struct TwoNativeConfigurator: DisplayConfiguring {
  let list: [DisplayMode]

  func displays() -> [ConfiguredDisplay] { [] }
  func modes(for _: CGDirectDisplayID) -> [DisplayMode] { list }
  func currentMode(for _: CGDirectDisplayID) -> DisplayMode? { list.first }
  func nativePixels(for displayID: CGDirectDisplayID) -> (width: Int, height: Int)? {
    DisplayModeSnapshot.nativePixels(in: modes(for: displayID))
  }

  func apply(_: DisplayMode, to _: CGDirectDisplayID, scope _: DisplayConfigScope) throws {}
  func applyMirroring(_: [MirrorChange], scope _: DisplayConfigScope) throws {}
  var revealsHiddenModes: Bool { false }
  var guardsWireTiming: Bool { true }
  func modesWithheldByWireTimingGuard(for _: CGDirectDisplayID) -> Int { 0 }
  var canRotate: Bool { false }
  func rotation(of _: CGDirectDisplayID) -> DisplayRotation? { .standard }
  func applyRotation(_: DisplayRotation, to _: CGDirectDisplayID) throws {}
}

@Suite("Display mode snapshot")
struct DisplayModeSnapshotTests {
  /// The HiDPI half of a Retina pair, listed FIRST, with a smaller framebuffer
  /// than its 1x sibling so enumeration order and sorted order answer
  /// differently (on real hardware both share the panel's pixel count).
  private static let flaggedHiDPI = DisplayMode(
    ioModeID: 3, logicalWidth: 1512, logicalHeight: 982,
    pixelWidth: 3024, pixelHeight: 1964, refreshHz: 60, isNative: true
  )
  private static let flaggedOneToOne = DisplayMode(
    ioModeID: 1, logicalWidth: 3840, logicalHeight: 2160,
    pixelWidth: 3840, pixelHeight: 2160, refreshHz: 60, isNative: true
  )
  private static let scaled = DisplayMode(
    ioModeID: 2, logicalWidth: 1280, logicalHeight: 800,
    pixelWidth: 1280, pixelHeight: 800, refreshHz: 60, isNative: false
  )

  private static let raw = [flaggedHiDPI, flaggedOneToOne, scaled]

  @Test("Native pixels come from the first flagged mode in enumeration order")
  func nativePixelsFollowEnumerationOrder() throws {
    // The trap this pins: the catalog's sorted view puts the OTHER flagged mode
    // first, so anything reading native pixels off `full` answers differently.
    let sorted = DisplayModeCatalog.full(Self.raw)
    #expect(sorted.first(where: \.isNative)?.ioModeID == Self.flaggedOneToOne.ioModeID)

    let native = try #require(DisplayModeSnapshot.nativePixels(in: Self.raw))
    #expect(native.width == Self.flaggedHiDPI.pixelWidth)
    #expect(native.height == Self.flaggedHiDPI.pixelHeight)
  }

  /// The DEFAULT implementation only; `TwoNativeConfigurator` does not override
  /// `modeSnapshot`. The real configurator's single-pass override is covered by
  /// the tests over the expressions it shares with the four methods, and by the
  /// hardware pass.
  @Test("The protocol default answers by asking the four separate calls")
  func protocolDefaultAsksTheFourSeparateCalls() throws {
    let configurator = TwoNativeConfigurator(list: Self.raw)
    let displayID: CGDirectDisplayID = 4

    let snapshot = configurator.modeSnapshot(for: displayID)

    #expect(snapshot.modes == configurator.modes(for: displayID))
    #expect(snapshot.current == configurator.currentMode(for: displayID))
    #expect(
      snapshot.withheldByWireTimingGuard
        == configurator.modesWithheldByWireTimingGuard(for: displayID))
    let native = try #require(snapshot.nativePixels)
    let separate = try #require(configurator.nativePixels(for: displayID))
    #expect(native.width == separate.width)
    #expect(native.height == separate.height)
  }

  @Test("No native-flagged mode means no native pixels, not zeros")
  func noNativeFlagAnswersNil() {
    #expect(DisplayModeSnapshot.nativePixels(in: [Self.scaled]) == nil)
    #expect(DisplayModeSnapshot(
      modes: [Self.scaled], current: Self.scaled, nativePixels: nil,
      withheldByWireTimingGuard: 0
    ).nativePixels == nil)
  }
}
