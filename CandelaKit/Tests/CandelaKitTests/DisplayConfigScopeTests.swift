import CoreGraphics
import Foundation
import Testing
@testable import CandelaKit

/// The scope → `CGConfigureOption` mapping is the one piece of the three
/// `CGCompleteDisplayConfiguration` call sites that is decidable without
/// reconfiguring the machine, which is why it was lifted out of them.
///
/// `.permanent` is the case that motivated the lift: it was added for
/// arrangement (drag-canvas §6.1), and the ternaries it replaced would have
/// mapped it to `.forSession` — a layout silently lost at logout, reported as
/// success. These assertions are what stops that mapping from being written
/// again by accident.
@Suite("Display config scope")
struct DisplayConfigScopeTests {
  @Test func everyScopeMapsToItsOwnCoreGraphicsOption() {
    #expect(DisplayConfigScope.preview.configureOption == .forAppOnly)
    #expect(DisplayConfigScope.session.configureOption == .forSession)
    #expect(DisplayConfigScope.permanent.configureOption == .permanently)
  }

  /// Distinctness on its own, so a mapping that collapsed two scopes onto one
  /// option fails here even if someone updated the expectations above to match
  /// it. Three scopes that mean three different lifetimes cannot share an
  /// option and still mean anything.
  @Test func noTwoScopesShareAnOption() {
    let options: [DisplayConfigScope] = [.preview, .session, .permanent]
    #expect(Set(options.map(\.configureOption.rawValue)).count == options.count)
  }
}
