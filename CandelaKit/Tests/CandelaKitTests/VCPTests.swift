import Testing
@testable import CandelaKit

@Test func brightnessVCPCodeMatchesMCCS() {
  #expect(VCP.brightness == 0x10)
}

@Test func muteCode() {
  #expect(VCP.audioMuteScreenBlank == 0x8D)
}
