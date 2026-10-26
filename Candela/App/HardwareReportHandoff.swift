import AppKit
import CandelaKit

/// Prepares a local report before opening the existing hardware issue form.
/// No report text is placed in the URL or sent to GitHub by this action.
@MainActor
enum HardwareReportHandoff {
  enum Outcome: Equatable {
    case opened
    case clipboardFailed
    case browserFailed
  }

  static let formURL = URL(
    string: "https://github.com/Rydersel/Candela/issues/new?template=hardware_report.yml")!

  static func prepare(
    snapshot: DiagnosticsReportSnapshot,
    pasteboard: NSPasteboard = .general,
    openURL: (URL) -> Bool = { NSWorkspace.shared.open($0) }
  ) -> Outcome {
    pasteboard.clearContents()
    guard pasteboard.setString(DiagnosticsReport.render(snapshot), forType: .string) else {
      return .clipboardFailed
    }
    return openURL(formURL) ? .opened : .browserFailed
  }
}
