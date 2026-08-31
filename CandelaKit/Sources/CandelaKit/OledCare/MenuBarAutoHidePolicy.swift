/// What the Control Center domain holds for `AutoHideMenuBarOption`, as three
/// states rather than an optional: "no value" and "a value we cannot read" are
/// different facts, and the policy collapses them by choice, not by type.
public enum ControlCenterMenuBarRecord: Equatable, Sendable {
  case absent
  case option(Int)
  /// Present, but not an integer.
  case unreadable
}

/// Decides how the two records of "automatically hide the menu bar" are read
/// and written across the whole macOS support range. Pure, so branches this
/// machine can never enter are still covered by tests; `SystemChromeWriter`
/// supplies the live values, owns every side effect, and states what is
/// measured here versus assumed from published sources.
public enum MenuBarAutoHidePolicy {
  /// The four-way choice, as MEASURED on macOS 26 (2026-08-07) by driving
  /// System Settings through accessibility and diffing the domains it wrote.
  public static let optionAlways = 0
  public static let optionOnDesktopOnly = 1
  public static let optionInFullScreenOnly = 2
  public static let optionNever = 3

  /// The first macOS major whose Control Center pane is sourced to keep this
  /// record. Only ever consulted to break the tie on a record that is not
  /// there, never to override one that is.
  public static let controlCenterRecordIntroducedIn = 26

  /// Feature detection first, version second.
  ///
  /// A decodable value proves this macOS keeps the record, so it participates.
  /// With nothing to detect, the version decides whether this macOS's own
  /// settings pane is expected to create the key: on 26 and later Candela writes
  /// it rather than leaving System Settings to disagree. Before that the picker
  /// runs on the global keys alone, and guessing an integer into undocumented
  /// Control Center schema nobody here can test is the worse failure.
  public static func controlCenterRecordParticipates(
    _ record: ControlCenterMenuBarRecord, osMajorVersion: Int
  ) -> Bool {
    switch record {
    case .option: return true
    case .absent, .unreadable: return osMajorVersion >= controlCenterRecordIntroducedIn
    }
  }

  /// What the record claims about the DESKTOP half, or nil when it makes no
  /// claim this code can read. An unrecognised integer is nil on purpose:
  /// defaulting schema drift to "hidden" would pin the switch ON with nothing
  /// able to clear it.
  public static func recordHidesOnDesktop(_ record: ControlCenterMenuBarRecord) -> Bool? {
    guard case .option(let option) = record else { return nil }
    switch option {
    case optionAlways, optionOnDesktopOnly: return true
    case optionInFullScreenOnly, optionNever: return false
    default: return nil
    }
  }

  /// Hidden if EITHER half says hidden, deliberately pessimistic: the switch
  /// must read ON whenever anything is hiding the bar, because turning it off
  /// is the only in-app route back (D29 rule 3).
  ///
  /// The participation guard is load-bearing. This predicate and
  /// `writesControlCenterRecord` ask the SAME question, so the read can never be
  /// swayed by a record the write would decline to touch. If they disagreed, an
  /// OFF click would write only the legacy key and the switch would snap back
  /// with the menu bar still gone.
  public static func isMenuBarHidden(
    effectiveBit: Bool, record: ControlCenterMenuBarRecord, osMajorVersion: Int
  ) -> Bool {
    guard controlCenterRecordParticipates(record, osMajorVersion: osMajorVersion),
          let recorded = recordHidesOnDesktop(record)
    else { return effectiveBit }
    return effectiveBit || recorded
  }

  /// The write leg of the same question. Named separately so a caller reads as
  /// a decision rather than as a re-derivation.
  public static func writesControlCenterRecord(
    _ record: ControlCenterMenuBarRecord, osMajorVersion: Int
  ) -> Bool {
    controlCenterRecordParticipates(record, osMajorVersion: osMajorVersion)
  }

  /// The option encodes BOTH halves, and the full-screen half is never
  /// Candela's to choose: it is read from the user's existing preference and
  /// passed straight back through.
  public static func option(desktopHides: Bool, fullScreenHides: Bool) -> Int {
    if desktopHides { return fullScreenHides ? optionAlways : optionOnDesktopOnly }
    return fullScreenHides ? optionInFullScreenOnly : optionNever
  }

  /// Everything one menu bar auto-hide write does to the machine, in order.
  ///
  /// The broadcast is why this is a sequence rather than two booleans.
  /// Preference writes alone change NOTHING on screen (`SystemChromeWriter` has
  /// the measurement); the system adopts them only when told to reconcile.
  /// Branching over that in the writer put the broadcast on one path and not the
  /// other, so a write could land and do nothing. Here the branch is chosen once
  /// and the broadcast appended unconditionally.
  public static func writeEffects(
    desktopHides: Bool, fullScreenHides: Bool,
    record: ControlCenterMenuBarRecord, osMajorVersion: Int
  ) -> [MenuBarWriteEffect] {
    var effects: [MenuBarWriteEffect] = [.setEffectiveBit(hidden: desktopHides)]
    if writesControlCenterRecord(record, osMajorVersion: osMajorVersion) {
      effects.append(.setControlCenterRecord(
        option: option(desktopHides: desktopHides, fullScreenHides: fullScreenHides)))
    }
    // Last, always: a reconcile that ran before the record write would adopt
    // the value being replaced.
    effects.append(.broadcastChange)
    return effects
  }
}

/// One step of a menu bar auto-hide write. `SystemChromeWriter` interprets these
/// against the live system; the ordering and the branch live in
/// `MenuBarAutoHidePolicy.writeEffects`, where they can be tested on the
/// versions this machine cannot boot.
public enum MenuBarWriteEffect: Equatable, Sendable {
  /// `NSGlobalDomain _HIHideMenuBar`.
  case setEffectiveBit(hidden: Bool)
  /// `com.apple.controlcenter AutoHideMenuBarOption`.
  case setControlCenterRecord(option: Int)
  /// Tell the system to adopt what was just written.
  case broadcastChange
}
