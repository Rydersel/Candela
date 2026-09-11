import CandelaKit
import Foundation
import SwiftUI
import Testing

@Suite("Restore notice actions") @MainActor
struct RestoreNoticeActionsTests {
  /// Under the other notices the button would either do nothing or make the state
  /// permanent.
  @Test func onlyTheStaleFootprintNoticeOffersASave() {
    #expect(RestoreNoticeActions(
      notice: .savedForDifferentGeometry(["a"]), isRestoringLayout: true, isBusy: false, refusedBy: nil
    ).offersSave)

    let withoutARemedy: [ArrangementReapplyNotice] = [
      .ambiguousIdentity(["a"]),
      .setDiffers(missing: ["a"], extra: ["b"]),
      .layoutNoLongerFits([.overlap(1, 2)]),
      .failed(DisplayConfigError(cgErrorCode: 1000)),
    ]
    for notice in withoutARemedy {
      #expect(
        !RestoreNoticeActions(
          notice: notice, isRestoringLayout: true, isBusy: false, refusedBy: nil
        ).offersSave,
        "\(notice) is not a stale record a save replaces")
    }
  }

  /// The save path no-ops with the setting off, so the button could not work.
  @Test func theSaveIsAbsentWhileTheRememberSettingIsOff() {
    #expect(!RestoreNoticeActions(
      notice: .savedForDifferentGeometry(["a"]), isRestoringLayout: false, isBusy: false, refusedBy: nil
    ).offersSave)
  }

  @Test func aBusyDisplayChangeSaysWhyRatherThanGreyingSilently() {
    #expect(RestoreNoticeActions(
      notice: .savedForDifferentGeometry(["a"]), isRestoringLayout: true, isBusy: true, refusedBy: nil
    ).showsBusyCaption)
    #expect(!RestoreNoticeActions(
      notice: .savedForDifferentGeometry(["a"]), isRestoringLayout: true, isBusy: false, refusedBy: nil
    ).showsBusyCaption)
    // Negative control: no caption under a notice that offers no save at all.
    #expect(!RestoreNoticeActions(
      notice: .setDiffers(missing: ["a"], extra: []), isRestoringLayout: true, isBusy: true, refusedBy: nil
    ).showsBusyCaption)
    #expect(!RestoreNoticeActions(
      notice: .savedForDifferentGeometry(["a"]), isRestoringLayout: false, isBusy: true, refusedBy: nil
    ).showsBusyCaption)
  }

  /// The caption is the whole feedback a refused save gets. The report card is not
  /// raised for one: its only button clears the notice, with nothing saved.
  @Test func aRefusedSaveNamesWhoRefusedItUnderTheButton() throws {
    let refused = RestoreNoticeActions(
      notice: .savedForDifferentGeometry(["a"]), isRestoringLayout: true, isBusy: false,
      refusedBy: .rotation
    )
    let caption = try #require(refused.caption)
    #expect(render(caption) == render(ReconfigurationCopy.blocked(by: .rotation)))

    // Nothing to say when nothing refused it and nothing is in flight.
    #expect(RestoreNoticeActions(
      notice: .savedForDifferentGeometry(["a"]), isRestoringLayout: true, isBusy: false,
      refusedBy: nil
    ).caption == nil)
  }

  /// Busy outranks a refusal: an outstanding preview refuses the save AND greys the
  /// button, and the sentence has to match the control on screen.
  @Test func theBusySentenceWinsOverAStaleRefusal() throws {
    let busy = RestoreNoticeActions(
      notice: .savedForDifferentGeometry(["a"]), isRestoringLayout: true, isBusy: true,
      refusedBy: .arrangement
    )
    let caption = try #require(busy.caption)
    #expect(render(caption) == render(ArrangementCopy.saveThisLayoutBusy))
  }

  /// No caption where there is no save, whatever the coordinator last published.
  @Test func noCaptionAppearsUnderANoticeThatOffersNoSave() {
    #expect(RestoreNoticeActions(
      notice: .setDiffers(missing: ["a"], extra: []), isRestoringLayout: true, isBusy: false,
      refusedBy: .mirroring
    ).caption == nil)
    #expect(RestoreNoticeActions(
      notice: .savedForDifferentGeometry(["a"]), isRestoringLayout: false, isBusy: false,
      refusedBy: .mirroring
    ).caption == nil)
  }

  /// `LocalizedStringKey` has no public text, so both sides of a comparison go
  /// through the same reflection dump, as `CopyBuilderTests` does.
  private func render(_ key: LocalizedStringKey) -> String {
    String(describing: key)
  }
}
