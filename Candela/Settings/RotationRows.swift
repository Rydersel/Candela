import CandelaKit
import CoreGraphics
import SwiftUI

/// Rotation for one display — a row in the hub's Display section (spec §4),
/// no section of its own since Task 13.
///
/// **Nothing here is persisted (RT2).** RS7 measured that a rotation outlives
/// the process that set it — it is WindowServer state, not a per-process
/// override — so macOS is already the store. There is deliberately no
/// `PrefName` case, no `PrefPropagation` row and no reapply-on-reconnect: adding
/// one risks *fighting* the system on every wake, which is the failure
/// `ModeReapplyPolicy` exists to prevent. If a reboot turns out not to preserve
/// it, that is a measurement, and then a design change.
///
/// A `Picker` rather than a segmented control, matching System Settings' own
/// presentation of rotation (RT14) — and matching the Size row above it. No
/// countdown-duration caption (spec §4): the countdown is runtime feedback the
/// confirmation window carries, not a description of the setting.
///
/// `@MainActor` because a `View`'s stored properties are nonisolated under
/// complete concurrency checking and this one stores main-actor types.
@MainActor
struct RotationRows: View {
  let state: AppModel.DisplayState
  let coordinator: RotationCoordinator

  private var displayID: CGDirectDisplayID { state.id }

  var body: some View {
    // RT5: no control at all rather than a dead one. A rotation picker that
    // cannot rotate is worse than its absence — it invites a click that will
    // only ever produce a report.
    if coordinator.canRotate {
      Picker(RotationCopy.label, selection: Binding(
        get: { coordinator.displayedRotation(of: displayID) ?? .standard },
        set: { coordinator.rotate(displayID, to: $0) }
      )) {
        ForEach(DisplayRotation.allCases, id: \.self) { rotation in
          Text(RotationCopy.angle(rotation)).tag(rotation)
        }
      }
      // A rotation takes up to a second and the window would otherwise
      // accept a second selection on top of the first.
      .disabled(coordinator.isApplying)

      // The display reports an angle that is not a right angle, so the picker
      // above is showing a fallback rather than the truth (RT7). Saying so is
      // the difference between a control that is wrong and one that is honest
      // about not knowing.
      if coordinator.rotation(of: displayID) == nil {
        SettingsCaption(RotationCopy.refusal(.unreadable))
      }
    }
  }
}
