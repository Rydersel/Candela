import Testing

@testable import CandelaKit

@Suite("Slider snapping and percent readout (fork SliderHandler)")
struct SliderSnapTests {
  @Test func stopsAreTheQuarterPositions() {
    // The fork's caption promises 0/25/50/75/100 while hardcoding `25` in one
    // place and `5` in another. One constant here.
    #expect(SliderSnap.stops == [0, 0.25, 0.5, 0.75, 1])
    #expect(SliderSnap.tolerance == 0.03)  // fork: within 3 percentage points
  }

  @Test func snapsToTheNearestStopInsideTheWindow() {
    #expect(SliderSnap.snapped(0.02, enabled: true) == 0)
    #expect(SliderSnap.snapped(0.27, enabled: true) == 0.25)
    #expect(SliderSnap.snapped(0.235, enabled: true) == 0.25)
    #expect(SliderSnap.snapped(0.52, enabled: true) == 0.5)
    #expect(SliderSnap.snapped(0.74, enabled: true) == 0.75)
    #expect(SliderSnap.snapped(0.99, enabled: true) == 1)
  }

  @Test func leavesValuesOutsideTheWindowAlone() {
    // 0.28/0.22 are one hundredth clear of the window: the boundary itself is
    // not exactly representable in binary, so it is deliberately not asserted.
    #expect(SliderSnap.snapped(0.29, enabled: true) == 0.29)
    #expect(SliderSnap.snapped(0.21, enabled: true) == 0.21)
    #expect(SliderSnap.snapped(0.375, enabled: true) == 0.375)
  }

  @Test func exactStopsAreUnchangedAndIdempotent() {
    for stop in SliderSnap.stops {
      #expect(SliderSnap.snapped(stop, enabled: true) == stop)
      #expect(SliderSnap.snapped(SliderSnap.snapped(stop, enabled: true), enabled: true) == stop)
    }
  }

  @Test func disabledPassesTheValueThroughUntouched() {
    #expect(SliderSnap.snapped(0.27, enabled: false) == 0.27)
    #expect(SliderSnap.snapped(0.02, enabled: false) == 0.02)
  }

  @Test func alwaysClampsToTheLegalRangeInBothModes() {
    // A drag that overshoots the capsule must still land on a writable value.
    // The controllers take 0…1 and this is the only place the drag is bounded.
    #expect(SliderSnap.snapped(1.4, enabled: true) == 1)
    #expect(SliderSnap.snapped(-0.3, enabled: true) == 0)
    #expect(SliderSnap.snapped(1.4, enabled: false) == 1)
    #expect(SliderSnap.snapped(-0.3, enabled: false) == 0)
  }

  @Test func clampHappensBeforeSnappingSoAnOvershootCannotEscapeTheRange() {
    // Pins the ordering claim in `snapped`'s doc comment. 1.02 is inside the
    // `1` stop's window either way, but -0.5 is 0.5 from every stop, so
    // snap-then-clamp returns it unsnapped and needs a clamp that does not exist.
    #expect(SliderSnap.snapped(1.02, enabled: true) == 1)
    #expect(SliderSnap.snapped(-0.5, enabled: true) == 0)
    #expect(SliderSnap.snapped(-0.5, enabled: true, stops: SliderSnap.stopsWithoutZero) == 0)
  }

  @Test func theZeroFreeStopSetNeverSnapsAVolumeDragIntoAHardwareMute() {
    // `DDCValueController.apply` treats volume 0 as a MUTE event
    // (VCP 0x8D = 1 when enableMuteUnmute). A 3-point capture window on
    // the `0` stop would turn the bottom 3 % of every volume drag into a
    // persistent hardware mute, so volume rows use this stop set.
    #expect(SliderSnap.stopsWithoutZero == [0.25, 0.5, 0.75, 1])
    #expect(SliderSnap.snapped(0.02, enabled: true, stops: SliderSnap.stopsWithoutZero) == 0.02)
    #expect(SliderSnap.snapped(0.01, enabled: true, stops: SliderSnap.stopsWithoutZero) == 0.01)
    // Deliberately reaching 0 still mutes: the user has to go there.
    #expect(SliderSnap.snapped(0, enabled: true, stops: SliderSnap.stopsWithoutZero) == 0)
    // Every other stop still snaps.
    #expect(SliderSnap.snapped(0.27, enabled: true, stops: SliderSnap.stopsWithoutZero) == 0.25)
    #expect(SliderSnap.snapped(0.99, enabled: true, stops: SliderSnap.stopsWithoutZero) == 1)
  }

  // MARK: - Stepping (the keyboard and VoiceOver route)

  @Test func steppingLandsOnRoundMultiplesWhereverTheDragLeftTheValue() {
    // A drag can stop anywhere. The stepping route puts the value back on the
    // grid rather than carrying the offset along forever, so the readout shows
    // 60% and 65% instead of 57% and 67%.
    #expect(SliderSnap.stepped(from: 0.625, up: false, step: 0.05, toStops: false) == 0.6)
    #expect(SliderSnap.stepped(from: 0.625, up: true, step: 0.05, toStops: false) == 0.65)
    // Already on the grid: strictly the next point, never a no-op.
    #expect(SliderSnap.stepped(from: 0.6, up: true, step: 0.05, toStops: false) == 0.65)
    #expect(SliderSnap.stepped(from: 0.6, up: false, step: 0.05, toStops: false) == 0.55)
    #expect(SliderSnap.stepped(from: 0.62, up: false, step: 0.01, toStops: false) == 0.61)
  }

  @Test func steppingWithSnappingOnMovesOneWholeStop() {
    // With the snapping pref on a step is 25%, not 5% with an occasional snap.
    // The measured defect was 45/40/35/30 with "Snap to 25% steps" on.
    #expect(SliderSnap.stepped(from: 0.45, up: false, step: 0.05, toStops: true) == 0.25)
    #expect(SliderSnap.stepped(from: 0.45, up: true, step: 0.05, toStops: true) == 0.5)
    #expect(SliderSnap.stepped(from: 0.5, up: true, step: 0.05, toStops: true) == 0.75)
    #expect(SliderSnap.stepped(from: 0.75, up: false, step: 0.05, toStops: true) == 0.5)
  }

  @Test func aDecrementNeverReachesZeroOnAZeroFreeGrid() {
    // The mute-strand rule's fourth clause, and the test that would have caught the hardware defect: on
    // the MAG's volume row a VoiceOver decrement walked 45/40/…/5/0 and wrote
    // VCP 0x8D, muting the display. Decrement is the ONLY way a VoiceOver user
    // can lower the volume, so no sequence of them may land on 0.
    for toStops in [true, false] {
      for step in [0.05, 0.01] {
        for start in [1.0, 0.9532, 0.45, 0.25, 0.13, 0.05, 0.01] {
          var value = start
          for _ in 0..<200 {
            value = SliderSnap.stepped(
              from: value, up: false, step: step,
              toStops: toStops, stops: SliderSnap.stopsWithoutZero
            )
            #expect(value > 0, "reached \(value) from \(start), toStops \(toStops), step \(step)")
          }
        }
      }
    }
  }

  @Test func aDecrementLeavesAValueAlreadyBelowTheGridWhereItIs() {
    // A muted row reads as 0 and a drag can leave a volume at 2%. Pushing
    // either UP to the floor would unmute the display as a side effect of
    // asking for LESS, which is the same class of accident the mute-strand rule exists for.
    for toStops in [true, false] {
      for start in [0.0, 0.02] {
        #expect(
          SliderSnap.stepped(
            from: start, up: false, step: 0.05,
            toStops: toStops, stops: SliderSnap.stopsWithoutZero
          ) == start
        )
      }
    }
  }

  @Test func anIncrementStillRecoversFromZero() {
    // The other half of the mute-strand rule's third clause: the row that reads 0 while muted has to be able
    // to climb back out from the same route that got stuck at the floor.
    #expect(
      SliderSnap.stepped(
        from: 0, up: true, step: 0.05, toStops: false, stops: SliderSnap.stopsWithoutZero
      ) == 0.05
    )
    #expect(
      SliderSnap.stepped(
        from: 0, up: true, step: 0.05, toStops: true, stops: SliderSnap.stopsWithoutZero
      ) == 0.25
    )
  }

  @Test func zeroStaysReachableWhereItIsAValueRatherThanAStateChange() {
    // Brightness and contrast keep the `0` stop: nothing downstream reads their
    // 0 as a command. Only the zero-free grid is fenced.
    #expect(SliderSnap.stepped(from: 0.05, up: false, step: 0.05, toStops: false) == 0)
    #expect(SliderSnap.stepped(from: 0.25, up: false, step: 0.05, toStops: true) == 0)
  }

  @Test func steppingStaysInsideTheLegalRange() {
    // The controllers downstream take 0…1, and the top and bottom of the travel
    // are where a repeat-held arrow key spends its time.
    #expect(SliderSnap.stepped(from: 1, up: true, step: 0.05, toStops: false) == 1)
    #expect(SliderSnap.stepped(from: 1, up: true, step: 0.05, toStops: true) == 1)
    #expect(SliderSnap.stepped(from: 0, up: false, step: 0.05, toStops: false) == 0)
    #expect(SliderSnap.stepped(from: 0.98, up: true, step: 0.05, toStops: false) == 1)
  }

  @Test func percentTextIsWholePercentAndClamped() {
    #expect(SliderSnap.percentText(0) == "0%")
    #expect(SliderSnap.percentText(1) == "100%")
    #expect(SliderSnap.percentText(0.465) == "47%")  // rounds, never truncates
    #expect(SliderSnap.percentText(0.004) == "0%")
    #expect(SliderSnap.percentText(1.2) == "100%")
    #expect(SliderSnap.percentText(-0.5) == "0%")
  }
}
