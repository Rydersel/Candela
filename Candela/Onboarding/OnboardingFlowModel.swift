import Foundation
import Observation

/// A decision the flow commits when the user advances past a page (OB7).
/// Stage 1 records these; Stage 2 routes them through the existing write
/// paths (OB6) and nothing else changes.
enum OnboardingCommit: Equatable {
  case rename(displayKey: String, name: String)
  case applySize(displayKey: String, looksLikeWidth: Int, looksLikeHeight: Int)
  case enrollInCare(displayKey: String)
  case enableMeasuredTelemetry(displayKey: String)
  case setLaunchAtLogin(Bool)
}

/// What the user chose on a size page.
enum OnboardingSizeChoice: Equatable {
  case recommended
  case keepCurrent
  case custom(looksLikeWidth: Int, looksLikeHeight: Int)
}

/// Drives the guided setup flow over an `OnboardingEnvironment`. Owns the
/// derived page list, the in-flow choices, and the commit seam. In fixture
/// mode (Stage 1, tests) commits are recorded and the permission grant is
/// simulated; live mode replaces `commit` and the permission proxy.
@MainActor
@Observable
final class OnboardingFlowModel {
  private(set) var environment: OnboardingEnvironment
  private(set) var pages: [OnboardingPage]
  private(set) var index: Int = 0

  /// Displays currently marked as OLEDs on the designation page. Changing it
  /// re-derives the plan, which is how the care page appears and disappears.
  var designatedOleds: Set<String> {
    didSet { replan() }
  }

  /// Per-display protection choice on the care page, default on for every
  /// designated display (OB3).
  var careEnabled: Set<String>
  /// True when the user took the recommended measured path (OB5).
  var measuredTelemetry: Bool = true
  var sizeChoices: [String: OnboardingSizeChoice] = [:]
  var renames: [String: String] = [:]
  /// Finish-page toggle, default checked on a first run (OB13).
  var launchAtLogin: Bool
  /// Simulated grant state in fixture mode; live mode mirrors the real
  /// permission object instead.
  var accessibilityGranted: Bool
  var accessibilityRequested = false

  /// The commit seam. Fixture mode records; live mode writes (OB6).
  var onCommit: (OnboardingCommit) -> Void
  /// Close the hosting window, recording completion (OB7 keeps everything
  /// already committed).
  var onClose: () -> Void = {}
  /// Permission actions, injected: live mode binds `AccessibilityPermission`,
  /// the mock presenter simulates a grant so the page's states are clickable.
  var onRequestAccessibility: () -> Void = {}
  var onOpenAccessibilitySettings: () -> Void = {}

  func requestAccessibility() {
    accessibilityRequested = true
    onRequestAccessibility()
  }

  func openAccessibilitySettings() {
    onOpenAccessibilitySettings()
  }

  /// OB5's ask, injected like the accessibility actions: live mode calls
  /// `CGRequestScreenCaptureAccess`, the mock records the click.
  var onRequestScreenRecording: () -> Void = {}

  func requestScreenRecording() {
    onRequestScreenRecording()
  }

  private(set) var committed: [OnboardingCommit] = []

  init(environment: OnboardingEnvironment) {
    self.environment = environment
    let designated = OnboardingPlan.initialDesignation(for: environment)
    designatedOleds = designated
    careEnabled = designated
    launchAtLogin = environment.isFirstRun ? true : environment.loginItemEnabled
    accessibilityGranted = environment.accessibilityGranted
    onCommit = { _ in }
    pages = OnboardingPlan.pages(for: environment, designatedOleds: designated)
    onCommit = { [weak self] in self?.committed.append($0) }
  }

  var currentPage: OnboardingPage { pages[min(index, pages.count - 1)] }
  var canGoBack: Bool { index > 0 }
  var isLastPage: Bool { index >= pages.count - 1 }

  func display(forKey key: String) -> OnboardingDisplayEntry? {
    environment.displays.first { $0.persistenceKey == key }
  }

  func displayName(forKey key: String) -> String {
    renames[key] ?? display(forKey: key)?.name ?? key
  }

  /// Commit the current page's decisions, then move forward (OB7). The last
  /// page's advance closes the window.
  func advance() {
    commitCurrentPage()
    if isLastPage {
      onClose()
    } else {
      index += 1
    }
  }

  func back() {
    guard canGoBack else { return }
    index -= 1
  }

  /// Skip Setup: close without committing the current page. Everything
  /// already applied stays applied (OB7).
  func skip() {
    onClose()
  }

  /// Mid-flow environment change (a display unplugged): re-derive and keep
  /// the position on a still-valid page.
  func update(environment: OnboardingEnvironment) {
    self.environment = environment
    designatedOleds = designatedOleds.filter { key in
      environment.displays.contains { $0.persistenceKey == key }
    }
    // didSet already replanned; clamp in case the list shrank.
    index = min(index, pages.count - 1)
  }

  private func replan() {
    let current = currentPage
    pages = OnboardingPlan.pages(for: environment, designatedOleds: designatedOleds)
    if let stillThere = pages.firstIndex(of: current) {
      index = stillThere
    } else {
      index = min(index, pages.count - 1)
    }
  }

  private func commitCurrentPage() {
    switch currentPage {
    case .welcome, .accessibility, .noDisplays, .oledSelect:
      break
    case .detection:
      for (key, newName) in renames {
        let original = display(forKey: key)?.name
        if !newName.isEmpty, newName != original {
          onCommit(.rename(displayKey: key, name: newName))
        }
      }
    case let .size(displayKey):
      switch sizeChoices[displayKey] ?? .recommended {
      case .recommended:
        if let suggestion = display(forKey: displayKey)?.sizeSuggestion {
          onCommit(.applySize(
            displayKey: displayKey,
            looksLikeWidth: suggestion.looksLikeWidth,
            looksLikeHeight: suggestion.looksLikeHeight))
        }
      case .keepCurrent:
        break
      case let .custom(width, height):
        onCommit(.applySize(
          displayKey: displayKey, looksLikeWidth: width, looksLikeHeight: height))
      }
    case .oledCare:
      for key in designatedOleds.sorted() where careEnabled.contains(key) {
        onCommit(.enrollInCare(displayKey: key))
        if measuredTelemetry {
          onCommit(.enableMeasuredTelemetry(displayKey: key))
        }
      }
    case .finish:
      onCommit(.setLaunchAtLogin(launchAtLogin))
    }
  }
}
