import CandelaKit
import SwiftUI

/// The CoreGraphics code goes in a tooltip, out of the sentence someone reads
/// while working out what happened to their screen. Only `.failed` gets one: an
/// empty tooltip would imply an error that a substitution never had.
struct ReapplyDiagnostic: ViewModifier {
  let notice: ModeReapplyNotice

  @ViewBuilder func body(content: Content) -> some View {
    if case let .failed(error) = notice {
      content.help("CoreGraphics error \(error.cgErrorCode)")
    } else {
      content
    }
  }
}
