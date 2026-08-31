import CoreGraphics
import Foundation
import Testing
@testable import CandelaKit

/// The scope to `CGConfigureOption` mapping is the one part of the
/// `CGCompleteDisplayConfiguration` call sites decidable without reconfiguring the
/// machine. `.permanent` motivated the lift: the ternaries it replaced mapped it to
/// `.forSession`, a layout silently lost at logout and reported as success.
@Suite("Display config scope")
struct DisplayConfigScopeTests {
  @Test func everyScopeMapsToItsOwnCoreGraphicsOption() {
    #expect(DisplayConfigScope.preview.configureOption == .forAppOnly)
    #expect(DisplayConfigScope.session.configureOption == .forSession)
    #expect(DisplayConfigScope.permanent.configureOption == .permanently)
  }

  /// Distinctness on its own, so a mapping that collapses two scopes fails here even
  /// if the expectations above were updated to match it.
  @Test func noTwoScopesShareAnOption() {
    let options: [DisplayConfigScope] = [.preview, .session, .permanent]
    #expect(Set(options.map(\.configureOption.rawValue)).count == options.count)
  }
}
