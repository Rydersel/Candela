/// What one DDC read transaction got back. An optional tuple could not separate
/// a panel that puts zeros on the bus from one that never answers, and only the
/// first is the write-only signature. Transports that cannot tell say `noReply`.
public enum DDCReadOutcome: Sendable, Equatable {
  /// A checksum-clean Get VCP reply for the code that was asked. A `max` of 0
  /// carries no value; what this case carries is that a FRAME arrived.
  case frame(current: UInt16, max: UInt16)
  /// The panel wrote zeros over the transport's sentinel: it is on the bus and
  /// saying nothing.
  case allZeros
  /// Nothing usable came back: a silent bus, a reply that failed validation, or
  /// a read call that reported success and left the buffer untouched.
  case noReply
  /// The panel's own result code for this register: it read the request and
  /// answered that it does not carry the code. Separate from `noReply` because
  /// it is a reply, and separate from `frame` because there is no value in it.
  case refused

  public var value: (current: UInt16, max: UInt16)? {
    guard case let .frame(current, max) = self else { return nil }
    return (current, max)
  }

  /// `max == 0` folds to `allZeros` here, once, so the two read sites cannot drift.
  public var evidence: DDCReadEvidence {
    switch self {
    case let .frame(_, max): max > 0 ? .answered : .allZeros
    case .allZeros: .allZeros
    case .noReply: .noReply
    case .refused: .refused
    }
  }
}
