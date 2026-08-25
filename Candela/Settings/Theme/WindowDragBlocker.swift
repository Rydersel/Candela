import SwiftUI

/// Exempts a region of the settings window from move-by-background dragging.
///
/// The window is `isMovableByWindowBackground`, which is deliberate: the card
/// deadspace, the empty canvas and the sidebar are all drag handles. AppKit
/// decides that per mouse-down by asking the view it hit whether it may move
/// the window, and `NSHostingView` answers yes for everything SwiftUI draws
/// inside it. So a SwiftUI `DragGesture` on drawn content loses the mouse-down
/// to the window move before it ever starts, whatever `minimumDistance` it
/// asks for.
///
/// This puts a real `NSView` behind the region that answers no, so the region
/// keeps its own drag. It overrides no event method, so the mouse-down it is
/// hit with travels on to the hosting view by the normal responder chain and
/// SwiftUI's gestures still see it: the only thing this view changes is
/// AppKit's answer to "may this drag move the window".
private struct WindowDragBlocker: NSViewRepresentable {
  func makeNSView(context: Context) -> NSView { BlockingView() }

  func updateNSView(_ view: NSView, context: Context) {}

  private final class BlockingView: NSView {
    override var mouseDownCanMoveWindow: Bool { false }
  }
}

extension View {
  /// Keeps mouse-downs on this view out of the window's move-by-background
  /// handling, so a drag here drives the control rather than the window.
  ///
  /// Applied to interactive regions only: a drawn slider, the arrangement map,
  /// a segmented control. Never to a whole page or a scroll view, which would
  /// take the window's approved drag handles away with it.
  func blocksWindowDrag() -> some View { background(WindowDragBlocker()) }
}
