import Testing

@testable import CandelaKit

@Suite("Slider snapping and percent readout (fork SliderHandler, D26-trimmed)")
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
    // A drag that overshoots the capsule must still land on a writable value —
    // the controllers take 0…1 and this is the only place the drag is bounded.
    #expect(SliderSnap.snapped(1.4, enabled: true) == 1)
    #expect(SliderSnap.snapped(-0.3, enabled: true) == 0)
    #expect(SliderSnap.snapped(1.4, enabled: false) == 1)
    #expect(SliderSnap.snapped(-0.3, enabled: false) == 0)
  }

  @Test func clampHappensBeforeSnappingSoAnOvershootCannotEscapeTheRange() {
    // Pins the ordering claim in `snapped`'s doc comment (review lens 4, L5):
    // 1.02 is inside the tolerance window of the `1` stop either way, but
    // -0.5 is 0.5 away from every stop — snap-then-clamp would return it
    // unsnapped and then need a second clamp that does not exist.
    #expect(SliderSnap.snapped(1.02, enabled: true) == 1)
    #expect(SliderSnap.snapped(-0.5, enabled: true) == 0)
    #expect(SliderSnap.snapped(-0.5, enabled: true, stops: SliderSnap.stopsWithoutZero) == 0)
  }

  @Test func theZeroFreeStopSetNeverSnapsAVolumeDragIntoAHardwareMute() {
    // D29 / lens 3 M4: `DDCValueController.apply` treats volume 0 as a MUTE
    // event (VCP 0x8D = 1 when enableMuteUnmute). A 3-point capture window on
    // the `0` stop would turn the bottom 3 % of every volume drag into a
    // persistent hardware mute, so volume rows use this stop set.
    #expect(SliderSnap.stopsWithoutZero == [0.25, 0.5, 0.75, 1])
    #expect(SliderSnap.snapped(0.02, enabled: true, stops: SliderSnap.stopsWithoutZero) == 0.02)
    #expect(SliderSnap.snapped(0.01, enabled: true, stops: SliderSnap.stopsWithoutZero) == 0.01)
    // Deliberately reaching 0 still mutes — the user has to actually go there.
    #expect(SliderSnap.snapped(0, enabled: true, stops: SliderSnap.stopsWithoutZero) == 0)
    // Every other stop still snaps.
    #expect(SliderSnap.snapped(0.27, enabled: true, stops: SliderSnap.stopsWithoutZero) == 0.25)
    #expect(SliderSnap.snapped(0.99, enabled: true, stops: SliderSnap.stopsWithoutZero) == 1)
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
