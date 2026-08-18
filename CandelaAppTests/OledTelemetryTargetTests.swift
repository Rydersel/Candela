import CandelaKit
import CoreGraphics
import Foundation
import Testing

/// The telemetry carve-out for a synthesized size: which suspensions may still
/// be sampled, and which display the sample is read from.
///
/// The defect these pin is silent in both halves. A panel showing a synthesized
/// size sits at `.suspended`, which used to disqualify it from sampling
/// outright; and even qualified, a capture asked for the panel returns nil
/// forever, because ScreenCaptureKit does not list a mirrored display. Either
/// way the exposure map simply stops growing while the health view keeps
/// rendering the history it already had.
///
/// The fixture is the shape measured on the rig: one physical panel mirroring
/// onto the virtual display that carries the desktop, with the engine's pairing
/// naming the master. `userMirrored` is the same CoreGraphics shape with no
/// stamp, which is exactly what an ordinary mirror set looks like, and it is
/// the control for every carve-out below.
@Suite("Telemetry targeting under a synthesized size") @MainActor
struct OledTelemetryTargetTests {
  private static let panelID: CGDirectDisplayID = 3
  private static let virtualID: CGDirectDisplayID = 79
  private static let otherPanelID: CGDirectDisplayID = 2

  private func display(
    _ id: CGDirectDisplayID, name: String, mirrors: CGDirectDisplayID? = nil
  ) -> ConfiguredDisplay {
    ConfiguredDisplay(
      id: id,
      identity: DisplayConfigIdentity(
        vendor: 0x3669, model: UInt32(id), serial: UInt32(id), isBuiltIn: false
      ),
      name: name, isBuiltIn: false, mirrorsDisplay: mirrors ?? kCGNullDirectDisplay
    )
  }

  /// The panel mirrors onto the virtual display, and the pairing names the
  /// master: a synthesized size is engaged.
  private var engaged: MirrorTopology {
    MirrorTopology(
      [
        display(Self.panelID, name: "MAG341C", mirrors: Self.virtualID),
        display(Self.virtualID, name: "Candela Scaled Size"),
      ],
      synthesisMasters: [Self.virtualID]
    )
  }

  /// The same CoreGraphics state with no pairing stamp: mirroring the user
  /// asked for.
  private var userMirrored: MirrorTopology {
    MirrorTopology([
      display(Self.panelID, name: "MAG341C", mirrors: Self.otherPanelID),
      display(Self.otherPanelID, name: "U2725QE"),
    ])
  }

  private var unmirrored: MirrorTopology {
    MirrorTopology([display(Self.panelID, name: "MAG341C")])
  }

  // MARK: - Which suspension may be sampled

  @Test("a panel showing a synthesized size is sampled through its suspension")
  func synthesisSuspensionQualifies() {
    let target = OledTelemetryTarget(panel: Self.panelID, topology: engaged)
    #expect(target.synthesisEngaged)
    #expect(target.samplingMayRun(dimState: .suspended))
    #expect(target.samplingMayRun(dimState: .active))
  }

  /// The control. Without it every assertion above passes for the wrong reason,
  /// because "sample every suspension" also samples a synthesis set.
  @Test("a panel the user mirrored stays out of the sample")
  func userMirrorSuspensionDoesNotQualify() {
    let target = OledTelemetryTarget(panel: Self.panelID, topology: userMirrored)
    #expect(!target.synthesisEngaged)
    #expect(!target.samplingMayRun(dimState: .suspended))
  }

  /// Every other suspension is a panel with our own overlay over it, which OC16
  /// excludes from the capture, so what is measured is not what is emitted.
  @Test("the carve-out is for the suspension alone, not for the dim states")
  func dimStatesStayDisqualifiedEitherWay() {
    for topology in [engaged, userMirrored, unmirrored] {
      let target = OledTelemetryTarget(panel: Self.panelID, topology: topology)
      for state: OledDimState in [.idleDim, .blackout, .lockDim, .unfocusedDim] {
        #expect(!target.samplingMayRun(dimState: state))
      }
      #expect(target.samplingMayRun(dimState: .active))
    }
  }

  // MARK: - Which display is read

  @Test("the capture reads the drawable display while engaged")
  func surfaceIsTheDrawableDisplayWhileEngaged() {
    let target = OledTelemetryTarget(panel: Self.panelID, topology: engaged)
    #expect(target.surface == Self.virtualID)
    #expect(target.panel == Self.panelID)
  }

  @Test("the capture reads the panel itself when nothing is engaged")
  func surfaceIsThePanelOtherwise() {
    for topology in [unmirrored, userMirrored, MirrorTopology([])] {
      let target = OledTelemetryTarget(panel: Self.panelID, topology: topology)
      #expect(target.surface == Self.panelID)
      #expect(target.panel == Self.panelID)
    }
  }

  /// Attribution rides the panel, and only the panel: the virtual display's own
  /// identity is derived from a display ID that changes every time it is
  /// recreated, so a history keyed on it scatters across a new key per engage.
  @Test("attribution stays with the panel across an engage and a disengage")
  func attributionIsAlwaysThePanel() {
    #expect(OledTelemetryTarget(panel: Self.panelID, topology: engaged).panel == Self.panelID)
    #expect(OledTelemetryTarget(panel: Self.panelID, topology: unmirrored).panel == Self.panelID)
  }

  // MARK: - Not twice

  /// The double-counting guard. Both ends of the pair resolve to the SAME
  /// surface, so the only thing stopping one desktop being booked to two stores
  /// is that the virtual end never qualifies: it is in a mirror set, so its own
  /// state is `.suspended` too, and it resolves to itself rather than to a
  /// synthesis slave's surface.
  @Test("the virtual display end of the pair is never sampled")
  func theVirtualMasterNeverQualifies() {
    let master = OledTelemetryTarget(panel: Self.virtualID, topology: engaged)
    #expect(master.surface == Self.virtualID)
    #expect(!master.synthesisEngaged)
    #expect(!master.samplingMayRun(dimState: .suspended))
  }

  /// The other half of that guard, and the one an assertion can see from
  /// outside: a virtual display has no store because it is never enrolled. Its
  /// key is display-ID-derived and fresh on every recreation, so nothing has
  /// ever written an enrollment under it.
  @Test("a virtual display has no OLED care store to double-count into")
  func theVirtualDisplayIsNotEnrolled() {
    let key = "virtual-display-\(Self.virtualID)-\(UUID().uuidString)"
    #expect(!DisplayPrefs(persistenceKey: key).oledCareEnrolled)
    #expect(
      UserDefaults.standard.object(forKey: "oledExposureMap.\(key)") == nil)
  }

  /// A target that stops matching is how `finishExposureCapture` notices a
  /// disengage inside the capture's suspension. Equality is the whole check, so
  /// it has to separate the two states it is asked about.
  @Test("engaging and disengaging produce unequal targets")
  func targetsCompareUnequalAcrossADisengage() {
    #expect(
      OledTelemetryTarget(panel: Self.panelID, topology: engaged)
        != OledTelemetryTarget(panel: Self.panelID, topology: unmirrored))
    #expect(
      OledTelemetryTarget(panel: Self.panelID, topology: engaged)
        == OledTelemetryTarget(panel: Self.panelID, topology: engaged))
  }
}
