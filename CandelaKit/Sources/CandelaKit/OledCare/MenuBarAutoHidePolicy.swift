/// What the Control Center domain holds for `AutoHideMenuBarOption`, as three
/// distinguishable states rather than an optional. "No value" and "a value in a
/// shape we do not recognise" are different facts about the machine and the
/// policy below treats them the same way only because it decided to, not
/// because the type collapsed them.
public enum ControlCenterMenuBarRecord: Equatable, Sendable {
  case absent
  case option(Int)
  /// Present, but not an integer.
  case unreadable
}

/// Decides how the two records of "automatically hide the menu bar" are read
/// and written across the whole macOS support range. Pure, so the branches this
/// machine can never enter are still covered by tests: `SystemChromeWriter`
/// supplies the live values and owns every side effect.
///
/// See `SystemChromeWriter` for the single statement of what is measured here
/// and what is assumed from published sources.
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
  /// A decodable value is proof this macOS keeps the record, whatever its
  /// version number, so it participates. Only when there is nothing usable to
  /// detect does the version get a vote, and then it answers one narrow
  /// question: is this a macOS whose own settings pane is expected to create
  /// the key? On 26 and later, yes, so Candela writes it rather than leaving
  /// System Settings to disagree. Before that, published evidence says the
  /// picker runs on the global keys alone, and writing a guessed integer into
  /// undocumented Control Center schema on a version nobody here can test is a
  /// worse failure than not writing it.
  public static func controlCenterRecordParticipates(
    _ record: ControlCenterMenuBarRecord, osMajorVersion: Int
  ) -> Bool {
    switch record {
    case .option: return true
    case .absent, .unreadable: return osMajorVersion >= controlCenterRecordIntroducedIn
    }
  }

  /// What the record claims about the DESKTOP half, or nil when it makes no
  /// claim this code can read. An unrecognised integer is nil on purpose: a
  /// value outside the measured four is schema drift, and defaulting drift to
  /// "hidden" would pin the switch ON with nothing able to clear it.
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
  /// The participation guard is load-bearing, not a tidiness pass. This
  /// predicate and `writesControlCenterRecord` ask the SAME question, so the
  /// read can never be influenced by a record the write would decline to
  /// touch. Were they allowed to disagree, an OFF click would write only the
  /// legacy key, leave the record still reporting hidden, and the switch would
  /// snap back with the menu bar still gone. One predicate, both legs, so that
  /// state cannot be constructed.
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
}
