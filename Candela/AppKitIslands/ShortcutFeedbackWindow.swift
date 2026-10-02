import AppKit

/// Brief, nonactivating feedback for a shortcut that has no visible control.
@MainActor
final class ShortcutFeedbackWindow {
  private var panel: NSPanel?
  private var dismissal: Timer?

  func show(_ message: String, on screen: NSScreen?) {
    dismissal?.invalidate()
    panel?.orderOut(nil)
    // Resolve a fresh screen after the HDR await; a disconnected NSScreen can
    // retain a frame outside every remaining display.
    let screens = NSScreen.screens
    let pointer = NSEvent.mouseLocation
    guard let screen = screens.first(where: { $0.displayID == screen?.displayID })
      ?? screens.first(where: { NSMouseInRect(pointer, $0.frame, false) })
      ?? NSScreen.main else { return }
    let width = min(360, screen.visibleFrame.width - 40)
    let (material, label) = Self.content(for: message, width: width)
    let height = material.frame.height
    let rect = NSRect(x: screen.visibleFrame.midX - width / 2,
                      y: screen.visibleFrame.minY + 80, width: width, height: height)
    let panel = NSPanel(contentRect: rect, styleMask: [.borderless, .nonactivatingPanel],
                        backing: .buffered, defer: false)
    panel.isOpaque = false
    panel.backgroundColor = .clear
    panel.hasShadow = true
    panel.level = .statusBar
    panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
    panel.ignoresMouseEvents = true
    panel.contentView = material
    self.panel = panel
    panel.orderFrontRegardless()
    NSAccessibility.post(element: label, notification: .announcementRequested,
                         userInfo: [.announcement: message, .priority: NSAccessibilityPriorityLevel.medium.rawValue])
    let timer = Timer(timeInterval: 3, repeats: false) { [weak self] _ in
      MainActor.assumeIsolated { self?.panel?.orderOut(nil) }
    }
    dismissal = timer
    RunLoop.main.add(timer, forMode: .common)
  }

  /// Kept separate so wrapping can be measured without displaying a window.
  static func content(for message: String, width: CGFloat) -> (NSVisualEffectView, NSTextField) {
    let label = NSTextField(wrappingLabelWithString: message)
    label.font = .systemFont(ofSize: 14, weight: .medium)
    label.alignment = .center
    label.textColor = .labelColor
    label.translatesAutoresizingMaskIntoConstraints = false
    label.preferredMaxLayoutWidth = max(1, width - 40)
    let material = NSVisualEffectView()
    material.material = .hudWindow
    material.state = .active
    material.wantsLayer = true
    material.layer?.cornerRadius = 14
    material.layer?.masksToBounds = true
    material.addSubview(label)
    NSLayoutConstraint.activate([
      material.widthAnchor.constraint(equalToConstant: width),
      label.leadingAnchor.constraint(equalTo: material.leadingAnchor, constant: 20),
      label.trailingAnchor.constraint(equalTo: material.trailingAnchor, constant: -20),
      label.topAnchor.constraint(equalTo: material.topAnchor, constant: 18),
      label.bottomAnchor.constraint(equalTo: material.bottomAnchor, constant: -18),
    ])
    material.frame = NSRect(x: 0, y: 0, width: width, height: 80)
    material.setFrameSize(NSSize(width: width, height: max(60, material.fittingSize.height)))
    material.layoutSubtreeIfNeeded()
    return (material, label)
  }
}
