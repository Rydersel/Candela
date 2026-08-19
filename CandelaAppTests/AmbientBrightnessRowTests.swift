import CandelaKit
import CoreGraphics
import SwiftUI
import Testing

// Whether the ambient auto-brightness row appears, and what it shows when it
// does (AT4 layer 1). The rule is the whole feature at the view layer: the row
// exists only where macOS has a sensor to act on, and it publishes only a state
// macOS actually reported.
@Suite("Ambient brightness row") @MainActor
struct AmbientBrightnessRowTests {
  private static let builtIn: CGDirectDisplayID = 1
  private static let external: CGDirectDisplayID = 2

  private func rowState(
    displayID: CGDirectDisplayID?,
    hasSensor: Bool = true,
    isEnabled: Bool? = false
  ) -> AmbientRowState {
    AmbientBrightnessRow.rowState(
      displayID: displayID,
      hasSensor: { _ in hasSensor },
      isEnabled: { _ in isEnabled })
  }

  /// Clamshell, or any moment the built-in slot is empty. There is no display
  /// for the setting to be about, so there is no row.
  @Test func noDisplayShowsNoRow() {
    #expect(rowState(displayID: nil) == .hidden)
  }

  /// The negative half of the rig's split: an external display has no ambient
  /// light sensor, so the row is absent there rather than present and inert.
  @Test func aDisplayWithNoSensorShowsNoRow() {
    #expect(rowState(displayID: Self.external, hasSensor: false) == .hidden)
  }

  /// A sensor macOS will not report a state for. Showing the switch would mean
  /// picking a position to show it in, and both positions would be a guess.
  @Test func aStateMacOSWillNotReportShowsNoRow() {
    #expect(rowState(displayID: Self.builtIn, hasSensor: true, isEnabled: nil) == .hidden)
  }

  @Test func theRowShowsWhatMacOSReports() {
    #expect(rowState(displayID: Self.builtIn, isEnabled: true) == .shown(isOn: true))
    #expect(rowState(displayID: Self.builtIn, isEnabled: false) == .shown(isOn: false))
  }

  /// The degradation case the hardware list cannot reach by waiting for a
  /// macOS release: run the real seam with every symbol missing, which is what
  /// a dropped symbol and a failed dlopen both leave behind. The row is absent,
  /// not present and inert.
  @Test func missingSymbolsShowNoRow() {
    let degraded = AmbientLightCompensation(symbols: .none)
    let state = AmbientBrightnessRow.rowState(
      displayID: Self.builtIn,
      hasSensor: degraded.supports,
      isEnabled: degraded.isEnabled)
    #expect(state == .hidden)
  }

  /// The same seam wired to symbols that all resolve, so the degraded result
  /// above is a finding about the missing symbols and not about the seam
  /// answering `.hidden` to everything.
  @Test func resolvedSymbolsShowTheRow() {
    let working = AmbientLightCompensation(symbols: AmbientLightSymbols(
      hasSensor: { _ in true },
      read: { _ in true },
      write: { _, _ in }))
    let state = AmbientBrightnessRow.rowState(
      displayID: Self.builtIn,
      hasSensor: working.supports,
      isEnabled: working.isEnabled)
    #expect(state == .shown(isOn: true))
  }

  /// Layer 2, and only the hidden branch: `AppModel.builtIn` reads real
  /// discovery and cannot be scripted, so a fixture model has an empty slot on
  /// every machine and the shown branch has no deterministic render. What this
  /// covers is that `body` evaluates and the hidden branch draws nothing while
  /// its `Form` still comes out at a plausible size.
  @Test func theHiddenRowRendersNothingAndBreaksNothing() {
    let model = TestFixtures.appModel()
    let form = Form {
      Section("Brightness") {
        Text("A sibling, so the section is never empty.")
        AmbientBrightnessRow()
      }
    }
    .formStyle(.grouped)
    .frame(width: 400)
    .environment(model)

    let image = ImageRenderer(content: form).cgImage
    #expect(image != nil)
    #expect((image?.width ?? 0) > 20)
    #expect((image?.height ?? 0) > 20)
  }
}
