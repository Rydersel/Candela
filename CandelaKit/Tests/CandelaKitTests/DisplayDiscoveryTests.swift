import Testing
@testable import CandelaKit

@Test func displayNamePrefersIORegProductName() {
  var service = Arm64DDC.IOregService()
  service.productName = "MAG 341C OLED"
  #expect(DisplayDiscovery.displayName(from: service, displayID: 5) == "MAG 341C OLED")
}

@Test func displayNameFallsBackToDisplayID() {
  let service = Arm64DDC.IOregService()  // productName == ""
  #expect(DisplayDiscovery.displayName(from: service, displayID: 5) == "Display 5")
}
