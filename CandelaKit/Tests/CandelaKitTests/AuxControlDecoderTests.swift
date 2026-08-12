import Testing
@testable import CandelaKit

@Suite("Aux-control data1 decode")
struct AuxControlDecoderTests {
  private func payload(keycode: Int64, state: Int64, isRepeat: Bool = false) -> Int64 {
    (keycode << 16) | (state << 8) | (isRepeat ? 1 : 0)
  }

  @Test func brightnessUpPressed() {
    let press = AuxControlDecoder.decode(data1: payload(keycode: 2, state: 0xA), modifiers: [])
    #expect(press?.key == .brightnessUp)
    #expect(press?.isPressed == true)
    #expect(press?.isRepeat == false)
  }

  @Test func brightnessDownReleased() {
    let press = AuxControlDecoder.decode(data1: payload(keycode: 3, state: 0xB), modifiers: [])
    #expect(press?.key == .brightnessDown)
    #expect(press?.isPressed == false)
  }

  @Test func autoRepeatBitIsBitZero() {
    let press = AuxControlDecoder.decode(
      data1: payload(keycode: 2, state: 0xA, isRepeat: true), modifiers: []
    )
    #expect(press?.isRepeat == true)
    #expect(press?.isPressed == true)
  }

  @Test func volumeAndMuteKeycodes() {
    #expect(AuxControlDecoder.decode(data1: payload(keycode: 0, state: 0xA), modifiers: [])?.key == .volumeUp)
    #expect(AuxControlDecoder.decode(data1: payload(keycode: 1, state: 0xA), modifiers: [])?.key == .volumeDown)
    #expect(AuxControlDecoder.decode(data1: payload(keycode: 7, state: 0xA), modifiers: [])?.key == .mute)
  }

  @Test func modifiersArePassedThroughUntouched() {
    let press = AuxControlDecoder.decode(
      data1: payload(keycode: 2, state: 0xA), modifiers: [.option, .shift]
    )
    #expect(press?.modifiers == [.option, .shift])
  }

  /// Caps lock rides the same event subtype as the media keys. It is the key
  /// whose HIToolbox handling made building an NSEvent on the tap thread
  /// unsafe, so it had better still fall out as "not ours".
  @Test func capsLockIsNotRouted() {
    #expect(AuxControlDecoder.decode(data1: payload(keycode: 4, state: 0xB), modifiers: []) == nil)
  }

  @Test func ejectAndPlayAreNotRouted() {
    #expect(AuxControlDecoder.decode(data1: payload(keycode: 14, state: 0xA), modifiers: []) == nil)
    #expect(AuxControlDecoder.decode(data1: payload(keycode: 16, state: 0xA), modifiers: []) == nil)
  }

  /// All-ones is what a sign-extended or garbage read looks like. Bits 16...31
  /// come out as 0xFFFF, which IOKit spells `NX_NOSPECIALKEY`, so it declines.
  @Test func allOnesDecodesToNoKey() {
    #expect(AuxControlDecoder.decode(data1: -1, modifiers: []) == nil)
  }

  /// Zero is the dangerous one, and the reason the tap self-checks its field
  /// indices before arming: `NX_KEYTYPE_SOUND_UP` is 0, so an all-zero read
  /// decodes as a perfectly plausible volume-up release rather than as an
  /// error. The decoder cannot tell the difference; only the self-check can.
  @Test func zeroDecodesAsAVolumeUpRelease() {
    let press = AuxControlDecoder.decode(data1: 0, modifiers: [])
    #expect(press?.key == .volumeUp)
    #expect(press?.isPressed == false)
    #expect(press?.isRepeat == false)
  }
}
