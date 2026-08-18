import CandelaKit
import CoreGraphics
import Foundation

/// Where one telemetry pass reads from, and whether it may read at all.
///
/// **Identity from the panel, geometry from the surface.** A panel carrying a
/// synthesized size is a mirror slave: the desktop lives on the virtual display
/// it mirrors, and that is where both the pixels and the window rectangles are.
/// Everything the telemetry path stores is still the PANEL's, keyed by its
/// `persistenceKey`. The virtual display has no EDID, so its own key is
/// derived from a display ID that changes every time the display is recreated,
/// and attributing to it would scatter one panel's history across a new key per
/// engage.
///
/// **Sampling is measurement, not intervention.** The interventions (idle dim,
/// blackout, masking) stay suspended under a synthesized size, and that is the
/// v1 ruling; the panel meanwhile is lit, showing the desktop and wearing, which
/// is why panel hours and the wear signal already carve synthesis out of the
/// OC13 pause. Exposure sampling and window observation carve out the same way:
/// what a capture would measure is exactly what the glass is emitting.
///
/// The carve-out is for a synthesis SLAVE only. A user mirror stays
/// disqualified: a redundant slave shows another display's picture, so sampling
/// it would book one desktop's wear onto two panels. The virtual master is
/// excluded by the same test: it resolves to itself, so it never reaches the
/// suspended branch, which is what keeps a capture from being counted twice if
/// a virtual display were ever enrolled.
///
/// Pure by construction: a topology value and a dim state in, a decision out.
/// The coordinator's own qualification adds the environment (lock, sleep,
/// battery, reset), none of which can be read without the machine.
struct OledTelemetryTarget: Equatable, Sendable {
  /// The panel every result is attributed to. Never the surface.
  let panel: CGDirectDisplayID
  /// The display whose framebuffer and coordinate space this pass reads:
  /// the panel itself, or the virtual display it is mirroring while a
  /// synthesized size is engaged.
  let surface: CGDirectDisplayID
  let synthesisEngaged: Bool

  init(panel: CGDirectDisplayID, topology: MirrorTopology) {
    let drawable = topology.drawableDisplayID(for: panel)
    // Both halves, deliberately. `isSynthesisSet` alone is true for the virtual
    // master as well, and `drawable != panel` alone is true for a user mirror.
    let engaged = drawable != panel && topology.isSynthesisSet(containing: panel)
    self.panel = panel
    // A user-mirrored panel never reads geometry off someone else's master:
    // it does not qualify below, and a surface it may not sample is not a
    // surface it may measure.
    surface = engaged ? drawable : panel
    synthesisEngaged = engaged
  }

  /// The state half of the sampling verdict, taken from the dimming engine's
  /// published state rather than re-derived from the signals behind it.
  ///
  /// Every dim state other than `.active` is a panel that is not showing what a
  /// capture would measure, because our own overlay is over it and OC16 excludes
  /// it from the capture. `.suspended` under a synthesized size is the one
  /// exception: no overlay is up, so the capture is faithful.
  func samplingMayRun(dimState: OledDimState) -> Bool {
    dimState == .active || (synthesisEngaged && dimState == .suspended)
  }
}
