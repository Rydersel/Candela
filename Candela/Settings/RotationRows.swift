import CandelaKit
import CoreGraphics
import SwiftUI

/// Rotation for one display, a row in the hub's Display section.
///
/// **Nothing here is persisted.** An earlier experiment measured that a
/// rotation outlives the process that set it: it is WindowServer state, so
/// macOS is already the store. No `PrefName` case, no `PrefPropagation` row,
/// no reapply-on-reconnect.
/// Adding one risks fighting the system on every wake, the failure
/// `ModeReapplyPolicy` exists to prevent.
///
/// A pop-up rather than a segmented control, matching System Settings' own
/// rotation control and the Size row above it.
///
/// The hairline above and below belongs to the hosting card: only the hub knows
/// whether the size rows above rendered.
///
/// `@MainActor` because a `View`'s stored properties are nonisolated under
/// complete concurrency checking and this one stores main-actor types.
@MainActor
struct RotationRows: View {
  let state: AppModel.DisplayState
  let coordinator: RotationCoordinator

  /// Read for the mirror sample only. `MirroringCoordinator` is this app's ONE
  /// definition of "mirrored"; a second sample taken here would disagree with it
  /// exactly when it matters.
  @Environment(AppModel.self) private var model

  private var displayID: CGDirectDisplayID { state.id }

  /// A mirror slave's framebuffer belongs to the display it mirrors, so
  /// `RotationPolicy` refuses it. Greyed with the reason rather than left live
  /// and refusing: the click would only produce a report.
  private var isMirrorSlave: Bool {
    model.mirroring.topology.displays.contains { $0.id == displayID && $0.isMirrorSlave }
  }

  /// A display showing a size the app renders is mechanically a slave too, so it
  /// is refused as well. Kept apart from `isMirrorSlave` because the sentence
  /// differs: the user paired nothing here, and the way out is the size control.
  ///
  /// Off the same coordinator sample as `isMirrorSlave`, not the raw store the
  /// policy reads: that one is an observation dependency and it unions in a
  /// pairing the store has not been told about yet, so the caption can never
  /// lag the flag it explains.
  private var isSynthesizedSize: Bool {
    MirroringPredicates.isSynthesized(model.mirroring.topology, displayID: displayID)
  }

  var body: some View {
    // No control at all rather than a dead one. A picker that cannot
    // rotate only invites a click that produces a report.
    if coordinator.canRotate {
      ThemedChoiceRow(label: RotationCopy.label, selection: Binding(
        get: { coordinator.displayedRotation(of: displayID) ?? .standard },
        set: { coordinator.rotate(displayID, to: $0) }
      )) {
        ForEach(DisplayRotation.allCases, id: \.self) { rotation in
          Text(RotationCopy.angle(rotation)).tag(rotation)
        }
      }
      // A rotation takes up to a second; without this the window accepts a
      // second selection on top of the first.
      .disabled(coordinator.isApplying || isMirrorSlave || isSynthesizedSize)

      // One caption at a time, pairing state first: it is the reason the control
      // above is dead, and the angle it shows is beside the point while it is.
      // The synthesis arm ahead of the mirror arm, in the policy's order: such a
      // display sets the raw flag too, and the mirroring sentence would name a
      // display the user does not have.
      if isSynthesizedSize {
        SettingsCaption(RotationCopy.refusal(.synthesizedSize))
      } else if isMirrorSlave {
        SettingsCaption(RotationCopy.refusal(.mirrored))
      } else if coordinator.rotation(of: displayID) == nil {
        // The display reports a non-right angle, so the picker above is showing
        // a fallback rather than the truth. Say so.
        SettingsCaption(RotationCopy.refusal(.unreadable))
      }
    }
  }
}
