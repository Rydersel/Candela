import AppKit
import CandelaKit
import CoreGraphics
import SwiftUI

/// The AppKit island that hosts the checkup flow, built on the same shape as
/// the setup window: an `LSUIElement` app has no ordinary window scene, so this
/// is a plain `NSWindow` created on demand.
///
/// Two things live here rather than in the flow: the one-second tick that runs
/// a showing's cap down, and the pairing of an answer with the region the field
/// was tapped at. Both need the field window, and the field window is an AppKit
/// island the model only ever sees through `CheckupFieldPresenting`.
@MainActor
final class CheckupWindowController: NSObject, NSWindowDelegate {
  private let environment: () -> CheckupEnvironment
  private let onSaved: (CheckupReportEnvelope) -> Void
  private var window: NSWindow?
  private var model: CheckupFlowModel?
  /// The presenter the flow drives. Owned here because the tap that reports a
  /// mark, the strip that carries the answers on a one-display run, and the
  /// countdown all live on it.
  let fieldWindow = CheckupFieldWindow()
  private var tick: Task<Void, Never>?

  init(
    environment: @escaping () -> CheckupEnvironment,
    onSaved: @escaping (CheckupReportEnvelope) -> Void
  ) {
    self.environment = environment
    self.onSaved = onSaved
    super.init()
  }

  func present() {
    let window = window ?? makeWindow()
    self.window = window
    // A fresh presentation gets a fresh flow over a fresh harvest; a present()
    // while the window is already up only brings it forward, keeping the user's
    // place in a run that is already recording claims.
    if !window.isVisible {
      installFlow(in: window)
      window.center()
    }
    // Same reason as the setup window: the modern `NSApp.activate()` cannot
    // activate an accessory app from inside a status-item tracking session, so
    // this stays the deprecated call and stays inside the click's event context.
    NSApp.activate(ignoringOtherApps: true)
    window.makeKeyAndOrderFront(nil)
  }

  /// CK27: the target going away ends the run as incomplete, with the leg it
  /// was in named on the report. Forwarded from the app's topology loop.
  func displayDisconnected(_ id: CGDirectDisplayID) {
    model?.displayDisconnected(id)
  }

  private func installFlow(in window: NSWindow) {
    var environment = self.environment()
    // The flow calls `show` and `hide` on whatever presenter its environment
    // carries, and everything this controller does around a showing is done on
    // the window it owns, so that window is the presenter.
    environment.presenter = FieldPresenter(window: fieldWindow)
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
        tappedRegion: { [weak self] in self?.fieldWindow.lastTap },
        onSelectedDisplayChanged: { [weak self] entry in self?.moveOffTarget(entry) }))
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

  /// The field covers the target, so the flow's own window belongs on another
  /// display when the setup has one. When it does not, the field's strip is
  /// what carries the instruction and the answers instead (CK16).
  private func moveOffTarget(_ entry: CheckupDisplayEntry?) {
    guard let window, let entry else { return }
    guard let host = NSScreen.screens.first(where: { $0.displayID != entry.id }) else { return }
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

  /// CK27: closing the window abandons the run, and an abandoned run is still
  /// saved, as incomplete with the page it stopped on. On the summary there is
  /// nothing left to abandon: the report is already written.
  func windowShouldClose(_: NSWindow) -> Bool {
    if model?.page != .summary {
      model?.abandon(reason: CheckupCopy.closedReason)
    }
    return true
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

  /// Sits between the flow and the field window so the strip is built from the
  /// field's own instruction: the model calls `show` directly, and this is the
  /// only point that runs before the window lays the strip out.
  @MainActor
  private final class FieldPresenter: CheckupFieldPresenting {
    private let window: CheckupFieldWindow

    init(window: CheckupFieldWindow) { self.window = window }

    func show(kind: CheckupFieldKind, plant: CheckupPlant?, on display: CheckupDisplayEntry) {
      window.instructionText = CheckupCopy.instruction(for: kind)
      window.show(kind: kind, plant: plant, on: display)
    }

    func hide() { window.hide() }
  }
}
