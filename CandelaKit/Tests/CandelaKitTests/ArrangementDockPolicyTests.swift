import CoreGraphics
import Foundation
import Testing
@testable import CandelaKit

@Suite("Arrangement dock policy")
struct ArrangementDockPolicyTests {
  /// `mirroredIDs` is non-empty on the odd ids, so every property below is
  /// checked against a tile that carries something a move must not drop. AR6:
  /// mirror slaves get no tile at all, and their masters must keep naming them
  /// across a keyboard move — a plan built from a tile that lost them would
  /// silently break the mirror set.
  private func tile(_ id: CGDirectDisplayID, _ rect: DisplayRect) -> ArrangementTile {
    ArrangementTile(
      id: id,
      identity: .init(vendor: id, model: id, serial: id, isBuiltIn: false),
      name: "Display \(id)",
      rect: rect,
      mirroredIDs: id.isMultiple(of: 2) ? [] : [id + 100]
    )
  }

  private func arrangement(_ tiles: [(CGDirectDisplayID, DisplayRect)]) -> DisplayArrangement {
    DisplayArrangement(tiles: tiles.map { tile($0.0, $0.1) })
  }

  /// Small and deliberately varied: equal sizes (where every alignment collapses
  /// onto one candidate), unequal sizes (where they do not), a portrait display,
  /// a vertical stack, a lone display, and a layout that is already broken.
  private var fixtures: [DisplayArrangement] {
    [
      // A lone display.
      arrangement([(1, DisplayRect(x: 0, y: 0, width: 1800, height: 1169))]),
      // Two, side by side, different sizes.
      arrangement([
        (1, DisplayRect(x: 0, y: 0, width: 3440, height: 1440)),
        (2, DisplayRect(x: 3440, y: 0, width: 1470, height: 956)),
      ]),
      // Two, stacked, identical sizes.
      arrangement([
        (1, DisplayRect(x: 0, y: 0, width: 1000, height: 800)),
        (2, DisplayRect(x: 0, y: 800, width: 1000, height: 800)),
      ]),
      // Three in a row — moving the middle one strands the far one.
      arrangement([
        (1, DisplayRect(x: 0, y: 0, width: 1000, height: 800)),
        (2, DisplayRect(x: 1000, y: 0, width: 1000, height: 800)),
        (3, DisplayRect(x: 2000, y: 0, width: 1000, height: 800)),
      ]),
      // An L with a portrait display, and negative coordinates.
      arrangement([
        (1, DisplayRect(x: 0, y: 0, width: 3440, height: 1440)),
        (2, DisplayRect(x: -1200, y: 0, width: 1200, height: 1920)),
        (3, DisplayRect(x: 3440, y: 0, width: 1470, height: 956)),
      ]),
      // Already invalid: display 2 is stranded in a corner-only contact.
      arrangement([
        (1, DisplayRect(x: 0, y: 0, width: 1000, height: 1000)),
        (2, DisplayRect(x: 1000, y: 1000, width: 600, height: 600)),
      ]),
      // Already invalid the other way: display 2 overlaps display 1. Reachable
      // from a System Settings change, and the keyboard has to work from it.
      arrangement([
        (1, DisplayRect(x: 0, y: 0, width: 1000, height: 1000)),
        (2, DisplayRect(x: 800, y: 800, width: 600, height: 600)),
      ]),
    ]
  }

  // MARK: - The three properties the brief requires

  @Test func everyArrowMoveProducesAValidArrangementOrNil() {
    for layout in fixtures {
      for source in layout.tiles {
        for direction in ArrangementDirection.allCases {
          guard let moved = ArrangementDockPolicy.move(source.id, direction, in: layout) else {
            continue
          }
          #expect(
            ArrangementRules.isValid(moved),
            "\(direction) on \(source.id) produced \(ArrangementRules.problems(in: moved))"
          )
          // A move relocates one display. It never adds, drops, resizes or
          // renames one, and it never touches another display's position.
          #expect(moved.tiles.map(\.id) == layout.tiles.map(\.id))
          for other in moved.tiles where other.id != source.id {
            #expect(other == layout.tile(other.id))
          }
          // The moved tile keeps everything except its origin — size, identity,
          // name, and the mirror slaves it is master of (AR6).
          #expect(moved.tile(source.id) == source.moved(to: moved.tile(source.id)!.rect.origin))
        }
      }
    }
  }

  @Test func aMoveAlwaysChangesTheOrigin() {
    for layout in fixtures {
      for source in layout.tiles {
        for direction in ArrangementDirection.allCases {
          guard let moved = ArrangementDockPolicy.move(source.id, direction, in: layout),
                let landed = moved.tile(source.id)?.rect.origin
          else { continue }
          #expect(landed != source.rect.origin)
          // And it changed in the direction that was asked for, strictly. That
          // strictness is also what makes the walk terminate.
          switch direction {
          case .left: #expect(landed.x < source.rect.x)
          case .right: #expect(landed.x > source.rect.x)
          case .up: #expect(landed.y < source.rect.y)
          case .down: #expect(landed.y > source.rect.y)
          }
        }
      }
    }
  }

  @Test func repeatedPressesInOneDirectionTerminate() {
    for layout in fixtures {
      for source in layout.tiles {
        for direction in ArrangementDirection.allCases {
          var current = layout
          var reachedTheEnd = false
          var visited: Set<DisplayPoint> = [source.rect.origin]

          for _ in 0 ..< 50 {
            guard let next = ArrangementDockPolicy.move(source.id, direction, in: current) else {
              reachedTheEnd = true
              break
            }
            guard let origin = next.tile(source.id)?.rect.origin else {
              Issue.record("the moved display vanished")
              break
            }
            // The walk never revisits a position, which is why it cannot loop.
            #expect(!visited.contains(origin))
            visited.insert(origin)
            current = next
          }

          #expect(
            reachedTheEnd,
            "\(direction) on \(source.id) still had somewhere to go after 50 presses"
          )
        }
      }
    }
  }

  // MARK: - Dock positions

  @Test func everyDockPositionIsLegalAndAppearsOnce() {
    for layout in fixtures {
      for source in layout.tiles {
        let positions = ArrangementDockPolicy.dockPositions(for: source.id, in: layout)
        #expect(Set(positions).count == positions.count)
        for position in positions {
          #expect(ArrangementRules.isValid(layout.moving(source.id, to: position)))
        }
        // Sorted by (x, y): the value is a function of the arrangement, not of
        // the order the tiles were enumerated in.
        #expect(positions == positions.sorted { ($0.x, $0.y) < ($1.x, $1.y) })
      }
    }
  }

  @Test func aLoneDisplayHasNowhereToDock() {
    let alone = arrangement([(1, DisplayRect(x: 0, y: 0, width: 1800, height: 1169))])
    #expect(ArrangementDockPolicy.dockPositions(for: 1, in: alone).isEmpty)
    for direction in ArrangementDirection.allCases {
      #expect(ArrangementDockPolicy.move(1, direction, in: alone) == nil)
    }
  }

  @Test func aDisplayThatIsNotInTheLayoutIsNotMoved() {
    let layout = arrangement([
      (1, DisplayRect(x: 0, y: 0, width: 1000, height: 800)),
      (2, DisplayRect(x: 1000, y: 0, width: 1000, height: 800)),
    ])
    #expect(ArrangementDockPolicy.dockPositions(for: 9, in: layout).isEmpty)
    for direction in ArrangementDirection.allCases {
      #expect(ArrangementDockPolicy.move(9, direction, in: layout) == nil)
    }
  }

  @Test func aZeroSizedDisplayCanDockNowhere() {
    // It shares no boundary segment of nonzero length with anything, so every
    // candidate position is disconnected. Reported as "no move", never as a
    // move onto an illegal layout.
    let layout = arrangement([
      (1, DisplayRect(x: 0, y: 0, width: 1000, height: 800)),
      (2, DisplayRect(x: 1000, y: 0, width: 0, height: 0)),
    ])
    #expect(ArrangementDockPolicy.dockPositions(for: 2, in: layout).isEmpty)
    for direction in ArrangementDirection.allCases {
      #expect(ArrangementDockPolicy.move(2, direction, in: layout) == nil)
    }
  }

  @Test func theFourSidesAndThreeAlignmentsAreAllOffered() {
    // A 600×600 display against a 1000×1000 one: the three alignments per side
    // are distinct, so all twelve positions are.
    let layout = arrangement([
      (1, DisplayRect(x: 0, y: 0, width: 1000, height: 1000)),
      (2, DisplayRect(x: 1000, y: 0, width: 600, height: 600)),
    ])
    #expect(Set(ArrangementDockPolicy.dockPositions(for: 2, in: layout)) == Set([
      // Left of display 1, aligned leading / centre / trailing on y.
      DisplayPoint(x: -600, y: 0), DisplayPoint(x: -600, y: 200), DisplayPoint(x: -600, y: 400),
      // Right of it.
      DisplayPoint(x: 1000, y: 0), DisplayPoint(x: 1000, y: 200), DisplayPoint(x: 1000, y: 400),
      // Above it.
      DisplayPoint(x: 0, y: -600), DisplayPoint(x: 200, y: -600), DisplayPoint(x: 400, y: -600),
      // Below it.
      DisplayPoint(x: 0, y: 1000), DisplayPoint(x: 200, y: 1000), DisplayPoint(x: 400, y: 1000),
    ]))
  }

  @Test func aCentreDockRoundsTheSameWayASnapDoes() {
    // An odd difference cannot land on the exact centre. The keyboard and the
    // drag must land on the SAME point either way, or an arrow press and a
    // centre snap would disagree by one — so both go through
    // `ArrangementSnapper.halved`.
    let layout = arrangement([
      (1, DisplayRect(x: 0, y: 0, width: 1001, height: 1000)),
      (2, DisplayRect(x: 1001, y: 0, width: 600, height: 600)),
    ])
    let centred = DisplayPoint(x: 0 + ArrangementSnapper.halved(1001 - 600), y: 1000)
    #expect(centred == DisplayPoint(x: 200, y: 1000))
    #expect(ArrangementDockPolicy.dockPositions(for: 2, in: layout).contains(centred))
  }

  @Test func aCentreDockFloorsWhenTheMovedDisplayIsTheWiderOne() {
    // The case a positive difference cannot see. `halved` FLOORS, so a moved
    // display wider than its neighbour centres one point to the LEFT of centre;
    // Swift's `/` would truncate toward zero and put it one point to the right,
    // making the bias depend on which of two displays the user happened to grab.
    // Both axes, because the two call sites are separate lines.
    let layout = arrangement([
      (1, DisplayRect(x: 0, y: 0, width: 600, height: 600)),
      (2, DisplayRect(x: 0, y: 600, width: 1001, height: 1001)),
    ])
    #expect(ArrangementSnapper.halved(600 - 1001) == -201)
    let positions = ArrangementDockPolicy.dockPositions(for: 2, in: layout)

    #expect(positions.contains(DisplayPoint(x: -201, y: 600)))
    #expect(!positions.contains(DisplayPoint(x: -200, y: 600)))
    #expect(positions.contains(DisplayPoint(x: 600, y: -201)))
    #expect(!positions.contains(DisplayPoint(x: 600, y: -200)))
  }

  // MARK: - Ordering

  @Test func theNearestPositionInTheDirectionWins() {
    let layout = arrangement([
      (1, DisplayRect(x: 0, y: 0, width: 1000, height: 800)),
      (2, DisplayRect(x: 1000, y: 0, width: 1000, height: 800)),
    ])
    // Four dock positions, all at Manhattan distance 1800 or 2000 from (1000, 0).
    // Pressing left offers three of them; the two at 1800 tie and `(x, y)` picks
    // the one with the lower y. So the first press moves the display ABOVE its
    // neighbour rather than to the far side of it — surprising, correct, and
    // pinned: "left" means the nearest legal position that is strictly to the
    // left, not "the position on the left-hand side".
    let first = ArrangementDockPolicy.move(2, .left, in: layout)
    #expect(first?.tile(2)?.rect.origin == DisplayPoint(x: 0, y: -800))

    // A second press then reaches the far side, so the position a user is
    // reaching for is two presses away rather than unreachable.
    let second = first.flatMap { ArrangementDockPolicy.move(2, .left, in: $0) }
    #expect(second?.tile(2)?.rect.origin == DisplayPoint(x: -1000, y: 0))
    #expect(second.flatMap { ArrangementDockPolicy.move(2, .left, in: $0) } == nil)
  }

  @Test func distanceIsMeasuredOnBothAxes() {
    // Manhattan, not "distance along the axis the key names". Display 2 sits at
    // the trailing edge of display 1's right-hand side; pressing up offers both
    // remaining right-hand positions, and they are the same distance along x.
    // Only the cross-axis term separates them, and it must, or the key would
    // jump the display the whole height of its neighbour when one step up was
    // available.
    let layout = arrangement([
      (1, DisplayRect(x: 0, y: 0, width: 1000, height: 1000)),
      (2, DisplayRect(x: 1000, y: 800, width: 200, height: 200)),
    ])
    let moved = ArrangementDockPolicy.move(2, .up, in: layout)
    #expect(moved?.tile(2)?.rect.origin == DisplayPoint(x: 1000, y: 400))
  }

  @Test func dockingIsIndependentOfTileOrder() {
    let tiles: [(CGDirectDisplayID, DisplayRect)] = [
      (1, DisplayRect(x: 0, y: 0, width: 1000, height: 1000)),
      (2, DisplayRect(x: 1000, y: 0, width: 600, height: 600)),
      (3, DisplayRect(x: -700, y: 0, width: 700, height: 900)),
    ]
    let forward = arrangement(tiles)
    let backward = arrangement(tiles.reversed())
    for direction in ArrangementDirection.allCases {
      #expect(
        ArrangementDockPolicy.move(2, direction, in: forward)
          == ArrangementDockPolicy.move(2, direction, in: backward)
      )
    }
    #expect(
      ArrangementDockPolicy.dockPositions(for: 2, in: forward)
        == ArrangementDockPolicy.dockPositions(for: 2, in: backward)
    )
  }

  @Test func anArrowPressRescuesADisplayFromAnIllegalLayout() {
    // The keyboard route has to work from a layout that is already broken —
    // otherwise a display stranded by a System Settings change, or by another
    // display departing, could not be recovered without the mouse.
    let stranded = arrangement([
      (1, DisplayRect(x: 0, y: 0, width: 1000, height: 1000)),
      (2, DisplayRect(x: 1000, y: 1000, width: 600, height: 600)),
    ])
    #expect(!ArrangementRules.isValid(stranded))
    let recovered = ArrangementDockPolicy.move(2, .up, in: stranded)
    #expect(recovered != nil)
    #expect(recovered.map(ArrangementRules.isValid) == true)
  }

  @Test func movingTheMiddleOfARowNeverStrandsTheFarDisplay() {
    // §3.5: connectivity is checked on the WHOLE arrangement, so a dock position
    // that would leave display 3 on its own is not offered at all.
    let row = arrangement([
      (1, DisplayRect(x: 0, y: 0, width: 1000, height: 800)),
      (2, DisplayRect(x: 1000, y: 0, width: 1000, height: 800)),
      (3, DisplayRect(x: 2000, y: 0, width: 1000, height: 800)),
    ])
    for direction in ArrangementDirection.allCases {
      guard let moved = ArrangementDockPolicy.move(2, direction, in: row) else { continue }
      #expect(ArrangementRules.problems(in: moved).isEmpty)
    }
    // Concretely: nothing to the left of display 2 is legal, because every such
    // position leaves display 3 hanging off the right-hand end alone.
    #expect(ArrangementDockPolicy.move(2, .left, in: row) == nil)
  }
}
