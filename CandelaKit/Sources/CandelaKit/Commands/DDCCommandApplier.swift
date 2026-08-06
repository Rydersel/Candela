//  Copyright © MonitorControl. @JoniVR, @theOneyouseek, @waydabber and others

import os

/// Command-generic DDC applier (D1): carries the VCP byte the write targets,
/// plus the user's control-code remap — fork `getRemapControlCodes` semantics:
/// a non-empty remap REPLACES the command, and writes go to EVERY remapped
/// code (reads use only the first; the read side lives in the controllers).
/// Every DDC leg goes through this — an empty remap is one write to `command`.
public struct DDCCommandApplier: BrightnessApplying {
  /// Per-instance, not static — same rationale as `NativeBrightnessApplier`.
  private let mismatchLogged = OSAllocatedUnfairLock(initialState: false)
  private let writer: any DDCWriting
  private let command: UInt8
  private let remapCodes: [UInt8]

  public init(writer: any DDCWriting, command: UInt8, remapCodes: [UInt8] = []) {
    self.writer = writer
    self.command = command
    self.remapCodes = remapCodes
  }

  public func apply(_ target: HardwareTarget) async -> Bool {
    guard case let .ddc(raw) = target else {
      logMismatchOnce(mismatchLogged, "DDCCommandApplier received a .native target")
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
