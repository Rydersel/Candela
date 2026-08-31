import CoreGraphics
import Foundation
import Testing
@testable import CandelaKit

@Suite("Mirror topology distribution (DT15)")
struct MirrorTopologyStoreTests {
  /// An unwired engine must degrade to TODAY's behaviour, not to a crash and
  /// not to a guess: the default store holds an empty topology whose
  /// `drawableDisplayID` is the identity function.
  @Test func anEmptyStoreIsTheIdentityFunction() {
    let store = MirrorTopologyStore()
    #expect(store.drawableDisplayID(for: 3) == 3)
    #expect(store.topology() == MirrorTopology([]))
  }

  @Test func updatingSwapsTheWholeSampleAtOnce() {
    let store = MirrorTopologyStore()
    store.update(MirrorFixtures.mirroredTrio)
    #expect(store.drawableDisplayID(for: 1) == 2)
    #expect(store.drawableDisplayID(for: 3) == 2)
    #expect(store.topology().masters == [2])

    store.update(MirrorFixtures.unmirroredPair)
    #expect(store.drawableDisplayID(for: 1) == 1)
    #expect(store.topology().masters.isEmpty)
  }

  /// The store hands out a VALUE. A caller that read the topology before a
  /// mirror engaged keeps reasoning about the instant it read, rather than
  /// about a half-updated one.
  @Test func aReadTopologyIsASnapshotAndDoesNotChangeUnderTheReader() {
    let store = MirrorTopologyStore(MirrorFixtures.unmirroredPair)
    let held = store.topology()
    store.update(MirrorFixtures.mirroredTrio)
    #expect(held == MirrorFixtures.unmirroredPair)
    #expect(store.topology() == MirrorFixtures.mirroredTrio)
  }

  /// A master unknown to the sample is handed back unchanged rather than resolved
  /// to something invented: the store adds no judgement of its own on top of
  /// `MirrorTopology.drawableDisplayID(for:)`.
  @Test func anIDAbsentFromTheSampleIsHandedBackUnchanged() {
    let store = MirrorTopologyStore(MirrorFixtures.mirroredTrio)
    #expect(store.drawableDisplayID(for: 99) == 99)
    #expect(store.drawableDisplayID(for: 2) == 2)
  }

  /// Concurrent readers and a writer, because the whole reason this is a lock
  /// and not an actor is that its readers cannot await. Run under
  /// `--sanitize=thread` at least once.
  @Test func concurrentReadsAndWritesDoNotTear() async {
    let store = MirrorTopologyStore(MirrorFixtures.unmirroredPair)
    await withTaskGroup(of: Void.self) { group in
      for _ in 0 ..< 8 {
        group.addTask { for _ in 0 ..< 200 { _ = store.drawableDisplayID(for: 1) } }
      }
      group.addTask {
        for i in 0 ..< 200 {
          store.update(i.isMultiple(of: 2) ? MirrorFixtures.mirroredTrio : MirrorFixtures.unmirroredPair)
        }
      }
    }
    // The assertion is that nothing crashed or tripped the sanitizer; the final
    // value is whichever write landed last and is deliberately not asserted.
    #expect(store.topology().displays.count == 2 || store.topology().displays.count == 3)
  }

  /// The islands are handed the PROTOCOL, not the class, so a double substitutes
  /// for the real store without either side changing.
  @Test func theProtocolIsWhatCallersDependOn() {
    let provider: any MirrorTopologyProviding = MirrorTopologyStore(MirrorFixtures.mirroredTrio)
    #expect(provider.drawableDisplayID(for: 1) == 2)
    #expect(provider.topology() == MirrorFixtures.mirroredTrio)
  }
}
