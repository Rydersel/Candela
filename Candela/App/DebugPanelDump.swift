#if DEBUG
  import CandelaKit
  import Foundation
  import os

  /// Writes the menu-bar panel's ROW MODEL to os_log, so a rig pass can assert
  /// panel content from a script with the menu never opened.
  ///
  /// The panel is the least observable surface in the app: it is an
  /// `NSMenu`-hosted `NSHostingView`, which publishes nothing to Accessibility,
  /// and `screencapture` cannot reach the menu's tracking window. Its pixels and
  /// its drags stay out of reach; this makes the model behind them readable.
  ///
  /// The WHOLE file is inside `#if DEBUG`, and so is its call site: the `#if` in
  /// `StatusItemController` wraps the calls themselves, not their bodies, so
  /// Release keeps no residue of it at all. Compiled out of Release BY
  /// CONSTRUCTION, not by remembering to delete it: the standing review step
  /// (grep EVERY Mach-O in the Release bundle for debug markers, with a Debug
  /// positive control, because a Debug app's code lives in `Candela.debug.dylib`
  /// and grepping only the stub passes vacuously) is what proves it, and a
  /// `CANDELA_TOOLBAR_STYLE` env switch once reached a Release build precisely
  /// because it was guarded by discipline instead.
  ///
  /// Trigger: the `CANDELA_DEBUG_PANEL` environment variable, read ONCE and
  /// cached. An env var rather than a pref or a hidden menu item because it
  /// cannot be set by accident on a user's machine and leaves no residue: a
  /// plain `open` of the app never sets it. Any value enables it. Usage:
  ///
  ///   CANDELA_DEBUG_PANEL=1 Candela.app/Contents/MacOS/Candela &
  ///   /usr/bin/log show --last 2m --info --debug \
  ///     --predicate 'subsystem == "com.rydersel.Candela"' | grep paneldump=
  ///
  /// `--info` is not optional: these lines are `.info` and `log show` hides that
  /// level by default. A launch WITHOUT the variable is the control that proves
  /// the grep can come back empty, before an empty result gets read as a panel
  /// with no rows.
  ///
  /// Format: one `paneldump=header` line per dump, then one `paneldump=row` line
  /// per panel row, in render order (the built-in first when it is shown). Every
  /// field is `key=value`, values with spaces are double-quoted, and booleans are
  /// spelled yes/no so a grep for `=no` cannot also match a number.
  ///
  /// Cadence: one dump after the first display refresh, then one per
  /// reconfiguration pass. No timer and no polling, and no dump-on-demand
  /// channel: a re-dump is a relaunch. `pass=1` is the launch dump by
  /// construction.
  ///
  /// Every field comes from `PanelView`'s own derivations (`visibleDisplays`,
  /// `showsBuiltIn`, `title`, the two slider predicates) and from the model
  /// accessors the panel's body calls. Nothing is re-derived here, so the dump
  /// cannot describe a panel other than the one that renders, and the
  /// `CandelaAppTests` row-model tests over the same functions cannot drift from
  /// either: the fixtures prove the logic, the dump proves the live wiring.
  ///
  /// It reads published state only, never the wire. No DDC read, no capabilities
  /// probe, nothing that submits a write: a dump must never be able to change
  /// what it is reporting, and the values it prints are last-written state, which
  /// is all a write-only panel has anyway.
  @MainActor
  enum DebugPanelDump {
    static let environmentKey = "CANDELA_DEBUG_PANEL"

    /// Read once. The dump runs on every refresh, and re-reading the environment
    /// per pass would suggest it can change under a running process.
    static let isEnabled = ProcessInfo.processInfo.environment[environmentKey] != nil

    private static let log = Logger(subsystem: "com.rydersel.Candela", category: "PanelDump")

    private static var pass = 0

    /// Deliberately silent when the variable is unset: that is every ordinary
    /// Debug launch, and a line there would be noise in all of them.
    static func dumpIfRequested(_ model: AppModel) {
      guard isEnabled else { return }
      pass += 1
      let externals = PanelView.visibleDisplays(model)
      let showsBuiltIn = PanelView.showsBuiltIn(model)
      let builtInState: String = if model.builtIn == nil {
        "absent"
      } else {
        showsBuiltIn ? "shown" : "hidden"
      }
      emit([
        ("paneldump", "header"),
        ("pass", "\(pass)"),
        ("rows", "\(externals.count + (showsBuiltIn && model.builtIn != nil ? 1 : 0))"),
        ("builtIn", builtInState),
        ("externals", "\(externals.count)"),
        // The gap between what is attached and what renders: a row missing
        // because its display is hidden reads as a missing row otherwise.
        ("hiddenExternals", "\(model.displays.count - externals.count)"),
        ("safeMode", yesNo(model.isSafeMode)),
        ("prefsRevision", "\(model.prefsRevision)"),
      ])
      var index = 0
      if showsBuiltIn, let builtIn = model.builtIn {
        index += 1
        emit(row(builtIn, index: index, isBuiltIn: true, model: model))
      }
      for state in externals {
        index += 1
        emit(row(state, index: index, isBuiltIn: false, model: model))
      }
    }

    private static func row(
      _ state: AppModel.DisplayState, index: Int, isBuiltIn: Bool, model: AppModel
    ) -> [(String, String)] {
      let title = PanelView.title(for: state.display)
      let key = state.display.persistenceKey
      let prefs = PanelView.standardPrefs(key)
      let controller = state.controller
      var fields: [(String, String)] = [
        ("paneldump", "row"),
        ("index", "\(index)"),
        ("kind", isBuiltIn ? "builtIn" : "external"),
        ("title", quoted(title)),
        ("key", quoted(key)),
        ("displayID", "\(state.id)"),
        ("brightness", value(controller.brightness)),
        ("hdrEngaged", yesNo(controller.isHDREngaged)),
        ("hdrSupported", yesNo(controller.supportsHDR)),
        ("hdrMode", controller.hdrMode == .off ? "off" : "alwaysOn"),
        // The wire's verdict and the caption the panel draws from it (WD5). The
        // panel is the least observable surface in the app, and this pair is the
        // only way a rig leg can assert that a degraded display SAYS so: both
        // come from the same accessors the row's body calls, so they cannot
        // describe a panel other than the one on screen.
        ("wireUnresponsive", yesNo(controller.isWireUnresponsive)),
        ("brightnessReason", quoted(model.brightnessSliderCompactReason(state) ?? "none")),
      ]
      guard !isBuiltIn else {
        // The built-in section is a name and a brightness slider, full stop:
        // its volume and contrast controllers are inert placeholders on a
        // `NoopDDCWriter`, so `PanelView`'s body renders value rows for
        // `model.displays` alone and never asks either predicate about this
        // slot. Reporting the predicates here would answer a question the panel
        // does not ask.
        fields.append(("volumeSlider", "notRendered"))
        fields.append(("contrastSlider", "notRendered"))
        return fields
      }
      // Both inputs are printed beside each verdict, so a hidden or greyed row
      // says WHICH input hid or greyed it without the reader re-deriving the
      // rule from the verdict.
      let showsVolume = PanelView.showsVolumeSlider(for: state, prefs: prefs)
      let volumeEnabled = model.volumeSliderEnabled(state)
      fields += [
        ("volumeSlider", showsVolume ? "shown" : "hidden"),
        ("volumeAvailable", yesNo(state.volume.isAvailable)),
        ("hideVolumePref", yesNo(prefs.hideVolumeSlider)),
        ("volumeEnabled", yesNo(volumeEnabled)),
        ("volumeSupport", support(model.volumeSupport[key])),
        ("muteSupport", support(model.muteSupport[key])),
        // The panel's own hover copy, so the dump quotes the sentence on screen
        // rather than a second account of the same decision.
        ("volumeReason", quoted(model.volumeSliderCompactReason(state) ?? "none")),
        ("volume", value(state.volume.value)),
        ("muted", yesNo(state.volume.isMuted)),
        ("contrastSlider", PanelView.showsContrastSlider(for: state, prefs: prefs) ? "shown" : "hidden"),
        ("contrastAvailable", yesNo(state.contrast.isAvailable)),
        ("showContrastPref", yesNo(prefs.showContrast)),
        ("contrast", value(state.contrast.value)),
      ]
      return fields
    }

    /// One line per call. `privacy: .public` because every field here is app
    /// state a rig script has to read back, and an interpolated string is
    /// `<private>` by default: the redaction would leave the line's shape intact
    /// and its content gone, which reads as a bug in the panel rather than in
    /// the logging.
    private static func emit(_ fields: [(String, String)]) {
      let line = fields.map { "\($0)=\($1)" }.joined(separator: " ")
      log.info("\(line, privacy: .public)")
    }

    /// Never true/false: a `=no` grep must not also match a value.
    private static func yesNo(_ flag: Bool) -> String { flag ? "yes" : "no" }

    /// Absent reads as unknown, exactly as every consumer of these dictionaries
    /// resolves it (D24), so the dump cannot report a fourth state nothing acts
    /// on.
    private static func support(_ verdict: VCPSupport?) -> String {
      switch verdict ?? .unknown {
      case .supported: "supported"
      case .unsupported: "unsupported"
      case .unknown: "unknown"
      }
    }

    private static func value(_ raw: Double) -> String { String(format: "%.3f", raw) }

    /// Friendly names are user text and can carry anything, including the quote
    /// and newline this format's parser depends on.
    private static func quoted(_ text: String) -> String {
      let flattened = text
        .replacingOccurrences(of: "\"", with: "'")
        .replacingOccurrences(of: "\n", with: " ")
      return "\"\(flattened)\""
    }
  }
#endif
