import Testing
@testable import CandelaKit

@Suite("Pref identifier composition") struct PrefIdentifierTests {
  @Test func appLevelIsTheBareRawValue() {
    #expect(PrefIdentifierComposer.compose(.menuIcon) == "menuIcon")
  }
  @Test func perDisplayAppendsTheKey() {
    #expect(PrefIdentifierComposer.compose(.forceSw, persistenceKey: "PK1") == "forceSw.PK1")
  }
  @Test func perCommandMirrorsTheOnDiskShape() {
    #expect(PrefIdentifierComposer.compose(.unavailableDDC, command: .volume, persistenceKey: "PK1")
      == "unavailableDDC.volume.PK1")
  }
  @Test func slotsAppendTheSlot() {
    #expect(PrefIdentifierComposer.compose(.virtualSlotHiDPI, slot: 2) == "virtualSlotHiDPI.2")
  }
}
