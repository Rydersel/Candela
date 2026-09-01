import AppKit
import SwiftUI

/// Overlay scrollers for the enclosing scroll view, whatever the system's
/// "Show scroll bars" preference says.
///
/// SwiftUI's `scrollIndicators` can hide the bar or follow the system, but not
/// ask for the overlay style on its own; with the preference set to Always, a
/// legacy bar sits in the window's edge for its whole life. Place this view
/// anywhere inside the scrolled content: it walks up to the `NSScrollView`
/// SwiftUI hosts and switches it to overlay, so the bar shows while scrolling
/// and fades afterwards. AppKit re-applies the preferred style whenever that
/// preference changes, so the override listens for the change and re-applies
/// too.
struct OverlayScrollers: NSViewRepresentable {
  func makeNSView(context: Context) -> OverlayScrollerProbe {
    OverlayScrollerProbe()
  }

  func updateNSView(_ nsView: OverlayScrollerProbe, context: Context) {
    nsView.apply()
  }
}

final class OverlayScrollerProbe: NSView {
  private var observing = false

  override func viewDidMoveToWindow() {
    super.viewDidMoveToWindow()
    apply()
    observe()
  }

  override func viewDidMoveToSuperview() {
    super.viewDidMoveToSuperview()
    apply()
  }

  @objc func apply() {
    var candidate: NSView? = superview
    while let view = candidate, !(view is NSScrollView) {
      candidate = view.superview
    }
    guard let scroll = candidate as? NSScrollView else { return }
    if scroll.scrollerStyle != .overlay {
      scroll.scrollerStyle = .overlay
    }
  }

  // Selector-based so there is no token to store: NSObject observers are
  // unregistered automatically when the view deallocates.
  private func observe() {
    guard !observing else { return }
    observing = true
    NotificationCenter.default.addObserver(
      self, selector: #selector(apply),
      name: NSScroller.preferredScrollerStyleDidChangeNotification, object: nil)
  }
}
