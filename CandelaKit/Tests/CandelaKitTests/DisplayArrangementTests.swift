import CoreGraphics
import Foundation
import Testing
@testable import CandelaKit

@Suite("Display arrangement")
struct DisplayArrangementTests {
  private func tile(
    _ id: CGDirectDisplayID,
    _ rect: DisplayRect,
    mirroredIDs: [CGDirectDisplayID] = []
  ) -> ArrangementTile {
    ArrangementTile(
      id: id,
      identity: .init(vendor: id, model: id, serial: id, isBuiltIn: false),
      name: "Display \(id)",
      rect: rect,
      mirroredIDs: mirroredIDs
    )
  }

  @Test func tileOrderDoesNotAffectEquality() {
    let a = ArrangementTile(id: 1, identity: .init(vendor: 1, model: 1, serial: 1, isBuiltIn: false),
                            name: "A", rect: DisplayRect(x: 0, y: 0, width: 100, height: 100), mirroredIDs: [])
    let b = ArrangementTile(id: 2, identity: .init(vendor: 2, model: 2, serial: 2, isBuiltIn: false),
                            name: "B", rect: DisplayRect(x: 100, y: 0, width: 100, height: 100), mirroredIDs: [])
    #expect(DisplayArrangement(tiles: [a, b]) == DisplayArrangement(tiles: [b, a]))
  }

  @Test func mainDisplayIsTheTileAtTheOrigin() {
    let arrangement = DisplayArrangement(tiles: [
      tile(7, DisplayRect(x: -1440, y: 0, width: 1440, height: 900)),
      tile(3, DisplayRect(x: 0, y: 0, width: 3440, height: 1440)),
    ])
    #expect(arrangement.mainDisplayID == 3)
  }

  @Test func anArrangementWithNoTileAtTheOriginHasNoMain() {
    let arrangement = DisplayArrangement(tiles: [
      tile(1, DisplayRect(x: 10, y: 0, width: 100, height: 100)),
      tile(2, DisplayRect(x: 110, y: 0, width: 100, height: 100)),
    ])
    #expect(arrangement.mainDisplayID == nil)
  }

  @Test func makingMainIsAPureTranslation() {
    // THE property: "make main" must never rearrange anything.
    let arrangement = DisplayArrangement(tiles: [
      tile(1, DisplayRect(x: 0, y: 0, width: 3440, height: 1440)),
      tile(2, DisplayRect(x: -1470, y: 200, width: 1470, height: 956)),
      tile(3, DisplayRect(x: 3440, y: -300, width: 1200, height: 1920)),
    ])
    let after = arrangement.makingMain(3)

    for lhs in arrangement.tiles {
      for rhs in arrangement.tiles {
        guard let movedLHS = after.tile(lhs.id), let movedRHS = after.tile(rhs.id) else {
          Issue.record("tile disappeared")
          return
        }
        #expect(movedRHS.rect.x - movedLHS.rect.x == rhs.rect.x - lhs.rect.x)
        #expect(movedRHS.rect.y - movedLHS.rect.y == rhs.rect.y - lhs.rect.y)
      }
    }
    // Sizes and identity survive the translation too.
    for original in arrangement.tiles {
      let moved = after.tile(original.id)
      #expect(moved?.rect.width == original.rect.width)
      #expect(moved?.rect.height == original.rect.height)
      #expect(moved?.identity == original.identity)
      #expect(moved?.name == original.name)
    }
  }

  @Test func makingMainPutsThatTileAtTheOrigin() {
    let arrangement = DisplayArrangement(tiles: [
      tile(1, DisplayRect(x: 0, y: 0, width: 3440, height: 1440)),
      tile(2, DisplayRect(x: -1470, y: 200, width: 1470, height: 956)),
    ])
    let after = arrangement.makingMain(2)
    #expect(after.tile(2)?.rect.origin == .zero)
    #expect(after.mainDisplayID == 2)
  }

  @Test func makingMainOnAnUnknownIDChangesNothing() {
    let arrangement = DisplayArrangement(tiles: [tile(1, DisplayRect(x: 0, y: 0, width: 100, height: 100))])
    #expect(arrangement.makingMain(99) == arrangement)
  }

  @Test func movingChangesOnlyTheNamedTile() {
    let arrangement = DisplayArrangement(tiles: [
      tile(1, DisplayRect(x: 0, y: 0, width: 100, height: 100)),
      tile(2, DisplayRect(x: 100, y: 0, width: 100, height: 100)),
      tile(3, DisplayRect(x: 200, y: 0, width: 100, height: 100)),
    ])
    let after = arrangement.moving(2, to: DisplayPoint(x: 0, y: 100))
    #expect(after.tile(2)?.rect == DisplayRect(x: 0, y: 100, width: 100, height: 100))
    #expect(after.tile(1)?.rect == arrangement.tile(1)?.rect)
    #expect(after.tile(3)?.rect == arrangement.tile(3)?.rect)
  }

  @Test func movingAnUnknownIDChangesNothing() {
    let arrangement = DisplayArrangement(tiles: [tile(1, DisplayRect(x: 0, y: 0, width: 100, height: 100))])
    #expect(arrangement.moving(99, to: DisplayPoint(x: 50, y: 50)) == arrangement)
  }

  @Test func boundsSpanEveryTile() {
    let rects = [
      DisplayRect(x: 0, y: 0, width: 3440, height: 1440),
      DisplayRect(x: -1470, y: 200, width: 1470, height: 956),
      DisplayRect(x: 3440, y: -300, width: 1200, height: 1920),
    ]
    let arrangement = DisplayArrangement(tiles: rects.enumerated().map { tile(CGDirectDisplayID($0.offset + 1), $0.element) })
    #expect(arrangement.bounds == DisplayRect.union(rects))
    #expect(arrangement.bounds == DisplayRect(x: -1470, y: -300, width: 6110, height: 1920))
  }

  @Test func anEmptyArrangementHasEmptyBoundsAndNoMain() {
    let arrangement = DisplayArrangement(tiles: [])
    #expect(arrangement.isEmpty)
    #expect(arrangement.bounds.isEmpty)
    #expect(arrangement.bounds == DisplayRect(x: 0, y: 0, width: 0, height: 0))
    #expect(arrangement.mainDisplayID == nil)
    #expect(arrangement.tile(1) == nil)
    #expect(arrangement.translated(dx: 10, dy: 10).isEmpty)
    #expect(arrangement.makingMain(1).isEmpty)
  }

  @Test func translatingShiftsEveryTile() {
    let arrangement = DisplayArrangement(tiles: [
      tile(1, DisplayRect(x: 0, y: 0, width: 100, height: 100)),
      tile(2, DisplayRect(x: 100, y: 0, width: 100, height: 100)),
    ])
    let after = arrangement.translated(dx: -5, dy: 7)
    #expect(after.tile(1)?.rect == DisplayRect(x: -5, y: 7, width: 100, height: 100))
    #expect(after.tile(2)?.rect == DisplayRect(x: 95, y: 7, width: 100, height: 100))
  }

  @Test func tilesAreSortedByID() {
    let arrangement = DisplayArrangement(tiles: [
      tile(9, DisplayRect(x: 0, y: 0, width: 10, height: 10)),
      tile(2, DisplayRect(x: 10, y: 0, width: 10, height: 10)),
      tile(5, DisplayRect(x: 20, y: 0, width: 10, height: 10)),
    ])
    #expect(arrangement.tiles.map(\.id) == [2, 5, 9])
  }
}
