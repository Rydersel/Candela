/// Hardware boundary for DDC/CI. Implementations serialize their own I/O.
public protocol DDCWriting: Sendable {
  func write(command: UInt8, value: UInt16) async -> Bool
  func read(command: UInt8) async -> (current: UInt16, max: UInt16)?
  /// The display's MCCS capability string (VCP 0xF3), reassembled from its
  /// fragments. `nil` means the TRANSACTION failed — never read that as "this
  /// display has no capabilities" (D24: unknown resolves to enabled).
  func readCapabilityString() async -> String?
}

public extension DDCWriting {
  /// Writers with no capabilities path — the built-in's `NoopDDCWriter`, test
  /// fakes — inherit the honest answer: we do not know.
  func readCapabilityString() async -> String? { nil }
}

/// A controller holding hardware writes that have been SUBMITTED and may not
/// have reached the wire.
///
/// Every value controller here submits onto a coalescer that drains on its own
/// task, so a submit call returning says nothing about the register. Anything
/// that is about to make the wire unusable (HDR locks DDC on the display) has
/// to wait the queue out first, and this is what it waits on.
@MainActor
public protocol PendingWireDraining {
  func waitForPendingWrites() async
}
