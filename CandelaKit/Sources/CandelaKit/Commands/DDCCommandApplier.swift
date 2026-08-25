import os

/// Command-generic DDC applier (D1): carries the VCP byte the write targets,
/// plus the user's control-code remap — fork `getRemapControlCodes` semantics:
/// a non-empty remap REPLACES the command, and writes go to EVERY remapped
/// code (reads use only the first; the read side lives in the controllers).
/// Every DDC leg goes through this — an empty remap is one write to `command`.
public struct DDCCommandApplier: BrightnessApplying {
  public let accepts = HardwareTargetKind.ddc

  /// Per-instance, not static — same rationale as `NativeBrightnessApplier`.
  private let mismatchReported = OSAllocatedUnfairLock(initialState: false)
  private let writer: any DDCWriting
  private let command: UInt8
  private let remapCodes: [UInt8]
  private let onMismatch: ApplierMismatchReporting?

  public init(
    writer: any DDCWriting,
    command: UInt8,
    remapCodes: [UInt8] = [],
    onMismatch: ApplierMismatchReporting? = nil
  ) {
    self.writer = writer
    self.command = command
    self.remapCodes = remapCodes
    self.onMismatch = onMismatch
  }

  public func apply(_ target: HardwareTarget) async -> Bool {
    guard case let .ddc(raw) = target else {
      reportMismatchOnce(
        mismatchReported, "DDCCommandApplier received a .native target", to: onMismatch
      )
      return false
    }
    let codes = remapCodes.isEmpty ? [command] : remapCodes
    var allOK = true
    for code in codes {
      allOK = await writer.write(command: code, value: raw) && allOK
    }
    return allOK
  }
}
