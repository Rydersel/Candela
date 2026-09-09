import SwiftUI

/// The drifting glow ground under every settings page, tinted per destination.
/// The Heat Map window draws it too, as its own window's ground.
///
/// The window keeps ONE canvas alive across every selection so the light moves
/// rather than cutting to a new one. Reduce Motion holds it at its first frame.
/// A non-key window holds the frame it froze on, so the drift resumes where it
/// stopped. Stricter than the poller's consumer threshold on purpose: only the
/// focused window has to pay for 12 frames a second.
struct SettingsCanvas: View {
  var accent: Color
  var secondary: Color

  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @Environment(\.controlActiveState) private var activeState

  /// Off-key time is discounted from the drift clock, so coming back resumes the
  /// motion instead of jumping it forward.
  @State private var offKeySince: Date?
  @State private var offKeyTotal: TimeInterval = 0

  var body: some View {
    ZStack {
      Color(red: 0.035, green: 0.035, blue: 0.06)
      if reduceMotion {
        blobs(at: 0)
      } else if activeState == .key {
        // 12 fps: a blob centre moves about a third of a point per frame, and
        // each frame costs two full-window Gaussian blurs.
        TimelineView(.animation(minimumInterval: 1.0 / 12.0)) { context in
          blobs(at: drift(at: context.date))
        }
      } else {
        // A CLOSED window lands here too: the object outlives the close and used
        // to pay for two blurs 12 times a second forever.
        blobs(at: drift(at: offKeySince ?? .now))
      }
      RadialGradient(
        colors: [.clear, Color.black.opacity(0.5)],
        center: .center, startRadius: 220, endRadius: 640
      )
    }
    .ignoresSafeArea()
    .accessibilityHidden(true)
    .onAppear { if activeState != .key, offKeySince == nil { offKeySince = .now } }
    .onChange(of: activeState) { _, state in
      if state == .key {
        if let since = offKeySince { offKeyTotal += Date.now.timeIntervalSince(since) }
        offKeySince = nil
      } else if offKeySince == nil {
        offKeySince = .now
      }
    }
  }

  private func drift(at date: Date) -> TimeInterval {
    date.timeIntervalSinceReferenceDate - offKeyTotal
  }

  private func blobs(at time: TimeInterval) -> some View {
    GeometryReader { proxy in
      let size = proxy.size
      let t1 = time / 26
      let t2 = time / 34
      ZStack {
        Circle()
          .fill(accent.opacity(0.21))
          .frame(width: size.width * 0.8)
          .blur(radius: 100)
          .position(
            x: size.width * (0.32 + 0.10 * CGFloat(sin(t1))),
            y: size.height * (0.20 + 0.08 * CGFloat(cos(t1 * 1.3)))
          )
        Circle()
          .fill(secondary.opacity(0.15))
          .frame(width: size.width * 0.7)
          .blur(radius: 110)
          .position(
            x: size.width * (0.80 - 0.09 * CGFloat(cos(t2))),
            y: size.height * (0.88 + 0.07 * CGFloat(sin(t2 * 1.7)))
          )
      }
      // Keyed on BOTH hues. Two destinations can share a primary accent and
      // differ only in the secondary; keyed on `accent` alone the second blob
      // cut to its new colour instead of relighting.
      .animation(
        SettingsTheme.canvasRelight,
        value: SettingsAccent(accent: accent, secondary: secondary))
    }
  }
}
