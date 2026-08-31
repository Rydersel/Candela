import CandelaKit
import CoreGraphics
import SwiftUI

/// Rotation for one display, a row in the hub's Display section.
///
/// **Nothing here is persisted (RT2).** RS7 measured that a rotation outlives
/// the process that set it: it is WindowServer state, so macOS is already the
/// store. No `PrefName` case, no `PrefPropagation` row, no reapply-on-reconnect.
/// Adding one risks fighting the system on every wake, the failure
/// `ModeReapplyPolicy` exists to prevent.
///
/// A pop-up rather than a segmented control, matching System Settings' own
/// rotation control and the Size row above it (RT14).
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

  private var displayID: CGDirectDisplayID { state.id }

  var body: some View {
    // RT5: no control at all rather than a dead one. A picker that cannot
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
      .disabled(coordinator.isApplying)

      // The display reports a non-right angle, so the picker above is showing
      // a fallback rather than the truth (RT7). Say so.
      if coordinator.rotation(of: displayID) == nil {
        SettingsCaption(RotationCopy.refusal(.unreadable))
      }
    }
  }
}
