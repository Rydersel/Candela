import Observation

/// Single source of truth for one display's brightness (spec §5: every input
/// funnels through here; every surface renders from `brightness`).
@MainActor @Observable
public final class BrightnessController {
  public private(set) var brightness: Double = 0.5
  public private(set) var maxDDCValue: UInt16 = 100

  private let writer: any DDCWriting
  @ObservationIgnored private var pendingWrite: UInt16?
  @ObservationIgnored private var writeTask: Task<Void, Never>?

  public init(writer: any DDCWriting) {
    self.writer = writer
  }

  public func refreshFromHardware() async {
    guard let result = await writer.read(command: VCP.brightness), result.max > 0 else {
      return
    }
    maxDDCValue = result.max
    brightness = Double(min(result.current, result.max)) / Double(result.max)
  }

  /// Synchronous by design: state updates immediately, hardware writes coalesce
  /// latest-wins — a 60 Hz slider drag must never queue stale DDC writes (each
  /// write holds the DDC actor for ~20 ms, more on retries).
  public func setBrightness(_ value: Double) {
    let clamped = min(max(value, 0), 1)
    brightness = clamped
    pendingWrite = UInt16((clamped * Double(maxDDCValue)).rounded())
    startDrainIfNeeded()
  }

  public func waitForPendingWrites() async {
    while let task = writeTask {
      await task.value
    }
  }

  private func startDrainIfNeeded() {
    guard writeTask == nil else { return }
    writeTask = Task {
      while let raw = pendingWrite {
        pendingWrite = nil
        _ = await writer.write(command: VCP.brightness, value: raw)
      }
      writeTask = nil
    }
  }
}
