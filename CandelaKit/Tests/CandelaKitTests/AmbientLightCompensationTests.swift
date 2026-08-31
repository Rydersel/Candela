import CoreGraphics
import Foundation
import Testing
@testable import CandelaKit

/// macOS's ambient auto-brightness, over the injectable symbol table.
///
/// Everything runs against fakes: the rules that matter are about missing
/// symbols and reads that refuse to answer, and neither is reachable on a
/// machine where the API works.
@Suite("Ambient light compensation")
struct AmbientLightCompensationTests {
  private static let builtIn: CGDirectDisplayID = 1
  private static let external: CGDirectDisplayID = 2

  /// The setting as macOS holds it, for one display.
  ///
  /// Locked rather than actor-isolated because the symbol closures are
  /// synchronous and `@Sendable`, which leaves no await to hand an actor. The
  /// lock covers every access to both stored properties, so the unchecked
  /// conformance is confined to this file's fakes.
  private final class FakePanel: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Bool
    private var writeCount = 0
    /// What a write does to the stored value. Identity is an honest panel; the
    /// others are the ways a write can fail to land while still returning.
    private let coerce: @Sendable (Bool) -> Bool

    init(_ value: Bool, coerce: @escaping @Sendable (Bool) -> Bool = { $0 }) {
      self.value = value
      self.coerce = coerce
    }

    var stored: Bool { lock.withLock { value } }
    var writes: Int { lock.withLock { writeCount } }

    func write(_ requested: Bool) {
      lock.withLock {
        writeCount += 1
        value = coerce(requested)
      }
    }
  }

  private static func symbols(
    panel: FakePanel,
    hasSensor: Bool? = true,
    readAnswers: Bool = true,
    writable: Bool = true
  ) -> AmbientLightSymbols {
    var table = AmbientLightSymbols()
    if let hasSensor {
      let query: AmbientLightSymbols.SensorQuery = { _ in hasSensor }
      table.hasSensor = query
    }
    if readAnswers {
      let read: AmbientLightSymbols.Read = { _ in panel.stored }
      table.read = read
    } else {
      let refusing: AmbientLightSymbols.Read = { _ in nil }
      table.read = refusing
    }
    if writable {
      let write: AmbientLightSymbols.Write = { _, enabled in panel.write(enabled) }
      table.write = write
    }
    return table
  }

  // MARK: - Whether the control is offered at all

  /// The degradation case no hardware pass can reach by waiting: every symbol
  /// gone, which is also what a failed dlopen leaves behind.
  @Test func aMachineWithNoSymbolsSupportsNothing() {
    let degraded = AmbientLightCompensation(symbols: .none)
    #expect(!degraded.supports(Self.builtIn))
    #expect(degraded.isEnabled(Self.builtIn) == nil)
    #expect(degraded.setEnabled(true, for: Self.builtIn) == nil)
  }

  /// A resolved reader with no writer is a switch that can only ever describe
  /// the state it cannot change, which is worse than no switch.
  @Test func aMissingWriterWithdrawsTheControl() {
    let panel = FakePanel(true)
    let compensation = AmbientLightCompensation(symbols: Self.symbols(panel: panel, writable: false))
    #expect(!compensation.supports(Self.builtIn))
    // The reader still works, and says so: withdrawing the control is a
    // decision about the UI, not a claim that macOS stopped answering.
    #expect(compensation.isEnabled(Self.builtIn) == true)
  }

  /// Without the reader there is no achieved state to publish, so the switch
  /// could only ever show what was asked for.
  @Test func aMissingReaderWithdrawsTheControl() {
    let panel = FakePanel(true)
    let symbols = AmbientLightSymbols(
      hasSensor: { _ in true }, read: nil, write: { _, enabled in panel.write(enabled) })
    #expect(!AmbientLightCompensation(symbols: symbols).supports(Self.builtIn))
  }

  @Test func theSensorQueryDecidesWhenItResolves() {
    let panel = FakePanel(false)
    let withSensor = AmbientLightCompensation(symbols: Self.symbols(panel: panel, hasSensor: true))
    let withoutSensor = AmbientLightCompensation(symbols: Self.symbols(panel: panel, hasSensor: false))
    #expect(withSensor.supports(Self.builtIn))
    #expect(!withoutSensor.supports(Self.external))
  }

  /// The dedicated sensor query outranks the getter's success, which is the
  /// looser signal of the two.
  @Test func aWorkingGetterDoesNotOverrideTheSensorQuery() {
    let panel = FakePanel(true)
    let compensation = AmbientLightCompensation(symbols: Self.symbols(panel: panel, hasSensor: false))
    #expect(compensation.isEnabled(Self.external) == true)
    #expect(!compensation.supports(Self.external))
  }

  /// The fallback for a macOS that keeps the getter and drops the sensor query.
  /// On the rig the getter separates the same two groups: 0 on the built-in, an
  /// error on a display with no sensor.
  @Test func theReaderStandsInWhenTheSensorQueryIsAbsent() {
    let panel = FakePanel(true)
    let answering = AmbientLightCompensation(
      symbols: Self.symbols(panel: panel, hasSensor: nil, readAnswers: true))
    let refusing = AmbientLightCompensation(
      symbols: Self.symbols(panel: panel, hasSensor: nil, readAnswers: false))
    #expect(answering.supports(Self.builtIn))
    #expect(!refusing.supports(Self.external))
  }

  // MARK: - Reading

  /// The reason `Read` returns an optional rather than a bool. A refused read
  /// leaves its out-parameter untouched, so folding the failure into false
  /// would report "off" for a display that never said anything.
  @Test func aRefusedReadIsNotOff() {
    let panel = FakePanel(true)
    let compensation = AmbientLightCompensation(
      symbols: Self.symbols(panel: panel, readAnswers: false))
    #expect(compensation.isEnabled(Self.external) == nil)
  }

  @Test func aReadReportsWhatMacOSHolds() {
    let on = AmbientLightCompensation(symbols: Self.symbols(panel: FakePanel(true)))
    let off = AmbientLightCompensation(symbols: Self.symbols(panel: FakePanel(false)))
    #expect(on.isEnabled(Self.builtIn) == true)
    #expect(off.isEnabled(Self.builtIn) == false)
  }

  // MARK: - Writing

  @Test func aWriteThatLandsReportsTheNewState() {
    let panel = FakePanel(false)
    let compensation = AmbientLightCompensation(symbols: Self.symbols(panel: panel))
    #expect(compensation.setEnabled(true, for: Self.builtIn) == true)
    #expect(panel.stored)
    #expect(compensation.setEnabled(false, for: Self.builtIn) == false)
    #expect(!panel.stored)
  }

  /// A write that returns is not a write that happened: this panel takes the
  /// call, counts it, and stays put, and the answer is the state it reached.
  @Test func aWriteThatDoesNotLandReportsTheOldState() {
    let stubborn = FakePanel(false, coerce: { _ in false })
    let compensation = AmbientLightCompensation(symbols: Self.symbols(panel: stubborn))
    #expect(compensation.setEnabled(true, for: Self.builtIn) == false)
    #expect(stubborn.writes == 1)
  }

  /// A panel that coerces the request to something else, the way one of the
  /// monitors on the rig coerces an unadvertised DDC value: the report follows
  /// the hardware, not the request.
  @Test func aCoercedWriteReportsTheCoercedState() {
    let inverting = FakePanel(false, coerce: { !$0 })
    let compensation = AmbientLightCompensation(symbols: Self.symbols(panel: inverting))
    #expect(compensation.setEnabled(false, for: Self.builtIn) == true)
    #expect(compensation.setEnabled(true, for: Self.builtIn) == false)
  }

  /// No write reaches a display that does not support the setting. The control
  /// is not rendered there, so this is a cheap second line of defence.
  @Test func anUnsupportedDisplayIsNeverWrittenTo() {
    let panel = FakePanel(false)
    let compensation = AmbientLightCompensation(symbols: Self.symbols(panel: panel, hasSensor: false))
    #expect(compensation.setEnabled(true, for: Self.external) == false)
    #expect(panel.writes == 0)
  }

  /// With the writer gone the request is dropped and the reader still answers,
  /// so the caller learns the state rather than a fiction about the write.
  @Test func aMissingWriterDropsTheRequestAndStillReports() {
    let panel = FakePanel(true)
    let compensation = AmbientLightCompensation(symbols: Self.symbols(panel: panel, writable: false))
    #expect(compensation.setEnabled(false, for: Self.builtIn) == true)
    #expect(panel.writes == 0)
  }
}
