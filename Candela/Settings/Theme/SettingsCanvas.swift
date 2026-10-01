import SwiftUI

/// The drifting glow ground under every settings page, tinted per destination.
/// The Heat Map window draws it too, as its own window's ground.
///
/// The window keeps ONE canvas alive across every selection so the light moves
/// rather than cutting to a new one. Reduce Motion holds it at its first frame.
/// A non-key window holds the frame it froze on, so the drift resumes where it
/// stopped. Stricter than the poller's consumer threshold on purpose: only the
/// focused window pays for the animation.
struct SettingsCanvas: View {
  var accent: Color
  var secondary: Color

  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @Environment(\.controlActiveState) private var activeState

  /// Off-key time is discounted from the drift clock, so coming back resumes the
  /// motion instead of jumping it forward.
  @State private var offKeySince: Date?
  @State private var offKeyTotal: TimeInterval = 0
  @State private var tick = Date.now

  var body: some View {
    ZStack {
      Color(red: 0.035, green: 0.035, blue: 0.06)
      if reduceMotion {
        blobs(at: 0)
      } else if activeState == .key {
        // On macOS 26 a TimelineView in a hosting view cost a full window layout per
        // display cycle under every schedule tried (12 to 16% of a core, key on the
        // General pane), so the drift is ticked by a task at the frame rate instead.
        // 4 fps: blob 1's x, the fastest term, moves about 1 pt a frame in an
        // 1100 pt window; under a ~200 pt blur ramp that is a quarter of an 8-bit
        // step. Each frame costs two full-window Gaussian blurs.
        blobs(at: drift(at: tick))
      } else {
        // A CLOSED window lands here too: the object outlives the close and used
        // to pay for two blurs on every frame forever.
        blobs(at: drift(at: offKeySince ?? .now))
      }
      RadialGradient(
        colors: [.clear, Color.black.opacity(0.5)],
        center: .center, startRadius: 220, endRadius: 640
      )
    }
    .ignoresSafeArea()
    .accessibilityHidden(true)
    .task(id: activeState == .key && !reduceMotion) {
      guard activeState == .key, !reduceMotion else { return }
      // Reduce Motion turning off while key leaves the tick as old as when it
      // turned on; without this the first frame is stale for a whole interval.
      tick = .now
      while true {
        do {
          try await Task.sleep(for: .milliseconds(250), tolerance: .milliseconds(25))
        } catch {
          return
        }
        guard !Task.isCancelled else { return }
        tick = .now
      }
    }
    .onAppear { if activeState != .key, offKeySince == nil { offKeySince = .now } }
    .onChange(of: activeState) { _, state in
      if state == .key {
        if let since = offKeySince { offKeyTotal += Date.now.timeIntervalSince(since) }
        offKeySince = nil
        // Same update as the offKeyTotal bump, or the first key frame renders a
        // stale tick against the new total and jumps back by the off-key time.
        tick = .now
      } else if offKeySince == nil {
        // The last tick, not now: the frozen frame is the one drawn at that tick,
        // so resume picks up exactly where the motion stopped.
        offKeySince = tick
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
