import CoreGraphics
import Foundation

public struct ArrangementTile: Sendable, Equatable, Identifiable {
  public let id: CGDirectDisplayID
  /// For persistence; `CGDirectDisplayID`s reassign across a replug.
  public let identity: DisplayConfigIdentity
  public let name: String
  public let rect: DisplayRect
  /// Displays hardware-mirroring THIS one. They get no tile and no origin (AR6).
  public let mirroredIDs: [CGDirectDisplayID]

  public init(
    id: CGDirectDisplayID,
    identity: DisplayConfigIdentity,
    name: String,
    rect: DisplayRect,
    mirroredIDs: [CGDirectDisplayID]
  ) {
    self.id = id
    self.identity = identity
    self.name = name
    self.rect = rect
    self.mirroredIDs = mirroredIDs
  }

  func moved(to origin: DisplayPoint) -> ArrangementTile {
    ArrangementTile(id: id, identity: identity, name: name, rect: rect.moved(to: origin), mirroredIDs: mirroredIDs)
  }

  func offset(dx: Int, dy: Int) -> ArrangementTile {
    ArrangementTile(id: id, identity: identity, name: name, rect: rect.offset(dx: dx, dy: dy), mirroredIDs: mirroredIDs)
  }
}

public struct DisplayArrangement: Sendable, Equatable {
  public let tiles: [ArrangementTile]

  /// Sorting by id makes equality order-independent: two arrangements that
  /// describe the same layout compare equal however they were enumerated.
  public init(tiles: [ArrangementTile]) {
    self.tiles = tiles.sorted { $0.id < $1.id }
  }

  public var isEmpty: Bool { tiles.isEmpty }

  public var bounds: DisplayRect {
    DisplayRect.union(tiles.map(\.rect)) ?? DisplayRect(x: 0, y: 0, width: 0, height: 0)
  }

  public func tile(_ id: CGDirectDisplayID) -> ArrangementTile? {
    tiles.first { $0.id == id }
  }

  /// AR5 — derived, never stored. The global display space is *defined* with its
  /// origin at the main display's top-left, so a stored flag would be a second
  /// source of truth able to disagree with the geometry it describes.
  public var mainDisplayID: CGDirectDisplayID? {
    tiles.first { $0.rect.origin == .zero }?.id
  }

  public func moving(_ id: CGDirectDisplayID, to origin: DisplayPoint) -> DisplayArrangement {
    DisplayArrangement(tiles: tiles.map { $0.id == id ? $0.moved(to: origin) : $0 })
  }

  public func translated(dx: Int, dy: Int) -> DisplayArrangement {
    DisplayArrangement(tiles: tiles.map { $0.offset(dx: dx, dy: dy) })
  }

  /// A pure translation of the whole arrangement, so relative geometry is
  /// provably unchanged — "make main" cannot rearrange anything.
  public func makingMain(_ id: CGDirectDisplayID) -> DisplayArrangement {
    guard let tile = tile(id) else { return self }
    return translated(dx: -tile.rect.x, dy: -tile.rect.y)
  }
}
