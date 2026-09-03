import CoreGraphics
import Foundation
import Testing
@testable import CandelaKit

@Suite("Display rotation")
struct DisplayRotationTests {
  private func display(
    _ id: CGDirectDisplayID, builtIn: Bool = false, mirroring: CGDirectDisplayID? = nil
  ) -> ConfiguredDisplay {
    ConfiguredDisplay(
      id: id,
      identity: DisplayConfigIdentity(vendor: 0x3669, model: 0x3DD0, serial: 0, isBuiltIn: builtIn),
      name: "Display \(id)",
      isBuiltIn: builtIn,
      mirrorsDisplay: mirroring ?? kCGNullDirectDisplay
    )
  }

  // MARK: - The angle type

  @Test func everyRightAngleRoundTripsThroughDegrees() {
    for rotation in DisplayRotation.allCases {
      #expect(DisplayRotation(degrees: Double(rotation.rawValue)) == rotation)
      #expect(rotation.degrees == Int32(rotation.rawValue))
    }
    #expect(DisplayRotation.allCases.count == 4)
  }

  /// A display reporting something that is not a right angle is one this
  /// feature declines to describe. Rounding 45 to 90 would put a rotation on
  /// screen that the display is not in, and offer a revert to an angle it was
  /// never at.
  @Test func anAngleThatIsNotARightAngleIsNotRounded() {
    for degrees in [45.0, 1.0, 89.0, 91.0, 271.0, 359.0, -90.0, 360.0, 450.0] {
      #expect(DisplayRotation(degrees: degrees) == nil, "\(degrees) should not resolve")
    }
  }

  /// `CGDisplayRotation` returns a `Double`, so the tolerance exists for float
  /// representation — not as a snapping window.
  @Test func floatingPointNoiseAroundARightAngleStillResolves() {
    #expect(DisplayRotation(degrees: 90.0000001) == .ninety)
    #expect(DisplayRotation(degrees: 269.9999999) == .twoSeventy)
    #expect(DisplayRotation(degrees: 90.5) == nil)
    #expect(DisplayRotation(degrees: .nan) == nil)
    #expect(DisplayRotation(degrees: .infinity) == nil)
  }

  /// Measured: the MAG went 3440×1440 → 1440×3440 at 90 and back at 180.
  @Test func onlyTheQuarterTurnsExchangeWidthAndHeight() {
    #expect(DisplayRotation.standard.swapsAxes == false)
    #expect(DisplayRotation.ninety.swapsAxes)
    #expect(DisplayRotation.oneEighty.swapsAxes == false)
    #expect(DisplayRotation.twoSeventy.swapsAxes)
  }

  // MARK: - The policy

  @Test func aRotationToADifferentAngleIsApprovedAndCarriesBothEnds() {
    let decision = RotationPolicy.decide(
      display: 2, to: .ninety, in: [display(1), display(2)],
      currentRotation: .standard, isSupported: true, isSynthesizedSize: false
    )
    #expect(decision == .rotate(RotationRequest(display: 2, from: .standard, to: .ninety)))
  }

  /// No countdown opens for a no-op. A 30-second timer over a change that
  /// is not happening is a bug, not a courtesy — and its revert would "restore"
  /// an angle nothing moved away from.
  @Test func rotatingToTheAngleItIsAlreadyAtIsRefusedRatherThanApplied() {
    let decision = RotationPolicy.decide(
      display: 2, to: .twoSeventy, in: [display(2)],
      currentRotation: .twoSeventy, isSupported: true, isSynthesizedSize: false
    )
    #expect(decision == .refused(.unchanged(.twoSeventy)))
  }

  @Test func aDisplayThatIsNotInTheListIsRefusedAsGone() {
    let decision = RotationPolicy.decide(
      display: 9, to: .ninety, in: [display(1), display(2)],
      currentRotation: .standard, isSupported: true, isSynthesizedSize: false
    )
    #expect(decision == .refused(.displayGone))
  }

  /// The refusal the policy had the flag for and never read: a slave's pixels
  /// come from its master, and the request looks ordinary right up to the apply.
  ///
  /// The MASTER of the same set is untouched, which is the half that makes this
  /// a carve-out rather than a blanket "anything mirrored is off limits": it
  /// owns the framebuffer, so its glass is its own to turn.
  @Test func aMirrorSlaveIsRefusedWhileItsMasterIsStillRotatable() {
    let set = [display(1), display(2, mirroring: 1)]
    #expect(RotationPolicy.decide(
      display: 2, to: .ninety, in: set, currentRotation: .standard,
      isSupported: true, isSynthesizedSize: false
    ) == .refused(.mirrored))
    #expect(RotationPolicy.decide(
      display: 1, to: .ninety, in: set, currentRotation: .standard,
      isSupported: true, isSynthesizedSize: false
    ) == .rotate(RotationRequest(display: 1, from: .standard, to: .ninety)))
    // And a standalone display is unchanged by the new guard.
    #expect(RotationPolicy.decide(
      display: 2, to: .ninety, in: [display(1), display(2)],
      currentRotation: .standard, isSupported: true, isSynthesizedSize: false
    ) == .rotate(RotationRequest(display: 2, from: .standard, to: .ninety)))
  }

  /// A display running a size this app renders sets the raw mirroring flag, so
  /// without its own arm it would be refused as mirroring and told to look for a
  /// display it is showing. Same set membership, two different answers, decided
  /// by the flag the caller states.
  @Test func aDisplayShowingARenderedSizeIsRefusedForThatRatherThanForMirroring() {
    let set = [display(1), display(2, mirroring: 1)]
    #expect(RotationPolicy.decide(
      display: 2, to: .ninety, in: set, currentRotation: .standard,
      isSupported: true, isSynthesizedSize: true
    ) == .refused(.synthesizedSize))
    #expect(RotationPolicy.decide(
      display: 2, to: .ninety, in: set, currentRotation: .standard,
      isSupported: true, isSynthesizedSize: false
    ) == .refused(.mirrored))
  }

  /// A missing current angle reaching the policy: no readable current angle means no honest "from"
  /// to show or to revert to.
  @Test func aDisplayWhoseAngleCannotBeReadIsRefusedAsUnreadable() {
    let decision = RotationPolicy.decide(
      display: 2, to: .ninety, in: [display(2)],
      currentRotation: nil, isSupported: true, isSynthesizedSize: false
    )
    #expect(decision == .refused(.unreadable))
  }

  /// A missing SkyLight symbol is a capability answer, not a crash — and it
  /// outranks every other refusal, since nothing can be attempted at all.
  @Test func withoutTheSymbolEveryRotationIsRefusedAsUnavailable() {
    for current in [DisplayRotation.standard, .ninety] {
      let decision = RotationPolicy.decide(
        display: 2, to: .ninety, in: [display(2)],
        currentRotation: current, isSupported: false, isSynthesizedSize: false
      )
      #expect(decision == .refused(.unavailable))
    }
    // Even for a display that is not there: unavailable is the truthful answer,
    // and "which display" is not a question worth asking of a dead API.
    #expect(RotationPolicy.decide(
      display: 9, to: .ninety, in: [], currentRotation: nil, isSupported: false,
      isSynthesizedSize: false
    ) == .refused(.unavailable))
  }

  // MARK: - The verification the platform makes necessary

  /// An earlier experiment's result, reproduced: the setter can return success and change nothing. The fake
  /// swallows the write the way `SLSSetDisplayRotation(display, 360)` does, so a
  /// caller that trusts the return value is visibly wrong here.
  @Test func aSwallowedRotationIsVisibleInTheReadbackEvenThoughTheCallSucceeded() throws {
    let fake = FakeConfigurator()
    fake.rotations = [2: .standard]
    fake.swallowRotations = true

    // The call itself does NOT throw — that is the whole trap.
    try fake.applyRotation(.ninety, to: 2)
    #expect(fake.appliedRotations.count == 1)
    // ...and the display never moved. Only the readback can tell.
    #expect(fake.rotation(of: 2) == .standard)
  }

  @Test func anHonestRotationLandsAndReadsBack() throws {
    let fake = FakeConfigurator()
    fake.rotations = [2: .standard]

    try fake.applyRotation(.oneEighty, to: 2)
    #expect(fake.rotation(of: 2) == .oneEighty)
    #expect(fake.appliedRotations.map(\.rotation) == [.oneEighty])
  }

  @Test func aFailingRotationThrowsAndLeavesTheDisplayWhereItWas() {
    let fake = FakeConfigurator()
    fake.rotations = [2: .standard]
    fake.failRotationWith = DisplayConfigError(cgErrorCode: 1001)

    #expect(throws: DisplayConfigError(cgErrorCode: 1001)) {
      try fake.applyRotation(.ninety, to: 2)
    }
    #expect(fake.rotation(of: 2) == .standard)
  }
}
