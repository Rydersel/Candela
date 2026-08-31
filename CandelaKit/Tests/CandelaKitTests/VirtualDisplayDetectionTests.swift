import CoreGraphics
import Foundation
import Testing
@testable import CandelaKit

/// Every wrong-shape answer must read as "don't know", never as "not virtual".
/// The caller treats nil as an ordinary panel; a false would do the same thing
/// while pretending to be an answer.
@Suite("Foreign virtual-display detection (VD3)")
struct VirtualDisplayDetectionTests {
  @Test func theVirtualDeviceFlagIsReadAsABoolean() {
    #expect(VirtualDisplayDetection.flag(in: ["kCGDisplayIsVirtualDevice": 1]) == true)
    #expect(VirtualDisplayDetection.flag(in: ["kCGDisplayIsVirtualDevice": 0]) == false)
  }

  /// An absent key is "don't know". Returning false here would promote a
  /// missing private key into a positive claim about the hardware.
  @Test func anAbsentKeyIsNotAnAnswer() {
    #expect(VirtualDisplayDetection.flag(in: [:]) == nil)
    #expect(VirtualDisplayDetection.flag(in: ["kCGDisplayIsAirPlay": 1]) == nil)
  }

  /// A key whose value is not a number is also "don't know". The measured
  /// shape is an NSNumber; anything else means the dictionary changed under us.
  @Test func aNonNumericValueIsNotAnAnswer() {
    #expect(VirtualDisplayDetection.flag(in: ["kCGDisplayIsVirtualDevice": "yes"]) == nil)
  }

  /// Measured (S1): the built-in Retina panel reports 0, every CGVirtualDisplay
  /// reports 1. Asserts false rather than `!= true` because a built-in that
  /// reads nil is a finding, not a pass.
  @Test func theBuiltInPanelIsNotVirtual() {
    #expect(VirtualDisplayDetection.isVirtual(CGMainDisplayID()) == false)
  }
}
