import CoreGraphics
import Foundation
import Testing
@testable import CandelaKit

/// The predicate that identifies a virtual display Candela did NOT create.
///
/// Every wrong-shape answer must read as "don't know", never as "not virtual":
/// the caller's degrade path for nil is "treat it as an ordinary panel", which
/// is exactly today's behavior, and a nil that read as false would be the same
/// thing while pretending to be an answer.
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

  /// Measured: the built-in Retina panel reports 0, every CGVirtualDisplay
  /// reports 1 (S1). Asserting false rather than `!= true` because the
  /// measurement is what makes the predicate usable; a machine where the
  /// built-in reads nil is a finding, not a pass.
  @Test func theBuiltInPanelIsNotVirtual() {
    #expect(VirtualDisplayDetection.isVirtual(CGMainDisplayID()) == false)
  }
}
