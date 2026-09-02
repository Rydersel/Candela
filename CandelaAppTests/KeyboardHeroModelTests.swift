import CandelaKit
import Testing

// Row-model coverage for the Keyboard hub: the keycap hero's cluster
// annotations and lighting, and the Targeting & Precision chevron preview.
// Pure functions over enum inputs, so every mode is enumerable.
@Suite("Keyboard hero model")
struct KeyboardHeroModelTests {

  // MARK: - Lighting follows KeyModePolicy, never a local copy

  @Test func lightingAgreesWithWatchesMediaKeysForEveryMode() {
    for mode in KeyMode.allCases {
      #expect(KeyboardHeroModel.brightnessLit(mode: mode) == KeyModePolicy.watchesMediaKeys(mode))
      #expect(KeyboardHeroModel.volumeLit(mode: mode) == KeyModePolicy.watchesMediaKeys(mode))
    }
  }

  @Test func alternateKeysLightOnlyWhenWatchedAndAccepted() {
    #expect(KeyboardHeroModel.alternateLit(brightnessMode: .media, accepted: true))
    #expect(KeyboardHeroModel.alternateLit(brightnessMode: .both, accepted: true))
    #expect(!KeyboardHeroModel.alternateLit(brightnessMode: .media, accepted: false))
    // Custom-only leaves the physical keys to macOS, so acceptance alone must
    // never light them.
    #expect(!KeyboardHeroModel.alternateLit(brightnessMode: .custom, accepted: true))
    #expect(!KeyboardHeroModel.alternateLit(brightnessMode: .disabled, accepted: true))
  }

  // MARK: - Annotations say what the lighting shows (colour is never alone)

  // Sentences with a verb: the line states what the keys are doing right now,
  // and a noun phrase reading like a feature caption is the defect it replaced.
  @Test func brightnessLineNamesModeAndTarget() {
    #expect(
      KeyboardHeroModel.brightnessLine(mode: .media, target: .mouse)
        == "Media keys act on the display under the pointer")
    #expect(
      KeyboardHeroModel.brightnessLine(mode: .both, target: .allScreens)
        == "Media keys and shortcuts act on every display")
    #expect(
      KeyboardHeroModel.brightnessLine(mode: .media, target: .focusInsteadOfMouse)
        == "Media keys act on the display with the active window")
    #expect(
      KeyboardHeroModel.brightnessLine(mode: .custom, target: .mouse)
        == "Custom shortcuts only; the keys go to macOS")
    #expect(
      KeyboardHeroModel.brightnessLine(mode: .disabled, target: .mouse)
        == "Off; the keys go to macOS")
  }

  @Test func volumeLineNamesModeAndTarget() {
    // The audio-matching target carries its own verb: keys FOLLOW the output
    // device rather than acting on it.
    #expect(
      KeyboardHeroModel.volumeLine(mode: .media, target: .audioDeviceNameMatching)
        == "Media keys follow the audio output device")
    #expect(
      KeyboardHeroModel.volumeLine(mode: .both, target: .mouse)
        == "Media keys and shortcuts act on the display under the pointer")
    #expect(
      KeyboardHeroModel.volumeLine(mode: .media, target: .allScreens)
        == "Media keys act on every display")
    #expect(
      KeyboardHeroModel.volumeLine(mode: .disabled, target: .mouse)
        == "Off; the keys go to macOS")
  }

  @Test func alternateLineMatchesItsLighting() {
    for mode in KeyMode.allCases {
      for accepted in [true, false] {
        let lit = KeyboardHeroModel.alternateLit(brightnessMode: mode, accepted: accepted)
        let line = KeyboardHeroModel.alternateLine(brightnessMode: mode, accepted: accepted)
        #expect(line == (lit ? "Treated as brightness keys" : "Left to macOS"))
      }
    }
  }

  // MARK: - The good-news line never competes with the warning

  @Test func accessibilityLineShowsOnlyWhenGrantedAndAMediaModeIsActive() {
    #expect(
      KeyboardHeroModel.showsAccessibilityLine(granted: true, brightnessMode: .media, volumeMode: .custom))
    #expect(
      KeyboardHeroModel.showsAccessibilityLine(granted: true, brightnessMode: .custom, volumeMode: .both))
    // All-custom rigs use Carbon hotkeys; there is no tap to be good news about.
    #expect(
      !KeyboardHeroModel.showsAccessibilityLine(granted: true, brightnessMode: .custom, volumeMode: .custom))
    // Missing grant is the warning section's voice, never this line's.
    #expect(
      !KeyboardHeroModel.showsAccessibilityLine(granted: false, brightnessMode: .media, volumeMode: .media))
  }

  // MARK: - Chevron previews

  @Test func targetingPreviewSummarizesTargetAndSteps() {
    #expect(
      KeyboardHeroModel.targetingPreview(
        brightnessMode: .media, volumeMode: .media,
        brightnessTarget: .mouse, volumeTarget: .mouse,
        fineBrightness: false, fineVolume: false)
        == "Under the pointer · normal steps")
    #expect(
      KeyboardHeroModel.targetingPreview(
        brightnessMode: .both, volumeMode: .both,
        brightnessTarget: .allScreens, volumeTarget: .allScreens,
        fineBrightness: true, fineVolume: true)
        == "Every display · fine steps")
    #expect(
      KeyboardHeroModel.targetingPreview(
        brightnessMode: .media, volumeMode: .media,
        brightnessTarget: .focusInsteadOfMouse, volumeTarget: .mouse,
        fineBrightness: true, fineVolume: false)
        == "Active window · mixed step sizes")
  }

  @Test func targetingPreviewSaysKeysOffOnlyWhenBOTHFamiliesAreDisabled() {
    #expect(
      KeyboardHeroModel.targetingPreview(
        brightnessMode: .disabled, volumeMode: .disabled,
        brightnessTarget: .mouse, volumeTarget: .mouse,
        fineBrightness: false, fineVolume: false)
        == "Keys off")
  }

  /// The row previewed "Keys off" over a page whose volume picker and volume
  /// step switch were both live, which is the defect this pins.
  @Test func targetingPreviewSpeaksForVolumeWhenBrightnessAloneIsDisabled() {
    let preview = KeyboardHeroModel.targetingPreview(
      brightnessMode: .disabled, volumeMode: .media,
      brightnessTarget: .focusInsteadOfMouse, volumeTarget: .audioDeviceNameMatching,
      fineBrightness: true, fineVolume: false)
    #expect(preview != "Keys off")
    // The brightness target and its fine switch are greyed on that page, so
    // neither may reach the preview.
    #expect(preview == "Matching the audio device · normal steps")
  }

  @Test func targetingPreviewIgnoresADisabledFamilysStepSize() {
    #expect(
      KeyboardHeroModel.targetingPreview(
        brightnessMode: .custom, volumeMode: .disabled,
        brightnessTarget: .allScreens, volumeTarget: .mouse,
        fineBrightness: true, fineVolume: false)
        == "Every display · fine steps")
  }

  // MARK: - House copy rules hold mechanically

  @Test func noAnnotationContainsAnEmDashOrThePWord() {
    var lines: [String] = [KeyboardHeroModel.modifiersPreview]
    for mode in KeyMode.allCases {
      for target in MultiKeyboardBrightness.allCases {
        lines.append(KeyboardHeroModel.brightnessLine(mode: mode, target: target))
        for volumeMode in KeyMode.allCases {
          for volumeTarget in MultiKeyboardVolume.allCases {
            for fineB in [true, false] {
              for fineV in [true, false] {
                lines.append(
                  KeyboardHeroModel.targetingPreview(
                    brightnessMode: mode, volumeMode: volumeMode,
                    brightnessTarget: target, volumeTarget: volumeTarget,
                    fineBrightness: fineB, fineVolume: fineV))
              }
            }
          }
        }
      }
      for target in MultiKeyboardVolume.allCases {
        lines.append(KeyboardHeroModel.volumeLine(mode: mode, target: target))
      }
      for accepted in [true, false] {
        lines.append(KeyboardHeroModel.alternateLine(brightnessMode: mode, accepted: accepted))
      }
    }
    for line in lines {
      #expect(!line.contains("\u{2014}"), "em dash in \(line)")
      // Hardware is a display, never a panel, in UI copy.
      #expect(!line.lowercased().contains("panel"), "'panel' in \(line)")
    }
  }
}
