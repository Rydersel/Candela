import CandelaKit
import SwiftUI

/// The two cards that state, in words, what the exposure map only draws: the
/// hottest area's measured multiple, and the display time each app booked.
///
/// They lived in the Display Health window until 2026-08-20, when Ryder moved
/// them onto a display's OLED Care page, directly above the dimming settings
/// they inform. The window keeps the instruments (the map, the History and
/// Right now lens, the legend, the crosshair, Delete History); these two carry
/// findings rather than instruments, and a finding belongs beside the settings
/// it argues for. Their copy and their accessibility are unchanged by the
/// move: both surfaces were hardware-verified as they read here.
///
/// Copy rule, the reason most of this file is text (OC11): software has two
/// levers against OLED wear, reduce luminance and reduce time at luminance.
/// Nothing here may translate a measurement into a lifespan, a date, a
/// percentage of damage avoided or a score. Relative exposure is measured and
/// therefore sayable; everything else on offer is not.

/// The measured ratio of one area against the display's own average, and where
/// it is. Renders nothing at all unless there is a measured multiple to state:
/// under `minimumSamplesForAnalysis` readings there is nothing to be right
/// about, and an estimate may never wear this card's certainty.
struct PanelHottestAreaCard: View {
  let summary: PanelHealthSummary

  /// The phrase this card exists to show, or nil when there is none. One
  /// function for the gate and for the body, so a card can never draw its
  /// frame around a missing number.
  static func multiple(_ summary: PanelHealthSummary) -> String? {
    guard summary.confidence == .measured, let relative = summary.hottestRelative else {
      return nil
    }
    return PanelHealthCopy.multiple(relative)
  }

  var body: some View {
    if let multiple = Self.multiple(summary) {
      SettingsCardSection(title: "The hottest area") {
        VStack(alignment: .leading, spacing: 6) {
          // The one number this whole feature is allowed to state: a measured
          // ratio of a panel against itself. It is not a lifespan, a date or a
          // score, and it must never grow into one.
          HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(verbatim: multiple)
              .font(.title2.weight(.semibold))
              .monospacedDigit()
              .foregroundStyle(SettingsTheme.titleColor)
            Text("this display's average")
              .foregroundStyle(SettingsTheme.bodyColor)
          }

          if let region = OledPanelGeometry.hottestIndex(summary.cells).map(Self.regionPhrase) {
            SettingsCaption(verbatim: "Marked on the map, \(region).")
          }

          // Past tense, deliberately. The snapshot behind this is up to a
          // minute old, so "right now" is a claim the data cannot support even
          // though the summary withholds the owner entirely once observation is
          // off.
          if let owner = summary.hottestOwner {
            SettingsCaption(
              verbatim: "\(owner) was on that part of the display at the last reading.")
          }
        }
      }
    }
  }

  private static func regionPhrase(_ index: Int) -> String {
    PanelHealthCopy.region(cell: index) ?? ""
  }
}

/// Display time per app, from window observation.
///
/// Rendered from whatever the summary carries, with an explicit empty case:
/// the producer for this series is wired separately from the view, so the
/// section must assume neither that it is populated nor that it is not.
///
/// **Not labelled by `confidence`.** That describes the luminance telemetry
/// only; these hours come from window observation, which is a separate pref
/// and needs no permission, so they are measured whether or not brightness
/// is. Calling them an estimate here would be as wrong as calling them
/// measured on the other side.
struct PanelDisplayTimeCard: View {
  let summary: PanelHealthSummary

  var body: some View {
    let owners = summary.topOwnersByHours
    VStack(alignment: .leading, spacing: 6) {
      SettingsCardSection(title: "Display time by app") {
        ownerRows(owners)
      }

      // The figure is display-time, NOT how long the app was open: an app
      // filling the display books an hour per hour, one covering a quarter
      // books fifteen minutes. Saying "Ghostty was open for 3 hours" would be a
      // claim this does not measure, so the caption states the weighting
      // outright.
      SettingsCaption(
        "Weighted by how much of the display each app's windows covered, so this is not how long the app was open. Read from window positions and owner names only (never window titles, and never their contents), and only while the display is awake and undimmed."
      )
    }
  }

  @ViewBuilder private func ownerRows(_ owners: [(owner: String, hours: Double)]) -> some View {
    VStack(alignment: .leading, spacing: 8) {
      if owners.isEmpty {
        SettingsCaption("No data yet.")
      } else {
        // Index-keyed: the elements are tuples, which cannot be `Identifiable`,
        // and an owner name is not guaranteed unique across the list.
        // The bar is proportional to the LIST's own leader, so the top row is
        // always full and the rest read against it; an absolute scale would
        // need a total this list deliberately truncates.
        let leader = owners.map(\.hours).max() ?? 0
        ForEach(Array(owners.enumerated()), id: \.offset) { _, entry in
          VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
              Text(verbatim: entry.owner)
                .foregroundStyle(SettingsTheme.titleColor)
              Spacer(minLength: 0)
              Text(verbatim: Self.displayTimePhrase(entry.hours))
                .foregroundStyle(SettingsTheme.bodyColor)
                .monospacedDigit()
            }
            GeometryReader { geometry in
              Capsule()
                .fill(Color.white.opacity(0.08))
                .overlay(alignment: .leading) {
                  if leader > 0 {
                    Capsule()
                      .fill(
                        LinearGradient(
                          colors: [
                            PanelExposureScale.color(0.35), PanelExposureScale.color(0.9),
                          ],
                          startPoint: .leading, endPoint: .trailing))
                      .frame(width: geometry.size.width * entry.hours / leader)
                  }
                }
            }
            .frame(height: 4)
            .accessibilityHidden(true)
          }
        }
      }
    }
  }

  /// "none yet" rather than the shared default "0 hours": a leaderboard row for
  /// an app with no time is a row that should not have appeared, whereas a
  /// lifetime counter is a number that legitimately reads zero.
  private static func displayTimePhrase(_ hours: Double) -> String {
    PanelHealthCopy.hours(hours, zeroPhrase: "none yet")
  }
}
