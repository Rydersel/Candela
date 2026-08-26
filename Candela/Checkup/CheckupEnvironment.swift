import CandelaKit
import CoreGraphics
import Foundation

/// One attached display as the checkup flow sees it (CK26). Virtual displays are
/// filtered out where entries are built, so a report can never key on one.
struct CheckupDisplayEntry: Equatable, Sendable, Identifiable {
  var id: CGDirectDisplayID
  /// The EDID-derived key every stored run is filed under; never the display id.
  var identityKey: String
  var name: String
  var isBuiltIn: Bool
  var isVirtual: Bool
  /// A display mirroring another has no `NSScreen` of its own, so no field can
  /// be drawn on it; it is dropped where entries are built, like a virtual one.
  var isMirroring: Bool
  var panelClass: CheckupPanelClass
  /// True when the panel was in HDR as the run began. DDC is dead in that state,
  /// so the capability rows say so rather than blaming the panel.
  var hdrEngaged: Bool
  var pixelWidth: Int
  var pixelHeight: Int
  /// The display's height in points, which is the field view's height: the
  /// instruction strip is sized in points and the plant is placed in pixels.
  var pointHeight: Double
  /// CK16: with nowhere else to put the instructions, they sit on the field
  /// itself and the report records the field as partially occluded.
  var isOnlyDisplay: Bool
}

/// Presents one field on one display and reports when it is down. MainActor
/// because the live implementation is an AppKit window on the target panel.
@MainActor
protocol CheckupFieldPresenting: AnyObject {
  /// False when the field never reached the glass, which is a display with no
  /// `NSScreen`. A Void return let the flow book light nothing emitted.
  func show(kind: CheckupFieldKind, plant: CheckupPlant?, on display: CheckupDisplayEntry) -> Bool
  func hide()
}

/// Everything the flow reaches past itself (CK25): live in the app, fakes in
/// the suite. The model never touches a display, a clock or a store directly.
struct CheckupEnvironment {
  var displays: [CheckupDisplayEntry]
  var macOSBuild: String
  var appBuild: String
  var runners: (CheckupDisplayEntry) -> CheckupRunnerSet
  var presenter: any CheckupFieldPresenting
  /// CK17: every showing is booked to the exposure record with its on-time.
  var bookShowing: (_ identityKey: String, _ kind: CheckupFieldKind, _ seconds: TimeInterval) -> Void
  var now: () -> Date
  var makeRNG: () -> any RandomNumberGenerator
}

/// `CheckupField.plantPosition` is generic over the generator, and an
/// existential cannot be passed inout; the model wraps it once per run.
struct AnyRandomNumberGenerator: RandomNumberGenerator {
  var base: any RandomNumberGenerator

  mutating func next() -> UInt64 { base.next() }
}

/// CK24's page order, plus the three states a field passes through. The
/// instruction page is where a field rests before and after its showing.
enum CheckupPage: Equatable {
  case scenario, displayPick, plan, identity, capabilities, nativeMode, refresh, witness
  case plantDisclosure
  case fieldInstruction(CheckupFieldKind)
  case fieldShowing(CheckupFieldKind)
  case fieldConfirmSecondDot(CheckupFieldKind)
  case hdr, summary

  /// Names the page in the report when a run ends here (CK27).
  var name: String {
    switch self {
    case .scenario: "the scenario page"
    case .displayPick: "the display pick"
    case .plan: "the plan"
    case .identity: "identity"
    case .capabilities: "capabilities"
    case .nativeMode: "the native mode check"
    case .refresh: "the refresh sweep"
    case .witness: "the witness card"
    case .plantDisclosure: "the planted control disclosure"
    case .fieldInstruction(let kind), .fieldShowing(let kind), .fieldConfirmSecondDot(let kind):
      // The prose name, never `kind.rawValue`: this reaches the summary and the
      // exported file, and `gray7` is a storage key.
      "the \(CheckupCopy.fieldName(kind))"
    case .hdr: "the HDR checks"
    case .summary: "the summary"
    }
  }
}

/// What a person can answer on a field. The first three belong to the visual
/// fields (CK22), the last two to the witness card (CK19).
enum CheckupFieldAnswer: Equatable { case nothing, oneMark, moreThanOne, roundAndUncut, notRound }
