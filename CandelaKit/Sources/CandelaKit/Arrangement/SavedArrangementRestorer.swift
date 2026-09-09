import CoreGraphics
import Foundation

/// Runs blocking rotation and arrangement writes away from the main actor.
/// The caller holds the display reconfiguration gate for this entire operation.
public actor SavedArrangementRestorer {
  private let arrangements: any DisplayArrangementConfiguring
  private let rotations: any DisplayRotationConfiguring

  public init(arrangements: any DisplayArrangementConfiguring,
              rotations: any DisplayRotationConfiguring) {
    self.arrangements = arrangements
    self.rotations = rotations
  }

  /// The returned decision describes work already performed. Callers must not
  /// apply its arrangementToApply again.
  public func restore(
    _ saved: SavedArrangement?, arrivals: Set<CGDirectDisplayID>,
    substituting: [CGDirectDisplayID: String] = [:],
    isEnabled: @Sendable () -> Bool = { true }
  ) -> ArrangementReapplyDecision {
    guard isEnabled(), !Task.isCancelled, !arrivals.isEmpty, let saved,
          !saved.entries.isEmpty, saved.version <= SavedArrangement.currentVersion
    else { return .doNothing }

    let initial = arrangements.currentTopology()
    // A missing footprint during reconnect must not be mistaken for a smaller setup.
    guard initial.displays.allSatisfy({ $0.isMirrorSlave || initial.arrangement.tile($0.id) != nil })
    else { return .deferred }

    var requests: [RotationRequest] = []
    var projected: [ArrangementTile] = []
    for tile in initial.arrangement.tiles {
      let identity = substituting[tile.id] ?? tile.identity.key
      guard let angle = saved.entries.first(where: { $0.identity == identity })?.rotation else {
        projected.append(tile)
        continue
      }
      // Rotation of a synthesized desktop does not describe the physical panel.
      // Preserve its existing position-only behavior until the pairing is removed.
      guard substituting[tile.id] == nil else {
        projected.append(tile)
        continue
      }
      guard let current = rotations.rotation(of: tile.id) else { return .deferred }
      guard current != angle else {
        projected.append(tile)
        continue
      }
      guard case let .rotate(request) = RotationPolicy.decide(
        display: tile.id, to: angle, in: initial.displays, currentRotation: current,
        isSupported: rotations.canRotate, isSynthesizedSize: false
      ), tile.mirroredIDs.isEmpty else { return Self.failed() }
      requests.append(request)
      let swap = current.swapsAxes != angle.swapsAxes
      projected.append(ArrangementTile(
        id: tile.id, identity: tile.identity, name: tile.name,
        rect: DisplayRect(x: tile.rect.x, y: tile.rect.y,
                          width: swap ? tile.rect.height : tile.rect.width,
                          height: swap ? tile.rect.width : tile.rect.height),
        mirroredIDs: tile.mirroredIDs
      ))
    }

    // Validate the WHOLE saved setup before the first write. A true resolution
    // change must not be "repaired" by rotating an otherwise unrelated display.
    let preflight = ArrangementReapplyPolicy.decide(
      isEnabled: true, arrivals: arrivals, stored: saved, attached: initial.displays,
      current: DisplayArrangement(tiles: projected), substituting: substituting
    )
    guard preflight.notice == nil, !preflight.isDeferred else { return preflight }

    for request in requests {
      guard isEnabled(), !Task.isCancelled else { return .doNothing }
      let live = arrangements.currentTopology()
      // IDs can be reassigned while a blocking display operation is in flight.
      // Defer the whole operation rather than send the next write to a new panel.
      guard Self.sameDisplays(initial.displays, live.displays),
            rotations.rotation(of: request.display) == request.from
      else { return .deferred }
      do {
        try rotations.applyRotation(request.to, to: request.display)
      } catch let error as DisplayConfigError {
        return Self.failed(error)
      } catch {
        return Self.failed()
      }
      guard rotations.rotation(of: request.display) == request.to else { return Self.failed() }
    }

    guard isEnabled(), !Task.isCancelled else { return .doNothing }
    let achieved = arrangements.currentTopology()
    guard Self.sameDisplays(initial.displays, achieved.displays) else { return .deferred }
    // Re-read actual dimensions AFTER rotation; macOS can move other displays too.
    let decision = ArrangementReapplyPolicy.decide(
      isEnabled: true, arrivals: arrivals, stored: saved, attached: achieved.displays,
      current: achieved.arrangement, substituting: substituting
    )
    guard decision.notice == nil, !decision.isDeferred else { return decision }
    if let layout = decision.arrangementToApply {
      guard let plan = ArrangementPlan(applying: layout, to: achieved.arrangement) else {
        return Self.failed()
      }
      do {
        _ = try arrangements.apply(plan, scope: ArrangementReapplyPolicy.scope)
      } catch let error as DisplayConfigError {
        return Self.failed(error)
      } catch {
        return Self.failed()
      }
    }
    let final = arrangements.currentTopology()
    guard Self.sameDisplays(initial.displays, final.displays) else { return .deferred }
    for tile in final.arrangement.tiles where substituting[tile.id] == nil {
      if let angle = saved.entries.first(where: { $0.identity == tile.identity.key })?.rotation,
         rotations.rotation(of: tile.id) != angle { return Self.failed() }
    }
    return decision
  }

  private static func sameDisplays(_ a: [ConfiguredDisplay], _ b: [ConfiguredDisplay]) -> Bool {
    a.sorted { $0.id < $1.id } == b.sorted { $0.id < $1.id }
  }

  private static func failed(
    _ error: DisplayConfigError = .init(cgErrorCode: CGError.cannotComplete.rawValue)
  ) -> ArrangementReapplyDecision {
    .init(arrangementToApply: nil, notice: .failed(error))
  }
}
