import SwiftUI

/// A translucent chrome surface, in whatever the running system's best form is.
///
/// macOS 26 gets real Liquid Glass via `glassEffect`. Everything down to the
/// 14.0 deployment floor gets a standard material, which is the same idea one
/// generation earlier — so this is a graceful degradation, not a feature gate,
/// and no call site needs an availability check of its own.
///
/// Why not an `NSVisualEffectView`: the settings window has NO sidebar-material
/// effect view to configure. Dumping the live hierarchy showed every
/// `NSVisualEffectView` in it is `.contentBackground`, full window width, and
/// already pinned to `.active` — SwiftUI draws the sidebar's own surface, and
/// that is what dims when the window loses focus. Reaching for AppKit therefore
/// cannot fix the dimming; owning the surface can.
///
/// Deliberately applied to the CONTROL layer only (sidebar, toolbar). The HIG
/// is explicit that Liquid Glass does not belong in the content layer, and this
/// window is full of 11-pt secondary text that must not sit on a surface whose
/// contrast depends on the desktop behind it.
struct GlassSurface: ViewModifier {
  var cornerRadius: CGFloat = 10

  func body(content: Content) -> some View {
    if #available(macOS 26.0, *) {
      content.glassEffect(.regular, in: .rect(cornerRadius: cornerRadius))
    } else {
      content.background(
        .ultraThinMaterial,
        in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
      )
    }
  }
}

extension View {
  /// Chrome-layer translucency. See `GlassSurface`.
  func glassSurface(cornerRadius: CGFloat = 10) -> some View {
    modifier(GlassSurface(cornerRadius: cornerRadius))
  }
}
