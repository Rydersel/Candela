import AppKit
// @preconcurrency: `kAXTrustedCheckOptionPrompt` is a mutable C global that
// Swift 6 refuses to reference. It is set once at framework load.
@preconcurrency import ApplicationServices
import CandelaKit
import CoreGraphics

/// A small panel docked inside the bottom edge of the System Settings window
/// while the person grants a permission, offering a copy of Candela's list row
/// to drag into the list.
///
/// It reads only window bounds (no permission needed; titles would need Screen
/// Recording), never anything inside System Settings, and never clicks there:
/// the person does the granting. It counts a permission as granted only when the
/// live read says so.
@MainActor
final class PermissionGuide {
  static let shared = PermissionGuide()

  private(set) var showing: PermissionPane?
  /// The intended state; the window itself may still be mid-fade.
  private(set) var isPanelShown = false
  private(set) var panel: NSPanel?
  private(set) var doneControl: PermissionGuideDoneControl?
  private var row: PermissionGuideRow?
  private var arrow: NSImageView?
  private var timer: Timer?
  private var tickCount = 0
  private var settingsSeen = false
  private var lastSettingsWindow: CGRect?
  private var lineOnly = false
  private(set) var lineField: NSTextField?
  private var observers: [any NSObjectProtocol] = []

  enum Cadence {
    /// Settings is frontmost: tracking a window the person may be dragging.
    case following
    /// Settings is behind another app: nothing to follow, only the grant to
    /// watch. Its return is caught by the activation observer, not by this rate.
    case idle

    var interval: TimeInterval {
      switch self {
      case .following: 1.0 / 30
      case .idle: 0.5
      }
    }
  }

  /// nil when not tracking.
  private(set) var cadence: Cadence?

  var isTracking: Bool { timer != nil }
  var isRowShown: Bool { row != nil }

  var openURL: (URL) -> Void
  /// Front to back, as `PermissionGuideGeometry.settingsWindowBounds` requires.
  var windowList: () -> [[String: Any]]
  var settingsPID: () -> pid_t?
  var frontmostBundleID: () -> String?
  var isGranted: (PermissionPane) -> Bool
  var requestSystemPrompt: (PermissionPane) -> Void
  /// Told when the guide closes on a live grant read. The guide's own read
  /// can be the only one running: the app's Accessibility backstop stands down
  /// once no key mode wants the event tap, so without this the grant could
  /// land with nothing in the app noticing.
  var onGranted: (PermissionPane) -> Void = { _ in }

  nonisolated private static let settingsBundleID = "com.apple.systempreferences"
  /// The grant reads are calls into the privacy database; while following,
  /// every sixth tick (five a second) is already quicker than a person can look
  /// back from the switch they flipped. While idle, every tick reads.
  static let ticksPerGrantRead = 6
  private static let fadeDuration: TimeInterval = 0.18
  /// The System Settings window width measured on 27.2; the guide is laid out
  /// for it until the real window has been seen.
  private static let assumedSettingsWidth: CGFloat = 757
  private static let lineFont = NSFont.systemFont(ofSize: 12, weight: .semibold)
  private static let bobKey = "bob"

  init() {
    openURL = { NSWorkspace.shared.open($0) }
    windowList = {
      CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
        as? [[String: Any]] ?? []
    }
    settingsPID = {
      NSRunningApplication.runningApplications(withBundleIdentifier: PermissionGuide.settingsBundleID)
        .first?.processIdentifier
    }
    frontmostBundleID = { NSWorkspace.shared.frontmostApplication?.bundleIdentifier }
    isGranted = { pane in
      switch pane {
      case .accessibility: AXIsProcessTrustedWithOptions(nil)
      case .screenRecording: CGPreflightScreenCaptureAccess()
      }
    }
    requestSystemPrompt = { pane in
      switch pane {
      case .accessibility:
        // A global constant: unretained, or each call over-releases it.
        let promptKey = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        _ = AXIsProcessTrustedWithOptions([promptKey: true] as CFDictionary)
      case .screenRecording:
        _ = CGRequestScreenCaptureAccess()
      }
    }
  }

  isolated deinit {
    // `isolated` so it can reach the timer and observers at all; the timer block
    // holds `self` weakly, but the run loop would keep firing it.
    stopTracking()
  }

  func request(_ pane: PermissionPane) {
    guard !isGranted(pane) else { return }
    show(pane)
  }

  /// Opens the pane and starts tracking; a second call retargets the one guide.
  /// `requestFirst` supports lists that require a system request before an app
  /// can be added, with switch-only instructions in place of the drag row.
  func show(_ pane: PermissionPane, requestFirst: Bool = false) {
    showing = pane
    tickCount = 0
    lineOnly = requestFirst
    if requestFirst { requestSystemPrompt(pane) }
    openURL(pane.deepLink)
    buildContent()
    // A visible retarget changes the height; waiting for the next tick shows
    // one frame at the old frame.
    if isPanelShown { reposition() }
    if timer == nil { startTracking() }
  }

  func close() {
    stopTracking()
    showing = nil
    settingsSeen = false
    lastSettingsWindow = nil
    setPanelShown(false)
  }

  /// One tracking step. Grant is checked before visibility so the guide closes
  /// even while the person is in another app.
  ///
  /// `activatedBundleID` is the app an activation notification names, which
  /// is authoritative before the frontmost read catches up with it.
  func tick(activatedBundleID: String? = nil) {
    guard let pane = showing else { return }
    defer { tickCount &+= 1 }
    if cadence != .following || tickCount % Self.ticksPerGrantRead == 0, isGranted(pane) {
      close()
      onGranted(pane)
      return
    }
    let pid = settingsPID()
    if pid != nil {
      settingsSeen = true
    } else if settingsSeen {
      // Settings quit without a grant; left running, this would tick for the
      // rest of the session.
      close()
      return
    }
    let settingsFront = (activatedBundleID ?? frontmostBundleID()) == Self.settingsBundleID
    schedule(settingsFront ? .following : .idle)
    guard settingsFront,
      let window = PermissionGuideGeometry.settingsWindowBounds(windowList: windowList(), settingsPID: pid)
    else {
      setPanelShown(false)
      return
    }
    lastSettingsWindow = window
    if panel == nil { buildContent() }
    reposition()
    setPanelShown(true)
  }

  /// The window server's origin is the primary display's top-left, whichever
  /// screen has focus.
  private static var primaryScreenHeight: CGFloat {
    NSScreen.screens.first?.frame.height ?? CGDisplayBounds(CGMainDisplayID()).height
  }

  private func reposition() {
    guard let window = lastSettingsWindow else { return }
    let width = Self.panelWidth(forSettingsWidth: window.width)
    // The line wraps, so a new width can mean a new height.
    if panel?.frame.width != width { buildContent() }
    guard let panel else { return }
    let frame = PermissionGuideGeometry.panelFrame(
      settingsWindowCG: window, mainScreenHeight: Self.primaryScreenHeight, panelHeight: panel.frame.height)
    if panel.frame != frame { panel.setFrame(frame, display: true) }
  }

  private static func panelWidth(forSettingsWidth width: CGFloat) -> CGFloat {
    PermissionGuideGeometry.panelFrame(
      settingsWindowCG: CGRect(x: 0, y: 0, width: width, height: 0), mainScreenHeight: 0, panelHeight: 0
    ).width
  }

  /// After a drop, macOS 27.2 adds Candela already switched on (measured), so
  /// the line never asks for the switch; Screen Recording then offers Quit &
  /// Reopen.
  static func line(for pane: PermissionPane, lineOnly: Bool) -> String {
    if lineOnly { return "Switch Candela on in the list above." }
    switch pane {
    case .accessibility: return "Drag this row into the list above."
    case .screenRecording: return "Drag this row into the list above, then choose Quit & Reopen when macOS asks."
    }
  }

  // MARK: - Tracking

  private func startTracking() {
    schedule(frontmostBundleID() == Self.settingsBundleID ? .following : .idle)
    let workspace = NSWorkspace.shared.notificationCenter
    observers = [
      workspace.addObserver(
        forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
      ) { [weak self] note in
        let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
        guard let bundleID = app?.bundleIdentifier, bundleID == PermissionGuide.settingsBundleID else { return }
        // Delivered on the main queue.
        MainActor.assumeIsolated { self?.tick(activatedBundleID: bundleID) }
      },
      workspace.addObserver(
        forName: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil, queue: .main
      ) { [weak self] _ in
        MainActor.assumeIsolated {
          guard let self, self.isPanelShown else { return }
          self.updateBob(reduceMotion: Motion.systemReduceMotion)
        }
      },
    ]
  }

  private func stopTracking() {
    timer?.invalidate()
    timer = nil
    cadence = nil
    let workspace = NSWorkspace.shared.notificationCenter
    for observer in observers { workspace.removeObserver(observer) }
    observers.removeAll()
  }

  private func schedule(_ cadence: Cadence) {
    guard self.cadence != cadence else { return }
    self.cadence = cadence
    let interval = cadence.interval
    timer?.invalidate()
    // `.common` so the guide keeps tracking while a menu is open. The block is
    // `@Sendable`-typed, so `assumeIsolated` traps if this timer ever lands on
    // another run loop; it goes on `RunLoop.main` and nowhere else.
    let timer = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
      MainActor.assumeIsolated { self?.tick() }
    }
    timer.tolerance = interval * 0.1
    self.timer = timer
    RunLoop.main.add(timer, forMode: .common)
  }

  // MARK: - Visibility

  private func setPanelShown(_ shown: Bool) {
    guard shown != isPanelShown, let panel else { return }
    isPanelShown = shown
    let reduceMotion = Motion.systemReduceMotion
    let duration = reduceMotion ? 0 : Self.fadeDuration
    if shown {
      if duration == 0 { panel.alphaValue = 1 }
      panel.orderFrontRegardless()
      updateBob(reduceMotion: reduceMotion)
      guard duration > 0 else { return }
      NSAnimationContext.runAnimationGroup { context in
        context.duration = duration
        panel.animator().alphaValue = 1
      }
    } else {
      fadeOutAndDiscard(panel, duration: duration)
    }
  }

  /// The outgoing panel is never shown again; the next appearance builds a new
  /// one. Alpha does not stop hit-testing, so the fading panel has to ignore the
  /// mouse or a click just after Done never reaches the Settings list. And
  /// `ignoresMouseEvents` cannot be handed back: setting it false explicitly
  /// (measured) also stops clicks on the transparent rounded corners passing
  /// through, which only the never-set default does.
  private func fadeOutAndDiscard(_ panel: NSPanel, duration: TimeInterval) {
    panel.ignoresMouseEvents = true
    row?.releaseCursor()
    arrow?.layer?.removeAnimation(forKey: Self.bobKey)
    self.panel = nil
    row = nil
    arrow = nil
    doneControl = nil
    lineField = nil
    guard duration > 0 else {
      panel.orderOut(nil)
      return
    }
    NSAnimationContext.runAnimationGroup { context in
      context.duration = duration
      panel.animator().alphaValue = 0
    } completionHandler: {
      // Typed `@Sendable`, but fires on the main thread where the panel lives.
      MainActor.assumeIsolated { panel.orderOut(nil) }
    }
  }

  private func updateBob(reduceMotion: Bool) {
    guard let layer = arrow?.layer else { return }
    if reduceMotion {
      layer.removeAnimation(forKey: Self.bobKey)
      return
    }
    guard layer.animation(forKey: Self.bobKey) == nil else { return }
    let bob = CABasicAnimation(keyPath: "transform.translation.y")
    bob.fromValue = 0
    bob.toValue = 3
    bob.duration = 0.6
    bob.autoreverses = true
    bob.repeatCount = .infinity
    bob.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
    layer.add(bob, forKey: Self.bobKey)
  }

  // MARK: - Content

  private func makePanel() -> NSPanel {
    let panel = GuidePanel(
      contentRect: NSRect(x: 0, y: 0, width: 400, height: PermissionGuideGeometry.panelHeight),
      styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
    panel.level = .floating
    panel.isOpaque = false
    panel.backgroundColor = .clear
    panel.hasShadow = true
    panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
    // Candela deactivates the moment System Settings comes forward; a panel that
    // hid on deactivation would vanish exactly when it is needed.
    panel.hidesOnDeactivate = false
    panel.isReleasedWhenClosed = false
    panel.alphaValue = 0
    panel.title = "Candela permission guide"
    return panel
  }

  /// Laid out for one width: the line wraps, so the height follows the width,
  /// and `reposition` rebuilds when the Settings window's width changes.
  private func buildContent() {
    guard let pane = showing else { return }
    let panel = self.panel ?? makePanel()
    self.panel = panel
    let width = lastSettingsWindow.map { Self.panelWidth(forSettingsWidth: $0.width) }
      ?? Self.panelWidth(forSettingsWidth: Self.assumedSettingsWidth)

    let done = PermissionGuideDoneControl()
    done.action = { [weak self] in self?.close() }
    let doneSize = done.intrinsicContentSize
    let doneInset = PermissionGuideDoneControl.hitPadding
    let capsuleMinX = width - 10 - (doneSize.width - doneInset * 2)

    let line = NSTextField(wrappingLabelWithString: Self.line(for: pane, lineOnly: lineOnly))
    line.font = Self.lineFont
    line.isSelectable = false
    let lineWidth = max(0, capsuleMinX - 8 - 34)
    let lineHeight = ceil(
      line.cell?.cellSize(forBounds: NSRect(x: 0, y: 0, width: lineWidth, height: .greatestFiniteMagnitude)).height
        ?? 16)
    // The arrow's 18 pt box sets the minimum; each extra line adds its own height.
    let block = max(18, lineHeight + 1)
    let height = lineOnly ? block + 22 : block + 74
    let size = NSSize(width: width, height: height)
    // Bottom-left origin kept: the bottom edge is the one docked to the window.
    panel.setFrame(NSRect(origin: panel.frame.origin, size: size), display: false)

    let blur = NSVisualEffectView(frame: NSRect(origin: .zero, size: size))
    blur.material = .popover
    blur.blendingMode = .behindWindow
    blur.state = .active
    blur.wantsLayer = true
    blur.layer?.cornerRadius = 14
    blur.layer?.masksToBounds = true
    blur.autoresizingMask = [.width, .height]

    let firstLineY = height - 10 - 18
    let arrow = NSImageView(
      image: NSImage(systemSymbolName: "arrow.up", accessibilityDescription: nil) ?? NSImage())
    arrow.symbolConfiguration = .init(pointSize: 13, weight: .bold)
    arrow.contentTintColor = .controlAccentColor
    arrow.frame = NSRect(x: 12, y: firstLineY, width: 18, height: 18)
    arrow.wantsLayer = true
    // Decoration: the line beside it says "above". The cell is what VoiceOver
    // reads for an image view, so hiding the view alone still announces "Up".
    arrow.setAccessibilityElement(false)
    arrow.cell?.setAccessibilityElement(false)
    blur.addSubview(arrow)

    line.frame = NSRect(x: 34, y: height - 11 - lineHeight, width: lineWidth, height: lineHeight)
    blur.addSubview(line)

    // Level with the first line however many the text wraps to.
    done.frame = NSRect(
      x: capsuleMinX - doneInset, y: firstLineY + (18 - doneSize.height) / 2,
      width: doneSize.width, height: doneSize.height)
    blur.addSubview(done)

    var row: PermissionGuideRow?
    if !lineOnly {
      let newRow = PermissionGuideRow(
        frame: NSRect(x: 8, y: 10, width: width - 16, height: PermissionGuideRow.height),
        bundleURL: Bundle.main.bundleURL, displayName: Self.displayName)
      blur.addSubview(newRow)
      row = newRow
    }

    panel.contentView = blur
    self.arrow = arrow
    self.row = row
    lineField = line
    doneControl = done
    if isPanelShown { updateBob(reduceMotion: Motion.systemReduceMotion) }
  }

  private static var displayName: String {
    let info = Bundle.main.infoDictionary
    return info?["CFBundleDisplayName"] as? String ?? info?["CFBundleName"] as? String ?? "Candela"
  }
}

/// Follows a window that can hang partly off screen. AppKit's constraint would
/// pull the guide back on screen and away from the list it points at.
private final class GuidePanel: NSPanel {
  override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
}

/// Drawn by hand because the guide's panel never becomes key: an `NSButton`
/// there renders in its inactive, dimmed state, which read as disabled.
final class PermissionGuideDoneControl: NSView {
  var action: (() -> Void)?
  private var isPressed = false {
    didSet { needsDisplay = true }
  }

  /// Clickable margin around the drawn capsule; a 20 pt target is a small one.
  static let hitPadding: CGFloat = 4
  private static let title = "Done"
  private static let font = NSFont.systemFont(ofSize: 12, weight: .semibold)
  private static let horizontalPadding: CGFloat = 10
  private static let capsuleHeight: CGFloat = 20

  override init(frame: NSRect) {
    super.init(frame: frame)
    setAccessibilityElement(true)
    setAccessibilityRole(.button)
    setAccessibilityLabel(Self.title)
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

  override var intrinsicContentSize: NSSize {
    let text = (Self.title as NSString).size(withAttributes: [.font: Self.font])
    return NSSize(
      width: ceil(text.width) + (Self.horizontalPadding + Self.hitPadding) * 2,
      height: Self.capsuleHeight + Self.hitPadding * 2)
  }

  override func draw(_ dirtyRect: NSRect) {
    let capsule = bounds.insetBy(dx: Self.hitPadding, dy: Self.hitPadding)
    let fill = isPressed
      ? NSColor.controlAccentColor.blended(withFraction: 0.2, of: .black) ?? .controlAccentColor
      : NSColor.controlAccentColor
    fill.setFill()
    NSBezierPath(roundedRect: capsule, xRadius: capsule.height / 2, yRadius: capsule.height / 2).fill()
    let attributes: [NSAttributedString.Key: Any] = [
      .font: Self.font, .foregroundColor: NSColor.alternateSelectedControlTextColor,
    ]
    let text = (Self.title as NSString).size(withAttributes: attributes)
    let origin = NSPoint(x: capsule.midX - text.width / 2, y: capsule.midY - text.height / 2)
    (Self.title as NSString).draw(at: origin, withAttributes: attributes)
  }

  override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

  override func mouseDown(with event: NSEvent) { isPressed = true }

  override func mouseDragged(with event: NSEvent) {
    isPressed = bounds.contains(convert(event.locationInWindow, from: nil))
  }

  override func mouseUp(with event: NSEvent) {
    let fire = isPressed && bounds.contains(convert(event.locationInWindow, from: nil))
    isPressed = false
    if fire { action?() }
  }

  override func accessibilityPerformPress() -> Bool {
    action?()
    return true
  }
}
