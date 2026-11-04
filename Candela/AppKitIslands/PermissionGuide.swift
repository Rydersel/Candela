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
  private var fadeGeneration = 0

  var isTracking: Bool { timer != nil }
  var isRowShown: Bool { row != nil }

  var openURL: (URL) -> Void
  /// Front to back, as `PermissionGuideGeometry.settingsWindowBounds` requires.
  var windowList: () -> [[String: Any]]
  var settingsPID: () -> pid_t?
  var frontmostBundleID: () -> String?
  var isGranted: (PermissionPane) -> Bool
  var requestSystemPrompt: (PermissionPane) -> Void

  private static let settingsBundleID = "com.apple.systempreferences"
  private static let tickInterval: TimeInterval = 1.0 / 30
  /// The grant reads are calls into the privacy database; five a second is
  /// already quicker than a person can look back from the switch they flipped.
  private static let ticksPerGrantRead = 6
  private static let fadeDuration: TimeInterval = 0.18
  private static let lineOnlyHeight: CGFloat = 40

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
        let promptKey = kAXTrustedCheckOptionPrompt.takeRetainedValue() as String
        _ = AXIsProcessTrustedWithOptions([promptKey: true] as CFDictionary)
      case .screenRecording:
        _ = CGRequestScreenCaptureAccess()
      }
    }
  }

  /// Opens the pane and starts tracking; a second call retargets the one guide.
  ///
  /// `requestFirst` is the fallback for a list that refuses a dropped app that
  /// never asked: the system request adds Candela switched off, so there is no
  /// row to offer and the line asks for the switch instead.
  func show(_ pane: PermissionPane, requestFirst: Bool = false) {
    showing = pane
    tickCount = 0
    if requestFirst { requestSystemPrompt(pane) }
    openURL(pane.deepLink)
    buildContent(lineOnly: requestFirst)
    if timer == nil { startTimer() }
  }

  func close() {
    timer?.invalidate()
    timer = nil
    showing = nil
    settingsSeen = false
    setPanelShown(false)
  }

  /// One tracking step. Grant is checked before visibility so the guide closes
  /// even while the person is in another app.
  func tick() {
    guard let pane = showing else { return }
    defer { tickCount &+= 1 }
    if tickCount % Self.ticksPerGrantRead == 0, isGranted(pane) {
      close()
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
    guard frontmostBundleID() == Self.settingsBundleID,
      let window = PermissionGuideGeometry.settingsWindowBounds(windowList: windowList(), settingsPID: pid),
      let panel
    else {
      setPanelShown(false)
      return
    }
    let frame = PermissionGuideGeometry.panelFrame(
      settingsWindowCG: window, mainScreenHeight: Self.primaryScreenHeight, panelHeight: panel.frame.height)
    if panel.frame != frame { panel.setFrame(frame, display: true) }
    setPanelShown(true)
  }

  /// The window server's origin is the primary display's top-left, whichever
  /// screen has focus.
  private static var primaryScreenHeight: CGFloat {
    NSScreen.screens.first?.frame.height ?? CGDisplayBounds(CGMainDisplayID()).height
  }

  private func startTimer() {
    // `.common` so the guide keeps tracking while a menu is open. The block is
    // `@Sendable`-typed, so `assumeIsolated` traps if this timer ever lands on
    // another run loop; it goes on `RunLoop.main` and nowhere else.
    let timer = Timer(timeInterval: Self.tickInterval, repeats: true) { [weak self] _ in
      MainActor.assumeIsolated { self?.tick() }
    }
    self.timer = timer
    RunLoop.main.add(timer, forMode: .common)
  }

  private func setPanelShown(_ shown: Bool) {
    guard shown != isPanelShown, let panel else { return }
    isPanelShown = shown
    fadeGeneration &+= 1
    let generation = fadeGeneration
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
      // Ordered out, not left at alpha 0: alpha does not stop hit-testing, and
      // an invisible panel would swallow clicks on the Settings list.
      guard duration > 0 else {
        panel.alphaValue = 0
        panel.orderOut(nil)
        return
      }
      NSAnimationContext.runAnimationGroup { context in
        context.duration = duration
        panel.animator().alphaValue = 0
      } completionHandler: { [weak self] in
        // Typed `@Sendable`, but fires on the main thread where the panel lives.
        MainActor.assumeIsolated {
          // A show that arrived mid-fade owns the window now.
          guard let self, self.fadeGeneration == generation else { return }
          panel.orderOut(nil)
        }
      }
    }
  }

  private func updateBob(reduceMotion: Bool) {
    guard let layer = arrow?.layer else { return }
    if reduceMotion {
      layer.removeAnimation(forKey: "bob")
      return
    }
    guard layer.animation(forKey: "bob") == nil else { return }
    let bob = CABasicAnimation(keyPath: "transform.translation.y")
    bob.fromValue = 0
    bob.toValue = 3
    bob.duration = 0.6
    bob.autoreverses = true
    bob.repeatCount = .infinity
    bob.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
    layer.add(bob, forKey: "bob")
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

  private func buildContent(lineOnly: Bool) {
    let panel = self.panel ?? makePanel()
    self.panel = panel
    let height = lineOnly ? Self.lineOnlyHeight : PermissionGuideGeometry.panelHeight
    let size = NSSize(width: panel.frame.width, height: height)
    var frame = panel.frame
    frame.origin.y += frame.height - height
    frame.size = size
    panel.setFrame(frame, display: false)

    let blur = NSVisualEffectView(frame: NSRect(origin: .zero, size: size))
    blur.material = .popover
    blur.blendingMode = .behindWindow
    blur.state = .active
    blur.wantsLayer = true
    blur.layer?.cornerRadius = 14
    blur.layer?.masksToBounds = true
    blur.autoresizingMask = [.width, .height]

    let lineY = height - 10 - 18
    let arrow = NSImageView(
      image: NSImage(systemSymbolName: "arrow.up", accessibilityDescription: nil) ?? NSImage())
    arrow.symbolConfiguration = .init(pointSize: 13, weight: .bold)
    arrow.contentTintColor = .controlAccentColor
    arrow.frame = NSRect(x: 12, y: lineY, width: 18, height: 18)
    arrow.wantsLayer = true
    blur.addSubview(arrow)

    let done = PermissionGuideDoneControl()
    done.action = { [weak self] in self?.close() }
    let doneSize = done.intrinsicContentSize
    done.frame = NSRect(
      x: size.width - doneSize.width - 10, y: lineY + (18 - doneSize.height) / 2,
      width: doneSize.width, height: doneSize.height)
    done.autoresizingMask = [.minXMargin]
    blur.addSubview(done)

    let line = NSTextField(
      labelWithString: lineOnly
        ? "Switch Candela on in the list above."
        : "Drag this row into the list above, then switch it on.")
    line.font = .systemFont(ofSize: 12, weight: .semibold)
    line.lineBreakMode = .byTruncatingTail
    line.frame = NSRect(x: 34, y: lineY, width: max(0, done.frame.minX - 34 - 8), height: 17)
    line.autoresizingMask = [.width]
    blur.addSubview(line)

    var row: PermissionGuideRow?
    if !lineOnly {
      let newRow = PermissionGuideRow(
        frame: NSRect(x: 8, y: 10, width: size.width - 16, height: PermissionGuideRow.height),
        bundleURL: Bundle.main.bundleURL, displayName: Self.displayName)
      newRow.autoresizingMask = [.width]
      blur.addSubview(newRow)
      row = newRow
    }

    panel.contentView = blur
    self.arrow = arrow
    self.row = row
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

  private static let title = "Done"
  private static let font = NSFont.systemFont(ofSize: 12, weight: .semibold)
  private static let horizontalPadding: CGFloat = 10
  private static let height: CGFloat = 20

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
    return NSSize(width: ceil(text.width) + Self.horizontalPadding * 2, height: Self.height)
  }

  override func draw(_ dirtyRect: NSRect) {
    let fill = isPressed
      ? NSColor.controlAccentColor.blended(withFraction: 0.2, of: .black) ?? .controlAccentColor
      : NSColor.controlAccentColor
    fill.setFill()
    NSBezierPath(roundedRect: bounds, xRadius: bounds.height / 2, yRadius: bounds.height / 2).fill()
    let attributes: [NSAttributedString.Key: Any] = [.font: Self.font, .foregroundColor: NSColor.white]
    let text = (Self.title as NSString).size(withAttributes: attributes)
    let origin = NSPoint(x: (bounds.width - text.width) / 2, y: (bounds.height - text.height) / 2)
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
