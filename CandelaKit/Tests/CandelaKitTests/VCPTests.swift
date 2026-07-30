import Testing
@testable import CandelaKit

@Test func brightnessVCPCodeMatchesMCCS() {
  #expect(VCP.brightness == 0x10)
}
