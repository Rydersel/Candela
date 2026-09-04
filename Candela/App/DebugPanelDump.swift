#if DEBUG
  import CandelaKit
  import Foundation
  import os

  /// Writes the menu-bar panel's ROW MODEL to os_log, so a rig pass can assert
  /// panel content without opening the menu. The panel is `NSMenu`-hosted: it
  /// publishes nothing to Accessibility and `screencapture` cannot reach its
  /// tracking window, so its pixels are unreadable.
  ///
  /// The file and its call site are both inside `#if DEBUG`, so Release keeps no
  /// residue by construction rather than by discipline.
  ///
  /// Trigger: `CANDELA_DEBUG_PANEL`, read once, any value. An env var cannot be
  /// set by accident on a user's machine and a plain `open` never sets it.
  ///
  ///   CANDELA_DEBUG_PANEL=1 Candela.app/Contents/MacOS/Candela &
  ///   /usr/bin/log show --last 2m --info --debug \
  ///     --predicate 'subsystem == "com.rydersel.Candela"' | grep paneldump=
  ///
  /// `--info` is not optional: these lines are `.info` and `log show` hides that
  /// level by default. Launch once without the variable as the control that
  /// proves the grep can come back empty.
  ///
  /// Format: one `paneldump=header` line per dump, then one `paneldump=row` per
  /// row in render order. Fields are `key=value`, values with spaces quoted, and
  /// booleans spelled yes/no so a `=no` grep cannot match a number. One dump
  /// after the first display refresh, then one per reconfiguration pass; a
  /// re-dump is a relaunch.
  ///
  /// Every field comes from `PanelView`'s own derivations and the model accessors
  /// its body calls, so the dump cannot describe a panel other than the one that
  /// renders. Published state only: no DDC read, no capabilities probe, nothing
  /// that submits a write.
  @MainActor
  enum DebugPanelDump {
    static let environmentKey = "CANDELA_DEBUG_PANEL"

    /// Read once: re-reading per pass would suggest the environment can change
    /// under a running process.
    static let isEnabled = ProcessInfo.processInfo.environment[environmentKey] != nil

    private static let log = Logger(subsystem: "com.rydersel.Candela", category: "PanelDump")

    private static var pass = 0

    /// Silent when the variable is unset, which is every ordinary Debug launch.
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
        ("hdrProbed", yesNo(controller.hdrCapabilityProbed)),
        // From the same helper the row calls, so a rig leg can read the reason
        // without a hover.
        ("hdrRefusal", quoted(PanelView.hdrRefusalReason(
          isShowingSynthesizedSize: model.synthesis.isEngaged(displayID: state.display.id),
          isHDREngaged: controller.isHDREngaged,
          supportsHDR: controller.supportsHDR,
          capabilityProbed: controller.hdrCapabilityProbed) ?? "none")),
        ("hdrMode", controller.hdrMode == .off ? "off" : "alwaysOn"),
        // The verdict and the caption, from the same accessors the row's body
        // calls: the only way a rig leg can assert a degraded panel says so.
        ("wireUnresponsive", yesNo(controller.isWireUnresponsive)),
        ("brightnessReason", quoted(model.brightnessSliderCompactReason(state) ?? "none")),
      ]
      guard !isBuiltIn else {
        // The built-in section is a name and a brightness slider: its volume and
        // contrast controllers are inert placeholders on a `NoopDDCWriter`, and
        // `PanelView` never asks either predicate about this slot.
        fields.append(("volumeSlider", "notRendered"))
        fields.append(("contrastSlider", "notRendered"))
        return fields
      }
      // Both inputs print beside each verdict, so a hidden or greyed row says
      // WHICH input hid or greyed it.
      let showsVolume = PanelView.showsVolumeSlider(for: state, prefs: prefs)
      let volumeEnabled = model.volumeSliderEnabled(state)
      fields += [
        ("volumeSlider", showsVolume ? "shown" : "hidden"),
        ("volumeAvailable", yesNo(state.volume.isAvailable)),
        ("hideVolumePref", yesNo(prefs.hideVolumeSlider)),
        ("volumeEnabled", yesNo(volumeEnabled)),
        ("volumeSupport", support(model.volumeSupport[key])),
        ("muteSupport", support(model.muteSupport[key])),
        // The panel's own hover copy, not a second account of the same decision.
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

    /// `privacy: .public` because an interpolated string is `<private>` by
    /// default, and redaction leaves the line's shape intact with its content
    /// gone, which reads as a panel bug rather than a logging one.
    private static func emit(_ fields: [(String, String)]) {
      let line = fields.map { "\($0)=\($1)" }.joined(separator: " ")
      log.info("\(line, privacy: .public)")
    }

    /// Never true/false: a `=no` grep must not also match a value.
    private static func yesNo(_ flag: Bool) -> String { flag ? "yes" : "no" }

    /// Absent reads as unknown, as every consumer of these dictionaries resolves
    /// it, so the dump cannot report a fourth state nothing acts on.
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
