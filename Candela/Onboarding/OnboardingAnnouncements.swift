import AppKit
import SwiftUI

/// The two priorities the guided flows post announcements at, so a call site
/// only picks one and says why. Lives here because the checkup flow already
/// draws with `OnboardingHeading` and `OnboardingStyle`.
@MainActor
enum GuidedFlowAnnouncement {
  /// Default priority: VoiceOver finishes what it is saying first. Cutting a
  /// sentence off loses it, and the listener cannot ask for it back.
  static func queued(_ text: String) {
    AccessibilityNotification.Announcement(text).post()
  }

  /// High priority, so it cuts in: a deadline heard after it expired is not a
  /// deadline. The AppKit route because `AccessibilityNotification.Announcement`
  /// carries no priority argument.
  static func interrupting(_ text: String) {
    NSAccessibility.post(
      element: NSApp as Any,
      notification: .announcementRequested,
      userInfo: [
        .announcement: text,
        .priority: NSAccessibilityPriorityLevel.high.rawValue,
      ]
    )
  }
}

/// When a countdown speaks. Shared by both flows so the two cannot settle on
/// different cadences.
enum AnnouncementThresholds {
  /// 10 and 3 seconds, and never the value the count OPENED on: the white field
  /// caps at 10, so an unguarded threshold would announce "10 seconds left" at
  /// the instant the count starts.
  static func speaks(at seconds: Int, cap: Int) -> Bool {
    (seconds == 10 || seconds == 3) && seconds < cap
  }
}

/// What VoiceOver says when the setup flow lands on a new page.
///
/// No arm contains the heading of the page it announces: the cursor lands on
/// that heading a moment later. A test pairs every page with the title its view
/// draws and holds this.
enum OnboardingAnnouncements {
  /// `displayName` tells consecutive size pages apart. The caller passes a name
  /// only when it has one, never `OnboardingPage.id` or a persistence key.
  static func pageAnnouncement(
    _ page: OnboardingPage, step: Int, of total: Int, displayName: String? = nil
  ) -> String {
    "\(purpose(page, displayName: displayName)) Step \(step) of \(total)."
  }

  private static func purpose(_ page: OnboardingPage, displayName: String?) -> String {
    switch page {
    case .welcome:
      "The start of setup: what \(AppInfo.productName) does for an external display, and "
        + "what the next few pages ask."
    case .accessibility:
      "Accessibility access, so the brightness, volume and mute keys reach \(AppInfo.productName)."
    case .detection:
      // Spoken on arrival, while the scan still runs, and never re-announced
      // when the heading flips to a count. So: no past tense, no number.
      "The displays attached to this Mac, with their names, as \(AppInfo.productName) finds them."
    case .noDisplays:
      "No external display is attached yet."
    case .size:
      "The size \(AppInfo.productName) recommends for \(displayName ?? "this display"), and "
        + "the other sizes it can use."
    case .oledSelect:
      "Which of these displays are OLED."
    case .oledCare:
      "Burn-in protection for the displays marked as OLED."
    case .finish:
      "Setup is done, with a summary of what changed."
    }
  }
}

/// The title each setup page draws, shared with the announcement test. A
/// heading re-typed there would let a retitled page pass with its old words
/// still being checked.
enum OnboardingTitles {
  static let welcome = "Welcome to \(AppInfo.productName)"
  static let accessibility = "Your keyboard, everywhere"
  /// The detection page draws two titles: this one while the scan runs, the
  /// count below once the cards resolve.
  static let detectionScanning = "Looking at your displays"
  static func detectionFound(count: Int) -> String {
    count == 1 ? "Found your display" : "Found \(count) displays"
  }
  static let noDisplays = "No external displays yet"
  /// Several size pages can follow each other, so this one names its display.
  static func size(displayName: String) -> String { "A better size for \(displayName)" }
  static let oledSelect = "Any OLEDs here?"
  static let oledCare = "Protect your OLED"
  static let finish = "You're all set"
}
