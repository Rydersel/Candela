import CandelaKit
import CoreGraphics
import SwiftUI

/// The OLED Care pane's navigation path, owned by `SettingsRootView` and
/// injected because the registry builds the pane root with no arguments and the
/// display hub's jump link also pushes. The default is a no-op, so a view
/// rendered outside the injection renders but never navigates.
private struct OledCarePathKey: EnvironmentKey {
  static let defaultValue: Binding<[OledCarePage]> = .constant([])
}

extension EnvironmentValues {
  var oledCarePath: Binding<[OledCarePage]> {
    get { self[OledCarePathKey.self] }
    set { self[OledCarePathKey.self] = newValue }
  }
}

/// OLED Care's overview (OCR1): one card per external display, then the global
/// screen-chrome switches. Everything per-display lives on that display's pushed
/// page; this root answers "how are my displays doing" and holds only what is
/// global (OCR4).
///
/// Copy rule for every sentence in this file (OC11): software has exactly two
/// levers against burn-in, reduce luminance and reduce time at luminance.
/// Nothing here may claim more than that, and the chrome trade-off is stated
/// rather than sold.
///
/// `@MainActor` is load-bearing: a `View`'s stored and computed properties are
/// nonisolated under complete concurrency checking, and this one reads
/// `AppModel` and the coordinator from outside `body`.
@MainActor
struct OledCarePane: View {
  @Environment(AppModel.self) private var model

  /// The last chrome value asked for and not granted, per control.
  /// `ChromeAutoHideController` records what the SYSTEM reports, so a write that
  /// does not land is honest (the switch snaps back) but silent, and a switch
  /// flicking back with no explanation reads as a bug in the app rather than a
  /// refusal by the system. Cleared once the requested value is observed.
  @State private var menuBarRefused: Bool?
  @State private var dockRefused: Bool?

  var body: some View {
    // Prefs are plain `UserDefaults` and not observable, so this is the only
    // thing that re-reads them after a write, the pushed pages included.
    let _ = model.prefsRevision
    SettingsPageScaffold {
      // The two levers (OC11) at header weight, with the claim bounded in the
      // same breath: the only two ways software can. "Enrolled" is load-bearing,
      // because care runs on enrolled displays and on no others.
      SettingsPageHeader(
        title: "OLED Care",
        subtitle:
          "\(AppInfo.productName) protects an enrolled OLED display the only two ways software can: show fewer bright pixels, and show them for less time."
      )

      // The exceptional state leads when it exists; prose never does.
      if model.isSafeMode {
        safeModeNote
      }

      displaysSection
      chromeSection
    }
    // The Dock has no change notification, so an external
    // `com.apple.dock autohide` change is only visible on a re-read. Cancelled
    // with the pane, or it would be a permanent timer for a hidden window. The
    // same poll covers the menu bar, which needs no observer of its own.
    .task {
      while !Task.isCancelled {
        // Resolved inside the loop, never captured before it: the coordinator
        // builds `chrome` during launch wiring, so a `guard else { return }`
        // would give up permanently if this pane appeared first.
        if let chrome = model.oledCare.chrome {
          chrome.refresh()
          reconcileChromeRefusals(chrome)
        }
        try? await Task.sleep(for: .seconds(2))
        // `Task.sleep` returns immediately once cancelled, so the loop
        // re-checks rather than trusting the `while` to catch it in time.
        if Task.isCancelled { break }
      }
    }
  }

  // MARK: - Displays

  /// Several cards rather than one, so the kicker stands on the canvas above
  /// them instead of inside a card. One scaffold child at a tighter internal
  /// rhythm: the cards belong to their title and the sentence under them.
  private var displaysSection: some View {
    VStack(alignment: .leading, spacing: 8) {
      SettingsSectionTitle(text: "Displays")

      // Keyed by `persistenceKey`, NOT `DisplayState.id`: IDs reassign across a
      // replug with both displays still attached (measured: the MAG went 3 to 2
      // and the Dell 2 to 3 over one dock cycle), and a reused id hands the OLD
      // view instance to the OTHER display's card.
      ForEach(model.displays, id: \.display.persistenceKey) { state in
        OledCareDisplayCard(state: state)
      }
      if model.displays.isEmpty {
        // The one place "external displays" must be said outright: with no
        // cards on screen nothing else implies the scope. Carded, because a bare
        // sentence where the cards would be reads as a page that failed to load.
        SettingsCard {
          SettingsCaption("Connect an external display to enroll it in OLED care. OLED care applies to external displays only.")
        }
      }

      // Scoped to a measured display on purpose: a card whose display has too
      // few readings draws a blank frame, and this line must not promise a
      // picture that is not there.
      SettingsCaption("Wear accumulates where bright, unchanging content sits, and a card shows where its display has been lit once there are enough readings.")
        .text
        .font(.caption)
        .foregroundStyle(SettingsTheme.faintColor)
        .fixedSize(horizontal: false, vertical: true)
        .padding(.leading, 4)
    }
  }

  /// D11's rule: say exactly what Safe Mode suppresses, where it changes what a
  /// control means. `OledCareCoordinator.start` returns at its safe-mode guard
  /// BEFORE the driver loop is built, so the dimming loop, the hours counter, the
  /// sampler and the window observer are all inert. The chrome switches are
  /// explicit writes to system settings and still work, so this must not claim
  /// the pane is inert either: understating the scope misleads the same way
  /// overstating it does.
  private var safeModeNote: some View {
    SettingsCard {
      // Surfaceless: the card is the surface.
      SettingsNotice(drawsSurface: false) {
        // From `SafeModeCopy`, so this pane and Health cannot describe one
        // session two ways.
        Text(verbatim: SafeModeCopy.careSessionNotice)
          .font(.callout.weight(.medium))
          .fixedSize(horizontal: false, vertical: true)
        SettingsCaption("Shift was held at launch. The two Screen Chrome settings below still work, and the settings you make here are saved for the next normal launch.")
      }
      .padding(.vertical, 2)
    }
  }

  // MARK: - Screen chrome (global)

  /// Global, and on the root (OCR4): system-wide rather than per-display, and
  /// the strongest lever in the pane. Hiding the menu bar and the Dock stops
  /// driving those pixels rather than merely dimming them.
  @ViewBuilder private var chromeSection: some View {
    SettingsCardSection(title: "Screen Chrome") {
      if let chrome = model.oledCare.chrome {
        // The refusal note lives INSIDE the switch's own row: a note as its own
        // row gets a divider and full padding, which reads as a separate setting
        // rather than as this switch failing.
        SettingRow(caption: SettingsCaption("The menu bar and the Dock are the most static bright areas on a Mac screen, and hiding them stops those pixels being driven (at the cost of the clock, status items and menus taking a trip to the screen's edge).")) {
          VStack(alignment: .leading, spacing: 6) {
            Toggle("Automatically hide the menu bar", isOn: Binding(
              get: { chrome.menuBarAutoHide },
              set: { on in
                chrome.setMenuBarAutoHide(on)
                menuBarRefused = chrome.menuBarAutoHide == on ? nil : on
              }
            ))
            .themedSwitch()
            if menuBarRefused != nil {
              OledInlineNote(Text("macOS did not take that change. Menu bar auto-hiding can also be set in System Settings > Control Center."))
            }
          }
        }

        SettingsCardDivider()

        SettingRow(caption: SettingsCaption("Changing this restarts the Dock, which takes a moment and is visible.")) {
          VStack(alignment: .leading, spacing: 6) {
            Toggle("Automatically hide the Dock", isOn: Binding(
              get: { chrome.dockAutoHide },
              set: { on in
                chrome.setDockAutoHide(on)
                dockRefused = chrome.dockAutoHide == on ? nil : on
              }
            ))
            .themedSwitch()
            if dockRefused != nil {
              OledInlineNote(Text("macOS did not take that change. Dock auto-hiding can also be set in System Settings > Desktop & Dock."))
            }
          }
        }

        SettingsCardDivider()

        // NOT a row of its own: a sentence about BOTH switches in a row reads
        // as a third setting. It cannot ride either `SettingRow` either, since
        // that caption is republished as that ONE control's accessibility hint.
        // Caption weight, or the brighter sentence competes with the labels.
        SettingsCaption("Both settings belong to macOS: they apply to every display, and enrolling a display never changes them.")
          .text
          .font(.caption)
          .foregroundStyle(SettingsTheme.faintColor)
          .fixedSize(horizontal: false, vertical: true)
          .padding(.top, 8)
          .padding(.bottom, 2)
      } else {
        // The pairing sentence is suppressed with the controls: "both settings"
        // is noise under a section showing neither.
        SettingsCaption("These settings are not available yet. Reopen this window in a moment.")
          .padding(.vertical, 6)
      }
    }
  }

  /// Clears a recorded refusal once the system reports the value asked for: a
  /// change made in System Settings, or a Dock restart that finished after the
  /// setter read back. Without it the note outlives the condition it describes.
  private func reconcileChromeRefusals(_ chrome: ChromeAutoHideController) {
    if let requested = menuBarRefused, chrome.menuBarAutoHide == requested {
      menuBarRefused = nil
    }
    if let requested = dockRefused, chrome.dockAutoHide == requested {
      dockRefused = nil
    }
  }
}
