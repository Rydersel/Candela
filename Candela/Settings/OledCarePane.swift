import CandelaKit
import CoreGraphics
import SwiftUI

/// The OLED Care pane's navigation path, owned by `SettingsRootView` beside
/// the display destinations' paths and injected here because the pane's root
/// is built by the registry with no arguments, and because the display hub's
/// jump link also pushes. The default is a no-op constant, so any view
/// rendered outside the injection can render but never navigate.
private struct OledCarePathKey: EnvironmentKey {
  static let defaultValue: Binding<[OledCarePage]> = .constant([])
}

extension EnvironmentValues {
  var oledCarePath: Binding<[OledCarePage]> {
    get { self[OledCarePathKey.self] }
    set { self[OledCarePathKey.self] = newValue }
  }
}

/// OLED Care's overview (OCR1): one card per external display, then the two
/// global screen-chrome switches. Everything per-display lives on that
/// display's pushed page; this root answers "how are my displays doing" and
/// holds only what is global (OCR4).
///
/// Copy rule for every sentence in this file (OC11): software has exactly two
/// levers against burn-in, reduce luminance and reduce time at luminance.
/// Nothing here may claim more than that, and the chrome trade-off is stated
/// rather than sold.
///
/// `@MainActor` is load-bearing for the same reason as `DisplayDetailView`: a
/// `View`'s stored and computed properties are nonisolated under complete
/// concurrency checking, and this one reads `AppModel` and the coordinator from
/// outside `body`.
@MainActor
struct OledCarePane: View {
  @Environment(AppModel.self) private var model

  /// The last chrome value we asked for and did not get, per control. Held
  /// because `ChromeAutoHideController` records what the SYSTEM reports rather
  /// than what was requested, so a write that does not land is honest (the
  /// switch snaps back) but silent, and a switch that flicks back with no
  /// explanation reads as a bug in the app rather than as a refusal by the
  /// system. Cleared as soon as the value the user asked for is observed.
  @State private var menuBarRefused: Bool?
  @State private var dockRefused: Bool?

  var body: some View {
    // Prefs are plain `UserDefaults` and not observable, so this is the only
    // thing that re-reads them after a write from anywhere, including the
    // pushed pages, which write through `DisplayPrefWriter`.
    let _ = model.prefsRevision
    Form {
      Section {
        // One row, not two: a `SettingsCaption` placed as its own `Form` row
        // gets a divider above it, so two paragraphs of the same introduction
        // read as two settings.
        VStack(alignment: .leading, spacing: 6) {
          // Two sentences, not three (SO15/SO16): "enrolling applies the
          // recommended settings" already lives on every enrollment toggle's
          // own caption, where the control is.
          SettingsCaption("Software can do two things about OLED wear: show fewer bright pixels, and show them for less time. \(AppInfo.productName) dims an enrolled display that has been idle, and can turn on macOS's own auto-hiding for the menu bar and the Dock.")
          SettingsCaption("OLED care applies to external displays.")
        }
        if model.isSafeMode {
          safeModeNote
        }
      }

      // Identified by `persistenceKey`, NOT by `DisplayState.id` (which is
      // the `CGDirectDisplayID`). IDs reassign across a replug with both
      // displays still attached (measured: the MAG went 3 to 2 and the Dell
      // 2 to 3 across one dock cycle), and a `ForEach` keyed on a reused id
      // hands the OLD view instance to the OTHER display's card.
      Section {
        ForEach(model.displays, id: \.display.persistenceKey) { state in
          OledCareDisplayCard(state: state)
        }
        if model.displays.isEmpty {
          SettingsCaption("Connect an external display to enroll it in OLED care.")
        }
      } header: {
        Text("Displays").settingsHeading()
      }

      chromeSection
    }
    .formStyle(.grouped)
    // The poll is cancelled when this pane goes away, which is the whole
    // requirement: the Dock has no change notification, so the only way to
    // reflect an external `com.apple.dock autohide` change is to re-read, and
    // a re-read running while the pane is hidden would be a permanent timer
    // for a window nobody is looking at. (The same poll covers the menu bar,
    // so it needs no screen-parameters observer of its own.)
    .task {
      while !Task.isCancelled {
        // Resolved inside the loop, never captured before it: the coordinator
        // builds `chrome` during launch wiring, and a `guard else { return }`
        // here would give up permanently if this pane happened to appear
        // first, leaving the switches frozen at whatever they read once.
        if let chrome = model.oledCare.chrome {
          chrome.refresh()
          reconcileChromeRefusals(chrome)
        }
        try? await Task.sleep(for: .seconds(2))
        // `Task.sleep` returns immediately once cancelled, so the loop must
        // re-check rather than trusting the `while` to catch it in time.
        if Task.isCancelled { break }
      }
    }
  }

  /// D11's rule, applied here: say exactly what Safe Mode suppresses, where it
  /// changes what a control means. `OledCareCoordinator.start` returns at its
  /// safe-mode guard BEFORE the driver loop is built, so the dimming loop, the
  /// hours counter, the brightness sampler and the window observer are all
  /// inert; the two chrome switches are explicit writes to system settings and
  /// still work, so this must not claim the pane is inert either. D11 is a rule
  /// against overstating scope, and understating it misleads the same way: a
  /// note that named only dimming and hours left the two measurement toggles
  /// looking live in a session that measures nothing.
  private var safeModeNote: some View {
    VStack(alignment: .leading, spacing: 5) {
      HStack(alignment: .firstTextBaseline, spacing: 6) {
        // Symbol AND text; never state by colour alone.
        Image(systemName: "exclamationmark.triangle")
          .foregroundStyle(.secondary)
        Text("Safe Mode is on for this session, so no display is being dimmed, no hours of use are being counted, and no measurements are being taken.")
      }
      SettingsCaption("Shift was held at launch. The two Screen Chrome settings below still work, and the settings you make here are saved for the next normal launch.")
    }
  }

  // MARK: - Screen chrome (global)

  /// Global, and on the root (OCR4): these two are system-wide settings
  /// rather than per-display ones, and they are the strongest lever in the
  /// pane. Hiding the menu bar and the Dock stops driving those pixels rather
  /// than merely dimming them.
  @ViewBuilder private var chromeSection: some View {
    Section {
      if let chrome = model.oledCare.chrome {
        // The refusal note lives INSIDE the switch's own row: a note in a
        // `Form` row of its own gets a divider and full padding, which reads
        // as a separate setting rather than as this switch failing.
        // One sentence (SO15): consequence plus its trade-off, and the
        // mechanism ("most static bright areas") stays because it IS the
        // consequence: hiding stops those pixels being driven (OC11).
        SettingRow(caption: SettingsCaption("The menu bar and the Dock are the most static bright areas on a Mac screen, and hiding them stops those pixels being driven (at the cost of the clock, status items and menus taking a trip to the screen's edge).")) {
          VStack(alignment: .leading, spacing: 6) {
            Toggle("Automatically hide the menu bar", isOn: Binding(
              get: { chrome.menuBarAutoHide },
              set: { on in
                chrome.setMenuBarAutoHide(on)
                menuBarRefused = chrome.menuBarAutoHide == on ? nil : on
              }
            ))
            if menuBarRefused != nil {
              OledInlineNote(Text("macOS did not take that change. Menu bar auto-hiding can also be set in System Settings > Control Center."))
            }
          }
        }

        SettingRow(caption: SettingsCaption("Changing this restarts the Dock, which takes a moment and is visible.")) {
          VStack(alignment: .leading, spacing: 6) {
            Toggle("Automatically hide the Dock", isOn: Binding(
              get: { chrome.dockAutoHide },
              set: { on in
                chrome.setDockAutoHide(on)
                dockRefused = chrome.dockAutoHide == on ? nil : on
              }
            ))
            if dockRefused != nil {
              OledInlineNote(Text("macOS did not take that change. Dock auto-hiding can also be set in System Settings > Desktop & Dock."))
            }
          }
        }
      } else {
        SettingsCaption("These settings are not available yet. Reopen this window in a moment.")
      }
    } header: {
      Text("Screen Chrome").settingsHeading()
    } footer: {
      // The section's footer, NOT a `Form` row of its own, which is what this
      // was: a row gets a divider above it and full padding, so a sentence
      // about BOTH switches read as a third setting. It cannot ride either
      // switch's `SettingRow` either, because a `SettingRow` caption is
      // republished as that ONE control's accessibility hint, and this sentence
      // is about the pair.
      //
      // Suppressed while the controls are missing: a note about what "both
      // settings" are is noise under a section that is currently showing
      // neither.
      if model.oledCare.chrome != nil {
        SettingsCaption("Both settings belong to macOS rather than to \(AppInfo.productName): they apply to every display, and enrolling a display never changes them on its own.")
      }
    }
  }

  /// Clears a recorded refusal once the system reports the value that was
  /// asked for: a change made in System Settings, or a Dock restart that
  /// finished after the setter read back. Without this the note would outlive
  /// the condition it describes for as long as the pane stays open.
  private func reconcileChromeRefusals(_ chrome: ChromeAutoHideController) {
    if let requested = menuBarRefused, chrome.menuBarAutoHide == requested {
      menuBarRefused = nil
    }
    if let requested = dockRefused, chrome.dockAutoHide == requested {
      dockRefused = nil
    }
  }
}
