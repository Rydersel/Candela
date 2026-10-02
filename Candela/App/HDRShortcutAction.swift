import CandelaKit
import CoreGraphics
import Observation

/// One explicit external display per press. A missing target never falls back
/// to another monitor or to all displays.
@MainActor @Observable
final class HDRShortcutAction {
  enum Outcome: Equatable {
    case changed(name: String, enabled: Bool)
    case refused(String)

    var message: String {
      switch self {
      case let .changed(name, enabled): "\(name): HDR \(enabled ? "on" : "off")"
      case let .refused(message): message
      }
    }
  }

  private(set) var isRunning = false
  private let gate: DisplayReconfigurationGate
  private let target: (CGDirectDisplayID) -> AppModel.DisplayState?
  private let isBlocked: () -> Bool
  private let isSynthesized: (CGDirectDisplayID) -> Bool

  init(gate: DisplayReconfigurationGate,
       target: @escaping (CGDirectDisplayID) -> AppModel.DisplayState?,
       isBlocked: @escaping () -> Bool = { false },
       isSynthesized: @escaping (CGDirectDisplayID) -> Bool = { _ in false }) {
    self.gate = gate
    self.target = target
    self.isBlocked = isBlocked
    self.isSynthesized = isSynthesized
  }

  enum PointerTarget: Equatable {
    case display(CGDirectDisplayID)
    /// No external display: nothing under the pointer, or a screen that is not
    /// one (the built-in among them).
    case nothing
    /// A Candela surface more than one panel shows. The press has to be about
    /// one display, so it names neither.
    case sharedSurface
  }

  static let sharedSurfaceRefusal = "Two displays show this screen. Switch HDR from Candela."

  /// A screen that is not one of `candidates` maps through a mirror only when
  /// it is one of `ownedSurfaces`, a virtual display Candela created, such as a
  /// synthesized size's master. The built-in panel is never a candidate, so
  /// mapping any screen would turn a press over the built-in into a switch on
  /// an external that merely mirrors it.
  static func pointerTarget(
    underScreen screenID: CGDirectDisplayID?, among candidates: [CGDirectDisplayID],
    ownedSurfaces: Set<CGDirectDisplayID>,
    mirrorsDisplay: (CGDirectDisplayID) -> CGDirectDisplayID
  ) -> PointerTarget {
    guard let screenID else { return .nothing }
    if candidates.contains(screenID) { return .display(screenID) }
    guard ownedSurfaces.contains(screenID) else { return .nothing }
    let showing = candidates.filter { mirrorsDisplay($0) == screenID }
    switch showing.count {
    case 0: return .nothing
    case 1: return .display(showing[0])
    default: return .sharedSurface
    }
  }

  func toggle(at target: PointerTarget) async -> Outcome {
    switch target {
    case let .display(id): await toggle(on: id)
    case .nothing: await toggle(on: nil)
    case .sharedSurface: .refused(Self.sharedSurfaceRefusal)
    }
  }

  func toggle(on displayID: CGDirectDisplayID?) async -> Outcome {
    guard let displayID, let state = target(displayID) else {
      return .refused("Move the pointer to an external display to switch HDR.")
    }
    return await toggle(state)
  }

  /// Keep the controller captured by the panel; a replug may reuse its display ID.
  func toggle(_ state: AppModel.DisplayState) async -> Outcome {
    guard target(state.id)?.controller === state.controller else {
      return .refused("The display changed. Try again.")
    }
    guard !isBlocked() else { return .refused("Wait for the settings reset to finish before switching HDR.") }
    guard !isRunning, !state.controller.isHDRSettling else {
      return .refused("Wait for the current HDR change to finish.")
    }
    isRunning = true
    defer { isRunning = false }
    if let holder = await gate.claim(.hdr).refusedBy {
      return .refused(holder == .checkup
        ? "Finish the display checkup before switching HDR."
        : "Finish the current display change before switching HDR.")
    }
    let outcome = await apply(to: state)
    await gate.release(.hdr)
    return outcome
  }

  private func apply(to state: AppModel.DisplayState) async -> Outcome {
    guard !isBlocked(), target(state.id)?.controller === state.controller else {
      return .refused("The display changed. Try again.")
    }
    let controller = state.controller
    if !controller.isHDREngaged {
      if isSynthesized(state.id) {
        return .refused(SynthesisCopy.hdrBlockedBySynthesizedSize)
      }
      guard controller.hdrCapabilityProbed else {
        return .refused("HDR support is still being checked. Try again shortly.")
      }
      guard controller.supportsHDR else { return .refused(PanelView.hdrNoModesCaption) }
    }
    let enabled = !controller.isHDREngaged
    await controller.setHDRMode(enabled ? .alwaysOn : .off)
    guard !isBlocked() else {
      return .refused("Settings changed while switching HDR. Try again after the reset finishes.")
    }
    guard target(state.id)?.controller === controller else {
      return .refused("The display disconnected while switching HDR.")
    }
    guard !controller.isHDRSettling, controller.isHDREngaged == enabled else {
      return .refused("The display did not confirm the HDR change. Try again.")
    }
    return .changed(name: PanelView.title(for: state.display), enabled: enabled)
  }
}
