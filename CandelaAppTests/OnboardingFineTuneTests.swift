import Testing

// What the Finish page offers to fine-tune, derived from what setup learned.
// An item appears only when its fact holds, the list never pads itself, and
// each item opens the pane it names.
@Suite("Onboarding fine-tune")
@MainActor
struct OnboardingFineTuneTests {
  private func items(
    _ enrolledOleds: Int, _ keysOn: Bool, _ grantInPlace: Bool,
    _ externalDisplays: Int, _ arrangedDisplays: Int
  ) -> [OnboardingFineTuneItem] {
    OnboardingFineTuneItem.items(
      enrolledOleds: enrolledOleds, keysOn: keysOn, grantInPlace: grantInPlace,
      externalDisplays: externalDisplays, arrangedDisplays: arrangedDisplays)
  }

  @Test func everyItemWhenEveryFactHolds() {
    #expect(items(1, true, true, 1, 2) == [.oledCare, .shortcuts, .checkup, .arrangement])
  }

  @Test func noDisplayItemsOnBuiltInOnly() {
    #expect(items(0, true, true, 0, 1) == [.shortcuts])
  }

  @Test func noShortcutsWhenKeysDeclined() {
    #expect(!items(1, false, true, 1, 2).contains(.shortcuts))
    // The control: the same rig with the keys on does offer them.
    #expect(items(1, true, true, 1, 2).contains(.shortcuts))
  }

  @Test func noShortcutsWithoutTheGrantInPlace() {
    #expect(!items(1, true, false, 1, 2).contains(.shortcuts))
  }

  /// A single external with the built-in is two displays to arrange; a lone
  /// external in clamshell is one, and has nothing to sit next to.
  @Test func theArrangementNeedsTwoArrangedDisplays() {
    #expect(items(0, false, false, 1, 2).contains(.arrangement))
    #expect(!items(0, false, false, 1, 1).contains(.arrangement))
  }

  @Test func neverMoreThanFour() {
    for oleds in [0, 1, 3] {
      for keys in [false, true] {
        for granted in [false, true] {
          for externals in [0, 1, 4] {
            for arranged in [0, 1, 2, 6] {
              let list = items(oleds, keys, granted, externals, arranged)
              #expect(list.count <= 4)
              #expect(Set(list).count == list.count)
            }
          }
        }
      }
    }
  }

  @Test func eachItemOpensThePaneItNames() {
    #expect(OnboardingFineTuneItem.oledCare.destination == .pane(.oledCare))
    #expect(OnboardingFineTuneItem.shortcuts.destination == .pane(.keyboard))
    #expect(OnboardingFineTuneItem.checkup.destination == .pane(.checkup))
    #expect(OnboardingFineTuneItem.arrangement.destination == .pane(.arrangement))
  }

  @Test func theCopyIsTheApprovedWords() {
    let copy = OnboardingFineTuneItem.allCases.map {
      [$0.title, $0.detail(externalDisplays: 1)]
    }
    #expect(copy == [
      ["Fine-tune OLED care", "Idle dimming and static-region protection"],
      ["Review your key shortcuts", "Brightness, volume and contrast"],
      ["Run a Checkup", "Look for defects and wear on your display"],
      ["Check the arrangement", "How your displays sit next to each other"],
    ])
    #expect(OnboardingFinishCopy.fineTuneHeading == "Next, in Settings")
    for line in copy.joined() + [OnboardingFinishCopy.fineTuneHeading] {
      #expect(!line.contains("\u{2014}"), "\(line)")
    }
  }

  /// Only the Checkup line names displays; two or more externals read plural.
  @Test func theCheckupDetailPluralizesFromTwoExternals() {
    #expect(OnboardingFineTuneItem.checkup.detail(externalDisplays: 2)
      == "Look for defects and wear on your displays")
    #expect(OnboardingFineTuneItem.checkup.detail(externalDisplays: 0)
      == "Look for defects and wear on your display")
    for item in OnboardingFineTuneItem.allCases where item != .checkup {
      #expect(item.detail(externalDisplays: 1) == item.detail(externalDisplays: 3), "\(item)")
    }
  }

  /// The cascade ends past every threshold the page can ask for, so a line or
  /// the list arriving after the page appeared still shows.
  @Test func theRevealEndsPastEveryLaterThreshold() {
    let opened = OnboardingFinishPage.revealSequence(summaryLines: 1, offersFineTune: false)
    #expect(Array(opened.dropLast()) == [1, 2])
    // The fullest page's list threshold: three summary lines, then the list.
    let fullestListThreshold = 3 + 1
    #expect(opened.last! > fullestListThreshold)
    #expect(opened == opened.sorted())
  }

  // MARK: - The Finish summary's keys line

  /// Skipping the keys page turns them off, and Finish must say so plainly
  /// rather than suggest access is merely pending.
  @Test func keysOffSaysSoAndWhereToTurnThemOn() {
    let line = OnboardingFinishCopy.keysLine(keysOn: false, grantInPlace: false)
    #expect(line == .init(text: OnboardingFinishCopy.keysOff, done: false))
    #expect(line.text.contains("Brightness and volume keys are off"))
    #expect(line.text.contains("Settings > Keyboard"))
    #expect(!line.text.contains("\u{2014}"))
    #expect(!line.text.contains("granted later"))
  }

  @Test func grantedKeysReadAsReady() {
    let line = OnboardingFinishCopy.keysLine(keysOn: true, grantInPlace: true)
    #expect(line == .init(text: OnboardingFinishCopy.keysReady, done: true))
  }

  /// Keys still on but no grant: reached with no external attached, where the
  /// keys page never asked.
  @Test func keysOnWithoutTheGrantSayAccessCanComeLater() {
    let line = OnboardingFinishCopy.keysLine(keysOn: true, grantInPlace: false)
    #expect(line == .init(text: OnboardingFinishCopy.keysAwaitAccess, done: false))
  }

  /// Stored modes off and the grant live: the grant changes nothing for the
  /// keys, so the page must not call them ready.
  @Test func keysOffStaysOffWithTheGrant() {
    let line = OnboardingFinishCopy.keysLine(keysOn: false, grantInPlace: true)
    #expect(line.text == OnboardingFinishCopy.keysOff)
  }

  @Test func theSummaryCountsDisplaysAndProtectedOleds() {
    let lines = OnboardingFinishCopy.summary(
      keysOn: true, grantInPlace: true, externalDisplays: 2, protectedOleds: 1)
    #expect(lines.map(\.text) == [
      OnboardingFinishCopy.keysReady,
      "2 displays configured",
      "OLED care is protecting 1 display",
    ])
    #expect(
      OnboardingFinishCopy.summary(
        keysOn: false, grantInPlace: false, externalDisplays: 0, protectedOleds: 0
      ).map(\.text) == [OnboardingFinishCopy.keysOff])
  }
}
