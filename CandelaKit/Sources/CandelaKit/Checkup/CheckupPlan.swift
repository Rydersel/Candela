import Foundation

/// Shipped schema: add ids, never rename them.
public enum CheckupCheckID {
  public static let identity = "identity.edid"
  public static let capabilityBrightness = "capabilities.brightness"
  public static let capabilityContrast = "capabilities.contrast"
  public static let capabilityVolume = "capabilities.volume"
  public static let nativeMode = "mode.native"
  public static let refreshSweep = "refresh.sweep"
  /// One decimal, never an Int: rounding collides NTSC's 59.9 with 60, and
  /// these ids are shipped schema.
  public static func refresh(hz: Double) -> String {
    "refresh." + String(format: "%g", DisplayMode.quantizedRefresh(hz))
  }
  public static let witness = "field.witness"
  public static let hdrFlags = "hdr.flags"
  public static let hdrSettle = "hdr.settle"
  public static func field(_ kind: CheckupFieldKind) -> String { "field.\(kind.rawValue)" }
}

public enum CheckupPlan {
  public struct Step: Equatable, Sendable {
    public let id: String
    public let family: CheckupFamily
    /// Set when this panel class cannot answer; the flow records it without running anything.
    public let pregraded: CheckupVerdict?
  }

  /// Support exists only where the capabilities string says so.
  /// A DDC service that answers reads with zeros, or not at all, is write-only.
  public static func panelClass(
    capabilities: String?, hasDDCService: Bool, isBuiltIn: Bool
  ) -> CheckupPanelClass {
    if isBuiltIn || !hasDDCService { return .noDDC }
    guard let capabilities, CapabilityString.codes(in: capabilities) != nil else {
      return .writeOnlyDDC
    }
    return .readsDDC
  }

  /// The reason the capability rows carry when the run starts with the panel in
  /// HDR. Public because the flow and the copy layer both quote it.
  public static let hdrEngagedCapabilityText =
    "DDC readback cannot be observed while this display is in HDR mode"

  /// `hdrEngaged` stays out of `CheckupPanelClass`: that enum is stored on every
  /// report, and a new raw value would fail an older decoder. HDR outranks the
  /// write-only reason (DDC classing is not trustworthy in HDR); no-DDC keeps its own.
  public static func make(panelClass: CheckupPanelClass, hdrEngaged: Bool) -> [Step] {
    let capabilityVerdict: CheckupVerdict? = switch (panelClass, hdrEngaged) {
    case (.noDDC, _): .notObserved("this display has no DDC path; readback cannot be observed")
    case (_, true): .notObserved(hdrEngagedCapabilityText)
    case (.readsDDC, false): nil
    case (.writeOnlyDDC, false):
      .notObserved("this panel is write-only over DDC; readback cannot be observed")
    }
    var steps: [Step] = [
      Step(id: CheckupCheckID.identity, family: .identity, pregraded: nil),
      Step(id: CheckupCheckID.capabilityBrightness, family: .capabilities, pregraded: capabilityVerdict),
      Step(id: CheckupCheckID.capabilityContrast, family: .capabilities, pregraded: capabilityVerdict),
      Step(id: CheckupCheckID.capabilityVolume, family: .capabilities, pregraded: capabilityVerdict),
      Step(id: CheckupCheckID.nativeMode, family: .nativeMode, pregraded: nil),
      Step(id: CheckupCheckID.refreshSweep, family: .refresh, pregraded: nil),
      Step(id: CheckupCheckID.witness, family: .visualField, pregraded: nil),
    ]
    for kind in CheckupFieldKind.protocolOrder {
      steps.append(Step(id: CheckupCheckID.field(kind), family: .visualField, pregraded: nil))
    }
    steps.append(Step(id: CheckupCheckID.hdrFlags, family: .hdr, pregraded: nil))
    steps.append(Step(id: CheckupCheckID.hdrSettle, family: .hdr, pregraded: nil))
    return steps
  }

  public static let maxShowingsPerField = 3

  /// Every field at its cap, three times, plus the one confirmation re-show a
  /// pixel field can ask for (exempt from the cap). What the plan page states
  /// and what the exposure ledger can expect.
  public static var worstCaseFieldSeconds: Int {
    let fields = CheckupFieldKind.protocolOrder.map(\.capSeconds).reduce(0, +)
    let confirmations = CheckupFieldKind.protocolOrder.filter(\.carriesPlant)
      .map(\.capSeconds).reduce(0, +)
    return (fields + CheckupFieldKind.witness.capSeconds) * maxShowingsPerField + confirmations
  }
}
