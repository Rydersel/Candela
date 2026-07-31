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
