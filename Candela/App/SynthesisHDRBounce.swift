import CandelaKit
import CoreGraphics

/// The per-display HDR seam the synthesis link bounce drives.
///
/// **Every leg goes through the display's own `BrightnessController`, never the
/// shared `MonitorPanelService`.** The controller owns the transition token,
/// the settle window and the wire-memo invalidation; a window it never heard
/// about leaves the brightness legs writing DDC into a register the display has
/// locked, where each value is ACKed, swallowed and memoed as landed. On a
/// write-only display nothing downstream can tell that from a write that
/// worked, and the slider sits dead until the person moves it away and back.
///
/// Closures rather than a protocol: a display id has to become a controller,
/// and only `AppModel` holds that table.
struct SynthesisHDRBounce: Sendable {
  /// Whether this display has HDR at all. False skips the bounce: there is
  /// nothing to renegotiate through.
  var supportsHDR: @Sendable (CGDirectDisplayID) async -> Bool
  /// The MEASURED state, read past the backend's own cache. nil when no
  /// controller will vouch for the answer, which the bounce treats as "do not
  /// touch this display's HDR".
  var measuredHDREnabled: @Sendable (CGDirectDisplayID) async -> Bool?
  /// One leg. Returns the MEASURED state after the settle, never the write's
  /// ACK, and **false is two facts**: the display measured the other way, or a
  /// newer transition superseded the call and established nothing. A caller may
  /// not read false as "HDR is off".
  ///
  /// The settle is the caller's to name: a full round trip pays this window up
  /// to six times inside one gate claim.
  var setHDR: @Sendable (CGDirectDisplayID, Bool, Duration) async -> Bool
  /// The off leg gave up with HDR standing, which kills DDC to the display.
  /// Surfaced rather than logged alone: the person is the only recovery path
  /// left, and they cannot act on a log line.
  var reportHDRLeftStanding: @Sendable (CGDirectDisplayID) async -> Void

  /// No HDR anywhere, so the bounce is a no-op. The right seam for anything
  /// that is not about the bounce.
  static let none = SynthesisHDRBounce(
    supportsHDR: { _ in false },
    measuredHDREnabled: { _ in false },
    setHDR: { _, _, _ in false },
    reportHDRLeftStanding: { _ in }
  )
}
