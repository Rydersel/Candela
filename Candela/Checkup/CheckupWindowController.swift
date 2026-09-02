import AppKit
import CandelaKit
import CoreGraphics
import SwiftUI

/// The AppKit island hosting the checkup flow, shaped like the setup window: an
/// `LSUIElement` app has no window scene, so this is a plain `NSWindow`. The cap
/// tick and the pairing of an answer with the tapped region live here because
/// both need the field window, which the model sees only through a protocol.
@MainActor
final class CheckupWindowController: NSObject, NSWindowDelegate {
  private let environment: () async -> CheckupEnvironment
  private let onSaved: (CheckupReportEnvelope) -> Void
  private var window: NSWindow?
  private var model: CheckupFlowModel?
  /// Held while an environment is being built, so a second click during the
  /// capability read does not install a second flow over the first.
  private var presenting = false
  /// Owned here because the tap, the one-display strip and the countdown all live on it.
  let fieldWindow: CheckupFieldWindow
  private var tick: Task<Void, Never>?

  init(
    environment: @escaping () async -> CheckupEnvironment,
    onSaved: @escaping (CheckupReportEnvelope) -> Void,
    care: (any CheckupCareHolding)? = nil
  ) {
    self.environment = environment
    self.onSaved = onSaved
    // The window takes the hold, not this controller: `windowWillClose` hides
    // it directly, so a hold owned a layer up would outlive a close mid-field.
    self.fieldWindow = CheckupFieldWindow(care: care)
    super.init()
  }

  func present() {
    let window = window ?? makeWindow()
    self.window = window
    // A present() while the window is up only brings it forward, keeping the
    // user's place in a run. Read before ordering front, which makes it visible.
    let needsFlow = !window.isVisible
    // Same as the setup window: modern `NSApp.activate()` cannot activate an
    // accessory app from inside a status-item tracking session.
    NSApp.activate(ignoringOtherApps: true)
    window.makeKeyAndOrderFront(nil)
    guard needsFlow, !presenting else { return }
    presenting = true
    Task { @MainActor in
      defer { presenting = false }
      let environment = await self.environment()
      // The window can have been closed while the read was out; installing a
      // flow into it now would start a run nobody is looking at.
      guard window.isVisible else { return }
      self.installFlow(in: window, environment: environment)
      window.center()
    }
  }

  /// The target going away ends the run as incomplete, with the leg it
  /// was in named on the report. Forwarded from the app's topology loop.
  func displayDisconnected(_ id: CGDirectDisplayID) {
    model?.displayDisconnected(id)
  }

  private func installFlow(in window: NSWindow, environment: CheckupEnvironment) {
    var environment = environment
    // Everything this controller does around a showing is on the window it
    // owns, so that window is the presenter.
    environment.presenter = FieldPresenter(
      window: fieldWindow, beforeShow: { [weak self] entry in self?.moveOffTarget(entry) })
    let model = CheckupFlowModel(environment: environment)
    model.onSaved = onSaved
    self.model = model

    fieldWindow.onAnswer = { [weak self] answer in
      guard let self, let model = self.model else { return }
      // The region and the answer are one report: the person pointed at the
      // mark on the field, then said what they saw.
      model.answer(answer, tappedRegion: self.fieldWindow.lastTap)
      // The confirmation re-show goes up inside `answer`, so the strip is
      // asking a new question the moment this returns.
      self.syncFieldWindow()
    }

    window.contentView = NSHostingView(
      rootView: CheckupFlowView(
        model: model,
        tappedRegion: { [weak self] in self?.fieldWindow.lastTap }))
    window.setContentSize(NSSize(width: 760, height: 620))
    startTick()
  }

  /// The cap is wall-clock time on the panel, so it is counted here and handed
  /// to the flow, which decides what a run-out means.
  private func startTick() {
    tick?.cancel()
    tick = Task { [weak self] in
      while !Task.isCancelled {
        try? await Task.sleep(for: .seconds(1))
        guard !Task.isCancelled, let self, let model = self.model else { return }
        model.timeoutTick()
        self.syncFieldWindow()
      }
    }
  }

  /// Keeps the field's own strip saying what the flow page says. A no-op when
  /// nothing is on the panel, and cheap enough to run every second.
  private func syncFieldWindow() {
    guard let model else { return }
    switch model.page {
    case .fieldShowing(let kind):
      fieldWindow.instructionText = CheckupCopy.instruction(for: kind)
    case .fieldConfirmSecondDot:
      fieldWindow.instructionText = CheckupCopy.secondDotPrompt
    default:
      break
    }
    fieldWindow.updateTimer(model.secondsRemaining)
  }

  /// The field covers the target, so the flow window belongs on another display
  /// when there is one; otherwise the field's strip carries the controls.
  /// Called as the field goes up, not at pick time: a window that jumped while
  /// the person was still choosing read as a random move.
  private func moveOffTarget(_ entry: CheckupDisplayEntry) {
    guard let window else { return }
    let screens = NSScreen.screens.compactMap { screen -> CheckupFlowWindowHost.Screen? in
      screen.displayID.map { .init(id: $0, frame: screen.frame) }
    }
    guard
      let pick = CheckupFlowWindowHost.host(for: window.frame, target: entry.id, screens: screens),
      let host = NSScreen.screens.first(where: { $0.displayID == pick.id })
    else { return }
    let frame = host.visibleFrame
    let size = window.frame.size
    window.setFrameOrigin(
      NSPoint(
        x: frame.midX - size.width / 2,
        y: frame.midY - size.height / 2))
  }

  private func makeWindow() -> NSWindow {
    let window = NSWindow(
      contentRect: NSRect(origin: .zero, size: NSSize(width: 760, height: 620)),
      styleMask: [.titled, .closable, .fullSizeContentView],
      backing: .buffered,
      defer: false
    )
    window.titlebarAppearsTransparent = true
    window.titleVisibility = .hidden
    window.isMovableByWindowBackground = true
    // Hidden in the titlebar, but still what VoiceOver and the Window menu read.
    window.title = "\(AppInfo.productName) Checkup"
    // The flow is composed against its own dark palette; the window forces it
    // so a light-mode system does not render dark text on dark canvas.
    window.appearance = NSAppearance(named: .darkAqua)
    // Without this the window is deallocated on close and the next `present()`
    // messages freed memory.
    window.isReleasedWhenClosed = false
    window.delegate = self
    return window
  }

  /// Closing abandons the run, and an abandoned run is still saved as
  /// incomplete. On the summary there is nothing left to abandon.
  func windowShouldClose(_: NSWindow) -> Bool {
    if model?.page != .summary {
      model?.abandon(reason: CheckupCopy.closedReason)
    }
    return true
  }

  /// The quit-time `windowShouldClose`: `NSApplication.terminate` closes no
  /// windows, so a run in flight at quit would otherwise save no report and
  /// book no field time.
  func abandonForTermination() {
    if model?.page != .summary {
      model?.abandon(reason: CheckupCopy.closedReason)
    }
    // `abandon` hides through the presenter; this covers a run that already
    // ended with the field still up.
    fieldWindow.hide()
  }

  func windowWillClose(_: Notification) {
    tick?.cancel()
    tick = nil
    // Belt and braces on top of the abandon above: whatever ended the run, no
    // field is left on a panel with no window left to take it down.
    fieldWindow.hide()
    fieldWindow.onAnswer = nil
    model = nil
  }

  /// Sets the strip's instruction before `show`, the only point that runs
  /// before the window lays the strip out.
  @MainActor
  private final class FieldPresenter: CheckupFieldPresenting {
    private let window: CheckupFieldWindow
    private let beforeShow: (CheckupDisplayEntry) -> Void

    init(window: CheckupFieldWindow, beforeShow: @escaping (CheckupDisplayEntry) -> Void) {
      self.window = window
      self.beforeShow = beforeShow
    }

    func show(kind: CheckupFieldKind, plant: CheckupPlant?, on display: CheckupDisplayEntry) -> Bool {
      beforeShow(display)
      window.instructionText = CheckupCopy.instruction(for: kind)
      return window.show(kind: kind, plant: plant, on: display)
    }

    func hide() { window.hide() }
  }
}
