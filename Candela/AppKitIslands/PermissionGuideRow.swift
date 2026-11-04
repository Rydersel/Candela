import AppKit

/// A copy of one row of the System Settings permission list, so it reads as
/// "this goes in there". Dragging it carries the app bundle's file URL, which is
/// what the list accepts in place of the "+" picker.
final class PermissionGuideRow: NSView, NSDraggingSource {
  static let height: CGFloat = 44

  private let bundleURL: URL
  private var ownsCursor = false

  init(frame: NSRect, bundleURL: URL, displayName: String) {
    self.bundleURL = bundleURL
    super.init(frame: frame)
    wantsLayer = true
    layer?.cornerRadius = 10
    layer?.borderWidth = 1.5

    let grip = NSImageView(
      image: NSImage(systemSymbolName: "line.3.horizontal", accessibilityDescription: nil) ?? NSImage())
    grip.contentTintColor = .tertiaryLabelColor
    grip.frame = NSRect(x: 10, y: (frame.height - 14) / 2, width: 14, height: 14)
    addSubview(grip)

    let icon = NSImageView(image: NSWorkspace.shared.icon(forFile: bundleURL.path))
    icon.frame = NSRect(x: 30, y: (frame.height - 24) / 2, width: 24, height: 24)
    addSubview(icon)

    let name = NSTextField(labelWithString: displayName + ".app")
    name.font = .systemFont(ofSize: 13)
    name.sizeToFit()
    name.frame.origin = NSPoint(x: 64, y: (frame.height - name.frame.height) / 2)
    addSubview(name)

    setAccessibilityElement(true)
    setAccessibilityRole(.image)
    setAccessibilityLabel(displayName + ".app")
    setAccessibilityHelp("Drag this row into the list above.")
    // Not cursor rects or `.cursorUpdate`: both need a key window or the active
    // app, and this panel is neither. `.activeAlways` covers entered/exited only.
    addTrackingArea(NSTrackingArea(
      rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

  override var wantsUpdateLayer: Bool { true }

  // Layer colours are resolved CGColors; re-resolving here follows a light/dark switch.
  override func updateLayer() {
    effectiveAppearance.performAsCurrentDrawingAppearance {
      let dark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
      layer?.backgroundColor = NSColor(white: dark ? 1 : 0, alpha: dark ? 0.07 : 0.04).cgColor
      layer?.borderColor = NSColor.controlAccentColor.withAlphaComponent(0.9).cgColor
    }
  }

  // One element: the grip, icon and name would otherwise each be read, the name twice.
  override func accessibilityChildren() -> [Any]? { [] }

  // The grip, icon and label must not swallow the drag.
  override func hitTest(_ point: NSPoint) -> NSView? {
    frame.contains(point) ? self : nil
  }

  // Never key; without this the first press is swallowed.
  override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

  override func mouseEntered(with event: NSEvent) {
    ownsCursor = true
    NSCursor.openHand.set()
  }

  override func mouseExited(with event: NSEvent) { releaseCursor() }

  /// An ordered-out window gets no exit event, so hiding under the pointer
  /// would leave the open hand over System Settings.
  func releaseCursor() {
    guard ownsCursor else { return }
    ownsCursor = false
    NSCursor.arrow.set()
  }

  override func mouseDragged(with event: NSEvent) {
    guard let rep = bitmapImageRepForCachingDisplay(in: bounds) else { return }
    cacheDisplay(in: bounds, to: rep)
    let snapshot = NSImage(size: bounds.size)
    snapshot.addRepresentation(rep)
    let item = NSDraggingItem(pasteboardWriter: bundleURL as NSURL)
    item.setDraggingFrame(bounds, contents: snapshot)
    beginDraggingSession(with: [item], event: event, source: self)
  }

  func draggingSession(
    _ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext
  ) -> NSDragOperation {
    .copy
  }
}
