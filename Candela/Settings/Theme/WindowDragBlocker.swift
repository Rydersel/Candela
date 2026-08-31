import SwiftUI

/// Exempts a region of the settings window from move-by-background dragging.
///
/// The window is deliberately `isMovableByWindowBackground`. AppKit decides per
/// mouse-down by asking the hit view, and `NSHostingView` says yes for
/// everything SwiftUI draws, so a `DragGesture` on drawn content loses the
/// mouse-down to the window move whatever `minimumDistance` it asks for.
///
/// This puts a real `NSView` behind the region that answers no. It overrides no
/// event method, so the mouse-down still reaches the hosting view and SwiftUI's
/// gestures still see it.
private struct WindowDragBlocker: NSViewRepresentable {
  func makeNSView(context: Context) -> NSView { BlockingView() }

  func updateNSView(_ view: NSView, context: Context) {}

  private final class BlockingView: NSView {
    override var mouseDownCanMoveWindow: Bool { false }
  }
}

extension View {
  /// Keeps mouse-downs here out of the window's move-by-background handling,
  /// so a drag drives the control rather than the window.
  ///
  /// Interactive regions only. Never a whole page or a scroll view, which would
  /// take the window's drag handles with it.
  func blocksWindowDrag() -> some View { background(WindowDragBlocker()) }
}
