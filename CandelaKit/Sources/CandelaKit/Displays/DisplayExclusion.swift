import CoreGraphics

/// Why one display is not in the DDC control pool.
///
/// One case per drop point in discovery, and it stays that way: the report exists
/// to answer "why is my monitor missing", and a case covering two drops answers
/// with a guess.
///
/// The raw values are internal plumbing and NOT on-disk schema. Nothing persists
/// them and nothing may start: the report prints a sentence from
/// `DiagnosticsCopy`, never the case name.
public enum DisplayExclusionReason: String, Sendable, CaseIterable {
  case builtIn, ownedVirtual, foreignVirtual, dummy, noDDCService
}

/// Which of discovery's two online-list calls macOS refused, where one was.
///
/// They fail independently and cost different things, so the report names which:
/// the count call costs the reader a number, while the fill call decides the
/// control pool and leaves it empty.
public enum OnlineListRefusal: Sendable, Equatable {
  /// The informational two-call count. Discovery records it and steps over it.
  case count
  /// The call that fills the id buffer. Discovery returns with no survivors.
  case fill
}

/// What one discovery pass saw beyond what it kept: every display it dropped with
/// the reason, and the counts that say whether the walk happened at all.
///
/// No serial, no EDID UUID, no persistence key and no identity key. The report is
/// pasted into public issues, so the type carries nothing to leak rather than
/// trusting each caller to leave those out.
public struct DisplayDiscoveryReport: Sendable, Equatable {
  public struct Excluded: Sendable, Equatable {
    public let displayID: CGDirectDisplayID
    public let vendorNumber: UInt32
    public let modelNumber: UInt32
    /// The IOReg walk's own strings, where the drop happened late enough to have
    /// them. Nil for a display dropped before service matching ran.
    public let manufacturerID: String?
    public let productName: String?
    public let reason: DisplayExclusionReason

    public init(
      displayID: CGDirectDisplayID, vendorNumber: UInt32, modelNumber: UInt32,
      manufacturerID: String?, productName: String?, reason: DisplayExclusionReason
    ) {
      self.displayID = displayID
      self.vendorNumber = vendorNumber
      self.modelNumber = modelNumber
      self.manufacturerID = manufacturerID
      self.productName = productName
      self.reason = reason
    }
  }

  public let excluded: [Excluded]
  /// Nil when nothing enumerated: the non-arm64 branch returns no displays and
  /// must not report zero online as if it had counted.
  public let onlineCount: Int?
  /// Nil where both calls answered.
  public let onlineListRefusal: OnlineListRefusal?
  public let slotCapReached: Bool

  public init(
    excluded: [Excluded], onlineCount: Int?, onlineListRefusal: OnlineListRefusal?,
    slotCapReached: Bool
  ) {
    self.excluded = excluded
    self.onlineCount = onlineCount
    self.onlineListRefusal = onlineListRefusal
    self.slotCapReached = slotCapReached
  }

  /// A report whose online count may be missing. The count call and the fill call
  /// fail independently, and only the fill call decides the control pool: a refused
  /// count costs the reader a number, never a display its DDC writer, and it
  /// withdraws the slot-cap claim derived from that same count.
  public static func counted(
    excluded: [Excluded], onlineTotal: UInt32?, slotCapacity: Int
  ) -> DisplayDiscoveryReport {
    DisplayDiscoveryReport(
      excluded: excluded,
      onlineCount: onlineTotal.map { Int($0) },
      onlineListRefusal: onlineTotal == nil ? .count : nil,
      slotCapReached: onlineTotal.map { Int($0) > slotCapacity } ?? false)
  }

  public static let notEnumerated = DisplayDiscoveryReport(
    excluded: [], onlineCount: nil, onlineListRefusal: nil, slotCapReached: false)

  /// macOS refused the call that fills the id list, so this pass controls nothing.
  /// Kept apart from `notEnumerated`: a question asked and not answered is not the
  /// same as one this build never asks.
  public static let listFailed = DisplayDiscoveryReport(
    excluded: [], onlineCount: nil, onlineListRefusal: .fill, slotCapReached: false)
}
