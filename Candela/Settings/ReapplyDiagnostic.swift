import CandelaKit
import SwiftUI

/// The diagnostic goes in a tooltip, out of the sentence someone reads while
/// working out what happened to their screen. Only `.failed` gets one: an empty
/// tooltip would imply an error that a substitution never had.
///
/// Through `DisplayModeCopy.diagnostic`, never the raw code: an unhonoured
/// commit has no CoreGraphics error to print.
struct ReapplyDiagnostic: ViewModifier {
  let notice: ModeReapplyNotice

  @ViewBuilder func body(content: Content) -> some View {
    if case let .failed(error) = notice {
      content.help(DisplayModeCopy.diagnostic(error))
    } else {
      content
    }
  }
}
