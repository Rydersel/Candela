import CandelaKit
import SwiftUI

/// The two cards that state in words what the exposure map only draws: the
/// hottest area's measured multiple, and the display time each app booked. They
/// carry findings rather than instruments, so they sit beside the dimming
/// settings they argue for; the Heat Map window keeps the instruments.
///
/// Copy rule (OC11): software has two levers against OLED wear, reduce luminance
/// and reduce time at luminance. Nothing here may translate a measurement into a
/// lifespan, a date, a percentage of damage avoided or a score. Relative
/// exposure is measured and therefore sayable; nothing else is.

/// The measured ratio of one area against the display's own average, and where
/// it is. Renders nothing unless there is a measured multiple to state: under
/// `minimumSamplesForAnalysis` readings there is nothing to be right about, and
/// an estimate may never wear this card's certainty.
struct PanelHottestAreaCard: View {
  let summary: PanelHealthSummary

  /// The phrase this card exists to show, or nil. One function for the gate and
  /// the body, so the card can never draw its frame around a missing number.
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
          // The one number this feature may state: a measured ratio of a panel
          // against itself. Not a lifespan, a date or a score, ever.
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

          // Past tense, deliberately: the snapshot behind this is up to a
          // minute old, so "right now" is a claim the data cannot support.
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

/// Display time per app, from window observation, with an explicit empty case:
/// the producer is wired separately from the view.
///
/// NOT labelled by `confidence`, which describes the luminance telemetry only.
/// These hours come from window observation, a separate pref that needs no
/// permission, so they are measured whether or not brightness is.
struct PanelDisplayTimeCard: View {
  let summary: PanelHealthSummary

  var body: some View {
    let owners = summary.topOwnersByHours
    VStack(alignment: .leading, spacing: 6) {
      SettingsCardSection(title: "Display time by app") {
        ownerRows(owners)
      }

      // Display-time, NOT how long the app was open: an app filling the display
      // books an hour per hour, one covering a quarter books fifteen minutes.
      // The caption states the weighting outright, because "open for 3 hours"
      // would be a claim this does not measure.
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
        // and an owner name is not guaranteed unique.
        // The bar is proportional to the LIST's own leader; an absolute scale
        // would need a total this list deliberately truncates.
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

  /// "none yet" rather than the shared default "0 hours": a row for an app with
  /// no time should not have appeared at all, unlike a lifetime counter, which
  /// legitimately reads zero.
  private static func displayTimePhrase(_ hours: Double) -> String {
    PanelHealthCopy.hours(hours, zeroPhrase: "none yet")
  }
}
