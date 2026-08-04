import CandelaKit
import SwiftUI

/// One `Section("Diagnostics")` under a connected display: what this display
/// is, how its brightness is being driven, what it told us, what is
/// unavailable and why, and what is true right now.
///
/// The feature is the HONESTY RULES (DT30), not the rows:
/// - every "unavailable" row states a REASON drawn from a typed value;
/// - an unanswered display is reported as UNANSWERED, never as unsupported;
/// - a write-only panel is NAMED, with the consequence stated plainly;
/// - we never claim what macOS hides, only what our own curation did;
/// - "not measured yet" (nil) is never rendered as "no answer" (empty);
/// - internal key names never reach copy (D25).
///
/// It renders under the BUILT-IN display too (DT45), not only under externals —
/// and the rules above are what make that worth doing rather than merely
/// possible. "Why can't hardware control reach my laptop screen?" is a real
/// question this feature exists to answer, and it is answered here, once, in
/// the brightness group. Every row that describes a data cable, an EDID or a
/// DDC answer is OMITTED for the built-in rather than rendered against a fact
/// that will never arrive: `DisplayDiscovery` is external-only by construction,
/// so a "Connection: not enumerated yet" on the built-in would be a permanent
/// promise of an answer, which is exactly the shape DT30 rule (e) forbids.
///
/// `@MainActor` is load-bearing: a `View`'s stored and computed properties
/// other than `body` are nonisolated under complete concurrency, and this one
/// constructs and reads main-actor types.
///
/// It WRITES NOTHING (DT31) — no `PrefName` case, no `DisplayPrefWriter`, no
/// button. D29 does not bind it today and binds the moment a control is added:
/// a "re-probe now" control would fall under D29 rule 3 immediately.
@MainActor
struct DisplayDiagnosticsSection: View {
  let state: AppModel.DisplayState

  @Environment(AppModel.self) private var model

  private var persistenceKey: String { state.display.persistenceKey }
  private var prefs: DisplayPrefs { DisplayPrefs(persistenceKey: persistenceKey) }
  private var facts: DisplayHardwareFacts? { model.hardwareFacts[persistenceKey] }
  private var path: BrightnessPath { state.controller.brightnessPath }

  /// Asked of the model's own slot rather than of the persistence key: the
  /// model is the thing that decides which display is the built-in, and a
  /// literal key compared here would be a second, driftable copy of that
  /// decision.
  private var isBuiltIn: Bool { model.builtIn?.id == state.id }

  var body: some View {
    // MANDATORY. `DisplayPrefs` is plain `UserDefaults` and is not observable;
    // `prefsRevision` is the ONLY invalidation signal, and this section reads
    // prefs in four of its five groups. Omitting it yields a silently stale
    // page.
    let _ = model.prefsRevision

    Section("Diagnostics") {
      thisDisplayGroup
      brightnessGroup
    }
  }

  // MARK: - 1. This display

  @ViewBuilder private var thisDisplayGroup: some View {
    SettingsCaption("This display")

    LabeledContent("Reported name") {
      Text(verbatim: state.display.name).foregroundStyle(.secondary)
    }

    if !DisplayCardPolicy.normalizedFriendlyName(prefs.friendlyName).isEmpty {
      LabeledContent("Your name for it") {
        Text(verbatim: DisplayCardPolicy.normalizedFriendlyName(prefs.friendlyName))
          .foregroundStyle(.secondary)
      }
    }

    // The cable-and-EDID rows. Omitted wholesale for the built-in panel — see
    // the type comment.
    if !isBuiltIn {
      SettingRow("Which cable this display is connected through.") {
        LabeledContent("Connection") {
          Text(verbatim: transportText).foregroundStyle(.secondary)
        }
      }

      LabeledContent("Manufacturer") {
        Text(verbatim: facts?.manufacturerID ?? "Not reported").foregroundStyle(.secondary)
      }

      LabeledContent("Serial number") {
        Text(verbatim: serialText).foregroundStyle(.secondary)
      }

      // Shown ONLY when it applies, and only once the facts have actually
      // arrived: a caveat raised while we still know nothing would claim the
      // display reported no serial before it reported anything at all. A
      // standing caveat about a hazard the user does not have is noise, and
      // noise is what makes real warnings ignorable.
      if let facts, facts.numericSerialNumber == nil, facts.alphanumericSerialNumber == nil {
        SettingsCaption(
          "This display reports no serial number. Two identical units would share one set of saved settings."
        )
      }

      if let width = facts?.physicalWidthCm, let height = facts?.physicalHeightCm {
        LabeledContent("Panel size") {
          Text(verbatim: "\(width) × \(height) cm").foregroundStyle(.secondary)
        }
      }
    }

    if let native = model.displayModes.catalogs[state.id], native.nativeKnown,
       let current = native.current {
      LabeledContent("Current mode") {
        Text(verbatim: modeText(current)).foregroundStyle(.secondary)
      }
    }

    identityKeysRow
  }

  /// The two keys this display's settings hang off. Split out of the group so
  /// the IOReg tooltip can be attached for externals and left off the built-in,
  /// whose IOReg facts are never read at all — a tooltip there would be
  /// reporting a lookup that never ran.
  ///
  /// The tooltip deliberately carries the IOReg PATH and not
  /// `ioregMatchScore`. The score is a non-optional `Int` that reads 0 both
  /// when nothing matched and when the CoreDisplay dictionary could not be read
  /// at all, so any wording for 0 asserts one of two incompatible things; and
  /// its documented "0…20" ceiling is wrong (the real maximum is 16). A number
  /// that cannot be worded honestly is not a number to put in front of a user
  /// — DT30 rule (g) wants the real one or none.
  @ViewBuilder private var identityKeysRow: some View {
    let row = SettingRow("Settings are saved under the first key. Resolution is saved under the second, because the built-in and virtual displays have no DDC identity to use.") {
      VStack(alignment: .leading, spacing: 2) {
        LabeledContent("Settings key") {
          Text(verbatim: persistenceKey).foregroundStyle(.secondary)
        }
        LabeledContent("Display key") {
          Text(verbatim: model.displayModes.catalogs[state.id]?.display.identity.key ?? "Not enumerated yet")
            .foregroundStyle(.secondary)
        }
      }
    }

    if isBuiltIn {
      row
    } else {
      row.help(ioregPathHelp)
    }
  }

  private var ioregPathHelp: String {
    guard let facts else { return "The system port path for this display has not been read yet." }
    guard let location = facts.ioDisplayLocation else {
      return "This display reports no system port path."
    }
    return "System port path: \(location)"
  }

  /// Rendered as the kernel spelled it. The `Transport` dictionary's vocabulary
  /// is macOS's, not ours, and no real panel's spelling has been observed — so
  /// this maps nothing and prettifies nothing. A pane that invents a vocabulary
  /// lies the moment the kernel's changes.
  private var transportText: String {
    guard let facts else { return "Not enumerated yet" }
    switch (facts.transportUpstream, facts.transportDownstream) {
    case let (up?, down?) where up == down: return up
    case let (up?, down?): return "\(up) → \(down)"
    case let (up?, nil): return up
    case let (nil, down?): return down
    case (nil, nil): return "This display does not report its connection type"
    }
  }

  private var serialText: String {
    guard let facts else { return "Not enumerated yet" }
    if let alphanumeric = facts.alphanumericSerialNumber { return alphanumeric }
    if let numeric = facts.numericSerialNumber { return String(numeric) }
    return "Not reported"
  }

  private func modeText(_ mode: DisplayMode) -> String {
    "\(mode.logicalWidth) × \(mode.logicalHeight) at \(Int(mode.refreshHz.rounded())) Hz"
  }

  // MARK: - 2. How brightness is controlled

  @ViewBuilder private var brightnessGroup: some View {
    SettingsCaption("How brightness is controlled")

    SettingRow(brightnessPathCaption) {
      LabeledContent("Brightness path") {
        Text(verbatim: brightnessPathText).foregroundStyle(.secondary)
      }
    }

    SettingRow("Native brightness is what macOS itself uses. It is the only path that works while a display is in HDR mode.") {
      LabeledContent("Native brightness") {
        Text(DisplayServices.isAvailable
          ? "Available on this Mac"
          : "Unavailable — macOS did not load the framework \(AppInfo.productName) needs for it")
          .foregroundStyle(.secondary)
      }
    }

    // The built-in's whole DDC story, stated once and only where it is true.
    // It is not a failure, a preference, or something a future release fixes,
    // so it is not phrased as any of those.
    if isBuiltIn {
      SettingRow("macOS drives the built-in panel's backlight itself, so there is nothing for \(AppInfo.productName) to send and nothing that can be turned back on.") {
        LabeledContent("Hardware control") {
          Text("Does not apply — this panel has no data cable to carry hardware commands")
            .foregroundStyle(.secondary)
        }
      }
    }

    // Gamma interference is a fight over the software dimming path, and the
    // built-in has no software leg to fight over — the row is omitted there
    // rather than reporting a permanent, meaningless zero.
    if !isBuiltIn, let monitor = model.gammaInterference {
      let count = monitor.interferenceCount(for: state.id)
      LabeledContent("Color profile conflicts") {
        Text(count == 0
          ? "None this session"
          : "\(count) this session — another app keeps taking this display's color profile back")
          .foregroundStyle(.secondary)
      }
      if monitor.suspendedForSession {
        SettingsCaption("\(AppInfo.productName) has stopped watching for these until it is relaunched.")
      }
    }
  }

  /// The engine's own answer, put into the user's words. `BrightnessPath` gained
  /// a `.softwareOnly` case after this section was specified, and it is the one
  /// case where PART of the slider works — so it gets its own sentence rather
  /// than being folded in with plain software dimming, which would overstate
  /// what moves.
  private var brightnessPathText: String {
    switch path {
    case .native:
      "macOS native brightness"
    case .hardware:
      "Hardware commands over the data cable"
    case .software(.gamma):
      "Software, through the display's color profile"
    case .software(.overlay):
      "Software, through a dark overlay"
    case let .combined(switching, .gamma):
      "Split at \(percent(switching)) — software below, the data cable above"
    case let .combined(switching, .overlay):
      "Split at \(percent(switching)) — overlay below, the data cable above"
    case let .softwareOnly(.gamma, .ddcTurnedOff, dimsBelow):
      "Software only below \(percent(dimsBelow)), through the display's color profile"
    case let .softwareOnly(.overlay, .ddcTurnedOff, dimsBelow):
      "Software only below \(percent(dimsBelow)), through a dark overlay"
    case .unavailable(.ddcTurnedOffWithNoSoftwareLeg):
      "Nothing is moving this display's brightness"
    }
  }

  private var brightnessPathCaption: LocalizedStringKey {
    switch path {
    case .native:
      "macOS sets this display's brightness directly. No hardware commands are sent over the cable."
    case .hardware:
      "Every brightness change is a command sent to the display over its data cable."
    case .software:
      "The display's own backlight is not touched. \(AppInfo.productName) darkens what is drawn on it."
    case let .combined(switching, _):
      "Below \(percent(switching)) this display dims in software while the cable holds at its lowest level; above it, the cable carries the whole range."
    case let .softwareOnly(_, .ddcTurnedOff, dimsBelow):
      "The hardware brightness command is turned off for this display, so only the part of the slider below \(percent(dimsBelow)) dims. Above that, nothing moves."
    case .unavailable(.ddcTurnedOffWithNoSoftwareLeg):
      "Combined dimming is off for this display and its hardware brightness command is turned off, so nothing is left to carry the value."
    }
  }

  private func percent(_ value: Double) -> String {
    "\(Int((value * 100).rounded()))%"
  }
}
