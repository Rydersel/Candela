import CandelaKit
import CoreGraphics
import SwiftUI

/// The display a jump into this pane came from, carried as a persistence key
/// and consumed ONCE: the hub's "All OLED Care Settings…" link sets it, this
/// pane scrolls to that display's section on appear and clears it there, so an
/// ordinary sidebar visit still opens at the top.
///
/// A `Binding` rather than a value so the consumer can do the clearing. The
/// value lives as `@State` on `SettingsRootView`, which is where the selection
/// it travels with lives; the default is `.constant(nil)`, whose setter is a
/// no-op, so any view rendered outside that injection simply never scrolls.
private struct OledCareScrollTargetKey: EnvironmentKey {
  static let defaultValue: Binding<String?> = .constant(nil)
}

extension EnvironmentValues {
  var oledCareScrollTarget: Binding<String?> {
    get { self[OledCareScrollTargetKey.self] }
    set { self[OledCareScrollTargetKey.self] = newValue }
  }
}

/// OLED care: the two global screen-chrome switches, then one section per
/// connected external display (spec §5).
///
/// Copy rule for every sentence in this file (OC11): software has exactly two
/// levers against burn-in — *reduce luminance* and *reduce time at luminance*.
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
  /// than what was requested, so a write that does not land is honest — the
  /// switch snaps back — but silent, and a switch that flicks back with no
  /// explanation reads as a bug in the app rather than as a refusal by the
  /// system. Cleared as soon as the value the user asked for is observed.
  @State private var menuBarRefused: Bool?
  @State private var dockRefused: Bool?

  /// Set by the hub's link, cleared by this pane the first time it appears.
  @Environment(\.oledCareScrollTarget) private var scrollTarget
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  var body: some View {
    ScrollViewReader { proxy in
      pane(proxy: proxy)
    }
  }

  /// The pane's own content. Split out of `body` only because the whole thing
  /// now hangs off a `ScrollViewReader`'s proxy; the sections still sit
  /// directly in this `Form`'s builder, which a grouped `Form` needs.
  private func pane(proxy: ScrollViewProxy) -> some View {
    // Prefs are plain `UserDefaults` and not observable, so this is the only
    // thing that re-reads them after a write from anywhere — including the
    // per-display sections below, which write through `DisplayPrefWriter`.
    let _ = model.prefsRevision
    return Form {
      // The pane's opening image, the display hero's precedent at pane scale:
      // each ENROLLED display's shape and history before any control. Clicking
      // a tile jumps to that display's section through the same anchor the hub
      // link uses. Enrolled only, so the strip is what this pane manages
      // rather than a row of placeholders.
      let enrolledDisplays = model.displays.filter {
        DisplayPrefs(persistenceKey: $0.display.persistenceKey).oledCareEnrolled
      }
      if !enrolledDisplays.isEmpty {
        Section {
          OledCareGlanceStrip(displays: enrolledDisplays) { key in
            withAnimation(Motion.scroll(reduceMotion: reduceMotion)) {
              proxy.scrollTo(key, anchor: .top)
            }
          }
        }
      }

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

      chromeSection

      if model.displays.isEmpty {
        Section {
          SettingsCaption("Connect an external display to enroll it in OLED care.")
        } header: {
          Text("Displays").settingsHeading()
        }
      }
    }
    .formStyle(.grouped)
    // One `.task` covers both appearance jobs and the poll, and it is cancelled
    // when this pane goes away — which is the whole requirement for the poll:
    // the Dock has no change notification, so the only way to reflect an
    // external `com.apple.dock autohide` change is to re-read, and a re-read
    // running while the pane is hidden would be a permanent timer for a window
    // nobody is looking at. (The same poll covers the menu bar, so it needs no
    // screen-parameters observer of its own.)
    .task {
      await scrollToTarget(proxy)
      while !Task.isCancelled {
        // Resolved inside the loop, never captured before it: the coordinator
        // builds `chrome` during launch wiring, and a `guard else { return }`
        // here would give up permanently if this pane happened to appear
        // first — leaving the switches frozen at whatever they read once.
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
        // Symbol AND text — never state by colour alone.
        Image(systemName: "exclamationmark.triangle")
          .foregroundStyle(.secondary)
        Text("Safe Mode is on for this session, so no display is being dimmed, no hours of use are being counted, and no measurements are being taken.")
      }
      SettingsCaption("Shift was held at launch. The two Screen Chrome settings below still work, and the settings you make here are saved for the next normal launch.")
    }
  }

  // MARK: - Screen chrome (global)

  /// Global, and first: these two are system-wide settings rather than
  /// per-display ones, and they are the strongest lever in the pane — hiding
  /// the menu bar and the Dock stops driving those pixels rather than merely
  /// dimming them.
  @ViewBuilder private var chromeSection: some View {
    Section {
      if let chrome = model.oledCare.chrome {
        // The refusal note lives INSIDE the switch's own row, like the
        // displaysleep warning below: a note in a `Form` row of its own gets a
        // divider and full padding, which reads as a separate setting rather
        // than as this switch failing.
        // One sentence (SO15): consequence plus its trade-off, and the
        // mechanism ("most static bright areas") stays because it IS the
        // consequence — hiding stops those pixels being driven (OC11).
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

  /// Consumes the jump's scroll target: land on the section for the display
  /// the user came from, once, then forget it so the next sidebar visit opens
  /// at the top.
  private func scrollToTarget(_ proxy: ScrollViewProxy) async {
    guard let key = scrollTarget.wrappedValue else { return }
    // A display named by a jump but absent from this pane (unplugged between
    // the click and the appear) consumes the target and leaves the page at the
    // top: no error, and nothing left over for the next visit to inherit.
    guard model.displays.contains(where: { $0.display.persistenceKey == key }) else {
      scrollTarget.wrappedValue = nil
      return
    }
    // The delay is load-bearing, not defensive [MEASURED 2026-08-07]: a
    // `scrollTo` issued on the first tick of this `.task` is accepted and does
    // nothing, and the pane stays at the top. The grouped `Form` has not
    // finished sizing its rows by then.
    try? await Task.sleep(for: .milliseconds(100))
    guard !Task.isCancelled else { return }
    // No animation: this is where the page opens, not a move the user made.
    proxy.scrollTo(key, anchor: .top)
    // Cleared only once a scroll has actually gone out, never before the
    // sleep. This task is cancelled and restarted during launch (measured), so
    // clearing up front spent the target on the run that never reached the
    // scroll and the surviving run found nothing to do.
    scrollTarget.wrappedValue = nil
  }

  /// Clears a recorded refusal once the system reports the value that was
  /// asked for — a change made in System Settings, or a Dock restart that
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

