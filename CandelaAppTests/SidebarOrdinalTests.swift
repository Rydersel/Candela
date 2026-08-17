import Testing

// The sidebar's shared-identity ordinals, over the seam the rows themselves
// use. The shape under test is the one that crashed on the rig: a settings
// reset rebuilt the sidebar while the display list shrank, and a row read the
// list with a position captured against the longer list it was built from.
@Suite("Sidebar ordinals")
struct SidebarOrdinalTests {
  @Test func uniqueKeysAreNotNumbered() {
    #expect(sidebarDisplayOrdinals(keys: ["mag", "dell"]) == [nil, nil])
  }

  @Test func duplicateKeysAreNumberedInListOrder() {
    #expect(sidebarDisplayOrdinals(keys: ["twin", "dell", "twin"]) == [1, nil, 2])
    #expect(sidebarDisplayOrdinals(keys: ["twin", "twin", "twin"]) == [1, 2, 3])
  }

  @Test func twoSharedKeysAreNumberedIndependently() {
    #expect(sidebarDisplayOrdinals(keys: ["a", "b", "a", "b", "c"]) == [1, 1, 2, 2, nil])
  }

  @Test func anEmptyListDerivesNothing() {
    #expect(sidebarDisplayOrdinals(keys: []) == [])
    #expect(sidebarOrdinal(at: 0, in: []) == nil)
  }

  @Test func theAnswerIsAlwaysAsLongAsTheInput() {
    // The invariant the whole shape rests on: every row built from a snapshot
    // has an entry, so no row ever has to go looking for its number.
    for count in 0...5 {
      let keys = (0..<count).map { _ in "twin" }
      #expect(sidebarDisplayOrdinals(keys: keys).count == count)
    }
  }

  @Test func aPositionPastTheEndAnswersNilInsteadOfTrapping() {
    let ordinals = sidebarDisplayOrdinals(keys: ["twin", "twin"])
    #expect(sidebarOrdinal(at: 0, in: ordinals) == 1)
    #expect(sidebarOrdinal(at: 1, in: ordinals) == 2)
    #expect(sidebarOrdinal(at: 2, in: ordinals) == nil)
    #expect(sidebarOrdinal(at: 99, in: ordinals) == nil)
  }

  @Test func aNegativePositionAnswersNilInsteadOfTrapping() {
    let ordinals = sidebarDisplayOrdinals(keys: ["twin", "twin"])
    #expect(sidebarOrdinal(at: -1, in: ordinals) == nil)
  }

  @Test func theListShrinkingUnderTheRowsCostsOrdinalsAndNotACrash() {
    // The reset shape, run synchronously: rows were laid out against three
    // attached displays, the reset emptied the list down to one, and the rows
    // read again with the positions they already held.
    let beforeReset = ["twin", "twin", "dell"]
    let afterReset = ["twin"]
    let positions = beforeReset.indices

    let ordinals = sidebarDisplayOrdinals(keys: afterReset)
    let readBack = positions.map { sidebarOrdinal(at: $0, in: ordinals) }

    // The one surviving row is no longer shared, so it loses its number; the
    // two departed rows answer for a row that is not there any more.
    #expect(readBack == [nil, nil, nil])
  }

  @Test func aShrinkThatLeavesTheSharedPairIntactKeepsItsNumbers() {
    let ordinals = sidebarDisplayOrdinals(keys: ["twin", "twin"])
    let readBack = (0..<3).map { sidebarOrdinal(at: $0, in: ordinals) }
    #expect(readBack == [1, 2, nil])
  }

  @Test func theListGrowingUnderTheRowsIsAnswerableToo() {
    // The other direction of the same race: a hotplug lands between the
    // derivation and the read, so a row's old position still describes a row,
    // just not necessarily the one it was drawn for. It answers a number
    // rather than trapping, which is all the sidebar needs of it.
    let ordinals = sidebarDisplayOrdinals(keys: ["twin", "dell", "twin"])
    #expect(sidebarOrdinal(at: 2, in: ordinals) == 2)
  }
}
