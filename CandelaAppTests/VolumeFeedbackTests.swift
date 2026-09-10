import CandelaKit
import CoreGraphics
import Foundation
import Testing

/// WHICH releases play the volume-feedback blip. The router answers what a key
/// event is, never whether it makes a sound, so a release under Option still
/// routes the feedback trigger; only the executor knows the preceding key-down
/// opened Sound settings instead of stepping.
///
/// The executor's two injection points exist for this suite alone: counting
/// plays instead of sounding the blip, and recording the deep link instead of
/// opening System Settings on the machine running the suite.
@Suite("Volume feedback sound", .timeLimit(.minutes(1)))
@MainActor
struct VolumeFeedbackTests {
  @Test func aPlainVolumeStepPlaysTheSoundOnRelease() async {
    let rig = await rig()
    rig.executor.execute(.stepVolume(isUp: true, isFine: false))
    rig.executor.execute(.volumeKeyUp)
    #expect(rig.sound.playCount == 1)
  }

  @Test func aReleaseAfterSoundSettingsPlaysNothing() async {
    let rig = await rig()
    rig.executor.execute(.openSoundSettings)
    rig.executor.execute(.volumeKeyUp)
    // The deep link has to have run, or the release is being judged against a
    // case that never fired.
    #expect(rig.opened.urls.count == 1)
    #expect(rig.sound.playCount == 0)
  }

  /// A press at the rail is still a step, and macOS blips there too. Gating on
  /// the value having moved would take that away.
  @Test func theSoundStillPlaysAtTheTopOfTheRange() async {
    let rig = await rig()
    let volume = rig.model.displays.first?.volume
    volume?.setValue(1)
    // Or the step below is an ordinary mid-range one and the rail is untested.
    #expect(volume?.value == 1)
    rig.executor.execute(.stepVolume(isUp: true, isFine: false))
    rig.executor.execute(.volumeKeyUp)
    #expect(rig.sound.playCount == 1)
  }

  /// The app started with the key already held, or a mode change swallowed the
  /// down: nothing armed the release, so nothing sounds.
  @Test func aReleaseWithNoPrecedingDownPlaysNothing() async {
    let rig = await rig()
    rig.executor.execute(.volumeKeyUp)
    #expect(rig.sound.playCount == 0)
  }

  @Test func keyRepeatStillPlaysOncePerEvent() async {
    let rig = await rig()
    for _ in 0..<3 {
      rig.executor.execute(.stepVolume(isUp: true, isFine: false))
    }
    rig.executor.execute(.volumeKeyUp)
    #expect(rig.sound.playCount == 1)
  }

  @Test func aStepAfterSoundSettingsRearmsTheSound() async {
    let rig = await rig()
    rig.executor.execute(.openSoundSettings)
    rig.executor.execute(.stepVolume(isUp: true, isFine: false))
    rig.executor.execute(.volumeKeyUp)
    #expect(rig.sound.playCount == 1)
  }

  // MARK: - Fixture

  private struct Rig {
    let model: AppModel
    let sound: CountingFeedback
    let opened: RecordedURLs
    let executor: KeyActionExecutor
  }

  /// The fixture display must accept volume keys, or every "plays nothing" case
  /// above passes for the wrong reason. Asserted here so no case can skip it.
  private func rig() async -> Rig {
    let discovery = ScriptedDiscovery([
      (id: 91, key: "volume-feedback-test-panel", name: "Feedback Test Panel"),
    ])
    let model = TestFixtures.appModel(discovery: discovery)
    await model.refresh()
    #expect(model.volumeKeyEnabledStates(model.displays).contains { $0.volume.isAvailable })

    let sound = CountingFeedback()
    let opened = RecordedURLs()
    return Rig(
      model: model, sound: sound, opened: opened,
      executor: KeyActionExecutor(
        model: model, hud: nil, feedback: sound, openURL: { opened.urls.append($0) }
      )
    )
  }

  @MainActor private final class CountingFeedback: VolumeFeedbackPlaying {
    private(set) var playCount = 0
    func play() { playCount += 1 }
  }

  @MainActor private final class RecordedURLs {
    var urls: [URL] = []
  }
}
