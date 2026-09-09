import Testing
@testable import CandelaKit

@Suite("CoreGraphics current mode reads")
struct CoreGraphicsCurrentModeTests {
  @Test("An unreadable current mode returns without enumerating modes")
  func unreadableCurrentSkipsEnumeration() {
    var reads = 0
    var enumerations = 0
    func enumerate() -> [DisplayMode] {
      enumerations += 1
      return []
    }

    let current = CoreGraphicsDisplayConfigurator.resolveCurrent(
      read: {
        reads += 1
        return nil
      },
      in: enumerate()
    )

    #expect(current == nil)
    #expect(reads == 1)
    #expect(enumerations == 0)
  }

  @Test("The captured live mode resolves to its surviving row", arguments: [178, 181])
  func capturedCurrentResolvesToSurvivor(currentID: Int32) {
    let survivor = DisplayMode(
      ioModeID: 178, logicalWidth: 1440, logicalHeight: 2560,
      pixelWidth: 2880, pixelHeight: 5120, refreshHz: 120, isNative: true
    )
    let duplicate = DisplayMode(
      ioModeID: 181, logicalWidth: 1440, logicalHeight: 2560,
      pixelWidth: 2880, pixelHeight: 5120, refreshHz: 120, isNative: false
    )
    var live = DisplayMode(
      ioModeID: currentID, logicalWidth: 1440, logicalHeight: 2560,
      pixelWidth: 2880, pixelHeight: 5120, refreshHz: 120, isNative: false
    )
    var events: [String] = []
    func enumerate() -> [DisplayMode] {
      events.append("enumerate")
      // A display can change while enumeration is in progress. Resolution must
      // use the reading already captured, without a second live read.
      live = DisplayMode(
        ioModeID: 999, logicalWidth: 800, logicalHeight: 600,
        pixelWidth: 800, pixelHeight: 600, refreshHz: 60, isNative: false
      )
      return DisplayModeList.deduplicated([survivor, duplicate])
    }

    let current = CoreGraphicsDisplayConfigurator.resolveCurrent(
      read: {
        events.append("read")
        return live
      },
      in: enumerate()
    )

    #expect(events == ["read", "enumerate"])
    #expect(current?.ioModeID == 178)
    #expect(current?.isNative == true)
  }
}
