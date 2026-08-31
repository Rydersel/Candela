import CandelaKit
import SwiftUI

/// The settings SO15 grants a second sentence to, because each one names a
/// state a person may not be able to undo from inside the app.
///
/// Closed on purpose, so a new safety case cannot appear by someone writing a
/// longer caption at a call site. It takes a case here, and a decision about
/// what it says and where it is spoken.
enum SafetySentence {
  /// The brightness slider can reach 0% on a display dimming in software.
  case blankDisplay
  /// A display's Sound section, D29's mute strand. SO5 gives the unavailable
  /// state a sentence of its own rather than letting a recoverable state borrow
  /// this one.
  ///
  /// `dedicatedCommandInReach` asks `VolumeSliderPolicy.usesDedicatedMuteCommand`
  /// with the pref held on, so it answers the switch's promise rather than its
  /// current position. This sentence rides the control's LABEL, the channel a
  /// VoiceOver user cannot suppress, so an overclaim here is one the reader
  /// cannot get past.
  case hardwareMute(isAvailable: Bool, dedicatedCommandInReach: Bool)
  /// The Advanced page's hardware-control toggle. Takes the whole block rather
  /// than a bool so the row is a safety row unconditionally: a row that changed
  /// shape when HDR engaged would swap `_ConditionalContent` branches and
  /// rebuild the control underneath the person using it.
  case hdrBlock(DDCTrafficBlock?)

  /// Appended to the control's accessibility label. Nil means nothing to add
  /// in this state, never that the row stopped being a safety row.
  var spoken: String? {
    switch self {
    case .blankDisplay:
      "The slider can reach 0% on any display dimming in software, which blanks it completely. If keyboard control is also off, a blank display can be hard to undo."
    case let .hardwareMute(isAvailable, dedicatedCommandInReach):
      if !isAvailable {
        "Volume control is off for this display, so mute is unavailable."
      } else if dedicatedCommandInReach {
        // "All the way down" rather than "to zero": the degraded mute rides
        // the volume command's value path, so a floor set there sends the floor
        // and Invert sends the top of the range.
        "Off: muting turns the volume all the way down. On: sends the display's own mute command."
      } else {
        // Says what the SWITCH does; the level and the cause are the status
        // caption's. Scoped to the mute direction on purpose: an unmute still
        // sends the command's release on the pref alone, ungated by the verdict
        // (D29 rule 3), so a sentence about the command in general is false.
        "Off or On, a mute here goes to the volume command instead."
      }
    case let .hdrBlock(block):
      block == .macOSDrivesBrightness ? Self.trafficBlockExplanation(.macOSDrivesBrightness) : nil
    }
  }

  /// The same sentence shown under the control. Nil for the HDR block, which
  /// SO12 states once for the whole page at the foot of Control Method, so that
  /// case goes into the label and nowhere else.
  var visibleCaption: SettingsCaption? {
    switch self {
    case .blankDisplay, .hardwareMute: spoken.map { SettingsCaption(verbatim: $0) }
    case .hdrBlock: nil
    }
  }

  /// Why no DDC command is reaching this display. Here rather than on
  /// `AdvancedPage` because the HDR half is both spoken in a control label and
  /// shown as the page's caption, and two copies would drift.
  static func trafficBlockExplanation(_ block: DDCTrafficBlock) -> String {
    switch block {
    case .macOSDrivesBrightness:
      "This display is in HDR mode. macOS is setting its brightness directly, so the settings below have no effect until HDR turns off."
    case .hardwareControlOff:
      "Hardware (DDC) control is off for this display, so the settings below have no effect."
    }
  }
}

/// A control and the caption explaining it, as ONE row.
///
/// A caption standing as its own row reads as a separate setting and runs the
/// page to roughly twice the height it needs. One row is what binds the
/// explanation to the thing it explains.
///
/// The caption is published as the control's `accessibilityHint` from here
/// rather than per call site, so a new row cannot forget it. Both initialisers
/// go through the same seam.
struct SettingRow<Control: View>: View {
  @Environment(\.isEnabled) private var isEnabled

  private let caption: SettingsCaption?
  private let safety: SafetySentence?
  private let controlLabel: LocalizedStringKey?
  private let control: Control

  init(_ caption: LocalizedStringKey? = nil, @ViewBuilder control: () -> Control) {
    self.init(caption: caption.map { SettingsCaption($0) }, control: control)
  }

  init(caption: SettingsCaption?, @ViewBuilder control: () -> Control) {
    self.caption = caption
    self.safety = nil
    self.controlLabel = nil
    self.control = control()
  }

  /// A row whose consequence a person may not be able to undo from inside the
  /// app.
  ///
  /// The sentence goes into the control's LABEL, not its hint. Hints are the
  /// suppressible channel and are spoken last, so the sentences that exist to
  /// prevent an unrecoverable state would be the ones least likely to be heard.
  /// `SafetySentence` is its own type for that reason: the initialisers above
  /// take a `SettingsCaption` and cannot be handed one, so a safety sentence
  /// has no route into the hint.
  ///
  /// `label` is handed BACK to the control builder because SwiftUI has no
  /// append-to-a-label modifier and a control's own label is unreadable from
  /// here. One value used twice, so spoken and visible cannot drift.
  ///
  /// `caption` is the row's ordinary explanation and still becomes the hint.
  init(
    safety: SafetySentence,
    label: LocalizedStringKey,
    caption: SettingsCaption? = nil,
    @ViewBuilder control: (LocalizedStringKey) -> Control
  ) {
    self.caption = caption
    self.safety = safety
    self.controlLabel = label
    self.control = control(label)
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 3) {
      // The initialiser fixes which branch runs, so it cannot flip on screen.
      // An `if` on the caption would not be safe: an appearing or disappearing
      // caption swaps `_ConditionalContent` branches, rebuilding the control
      // and losing its focus and in-progress edits. A safety sentence going
      // empty changes the `Text`, not the branch.
      if let spokenLabel {
        hinted(control).accessibilityLabel(spokenLabel)
      } else {
        hinted(control)
      }
      rowCaption(safety?.visibleCaption)
      rowCaption(caption)
    }
    // Full card width, not the content's ideal width: a labeled control given
    // the whole row puts its label leading and its switch or pop-up trailing.
    .frame(maxWidth: .infinity, alignment: .leading)
    .padding(.vertical, SettingsTheme.rowVerticalPadding)
    .foregroundStyle(SettingsTheme.titleColor)
    // Supplied here, so a nested row component adds none of its own.
    .environment(\.settingsRowIsPadded, true)
  }

  /// A caption at row weight rather than its standalone weight, which on a
  /// card would compete with the control's label. Takes the `Text` rather than
  /// the view, because a caption styles itself and an outer font cannot
  /// override it.
  @ViewBuilder
  private func rowCaption(_ caption: SettingsCaption?) -> some View {
    if let caption {
      caption.text
        .font(.caption)
        .foregroundStyle(SettingsTheme.faintColor)
        .fixedSize(horizontal: false, vertical: true)
        .opacity(isEnabled ? 1 : SettingsTheme.disabledOpacity)
    }
  }

  /// Attached unconditionally, empty when there is no caption: the
  /// `isEnabled:` overload that would say this directly needs macOS 15.
  private func hinted(_ view: Control) -> some View {
    view.accessibilityHint(caption?.text ?? Text(verbatim: ""))
  }

  private var spokenLabel: Text? {
    guard let controlLabel else { return nil }
    guard let sentence = safety?.spoken else { return Text(controlLabel) }
    return Text(controlLabel) + Text(verbatim: ". \(sentence)")
  }
}

/// Secondary explanatory text under a control, the one caption idiom.
///
/// Two initialisers because a sentence with a display name or a count in it
/// cannot be a `LocalizedStringKey` literal. The alternative, callers
/// hand-rolling `Text` with the same three modifiers, is how styling drifts one
/// caption at a time.
struct SettingsCaption: View {
  /// The unstyled sentence, so `SettingRow` can republish it as a hint. `Text`
  /// and not `String`: a `LocalizedStringKey` cannot be read back as a string,
  /// and most callers hand one over.
  let text: Text

  @Environment(\.isEnabled) private var isEnabled

  init(_ text: LocalizedStringKey) {
    self.text = Text(text)
  }

  init(verbatim text: String) {
    self.text = Text(verbatim: text)
  }

  var body: some View {
    text
      .font(.callout)
      .foregroundStyle(SettingsTheme.bodyColor)
      .fixedSize(horizontal: false, vertical: true)
      // The theme paints an opaque colour, so nothing else dims this.
      .opacity(isEnabled ? 1 : SettingsTheme.disabledOpacity)
  }
}

extension View {
  /// Every settings section header is a VoiceOver heading.
  func settingsHeading() -> some View { accessibilityAddTraits(.isHeader) }
}

/// A row whose control is an ACTION rather than a setting: sentence leading,
/// buttons trailing.
///
/// `SettingRow` cannot draw this shape. It hands the control the card's full
/// width so the control places its own label, and a `Button` carries no such
/// label, so it collapses to its natural width and the rest of the card reads
/// as dead space.
///
/// The sentence is both the visible explanation and the actions'
/// `accessibilityHint`, same seam as `SettingRow`, so a new row cannot forget
/// it.
struct SettingsActionRow<Actions: View>: View {
  @Environment(\.isEnabled) private var isEnabled

  private let sentence: Text
  private let caption: SettingsCaption?
  private let dividerFollows: Bool
  private let actions: Actions

  init(
    _ sentence: LocalizedStringKey,
    caption: SettingsCaption? = nil,
    dividerFollows: Bool = false,
    @ViewBuilder actions: () -> Actions
  ) {
    self.sentence = Text(sentence)
    self.caption = caption
    self.dividerFollows = dividerFollows
    self.actions = actions()
  }

  /// For a sentence carrying a name, a date or a count, which cannot be a
  /// `LocalizedStringKey`.
  init(
    verbatim sentence: String,
    caption: SettingsCaption? = nil,
    dividerFollows: Bool = false,
    @ViewBuilder actions: () -> Actions
  ) {
    self.sentence = Text(verbatim: sentence)
    self.caption = caption
    self.dividerFollows = dividerFollows
    self.actions = actions()
  }

  var body: some View {
    HStack(alignment: .center, spacing: 12) {
      VStack(alignment: .leading, spacing: 3) {
        sentence
          .font(.callout)
          .foregroundStyle(SettingsTheme.bodyColor)
          .fixedSize(horizontal: false, vertical: true)
        if let caption {
          caption.text
            .font(.caption)
            .foregroundStyle(SettingsTheme.faintColor)
            .fixedSize(horizontal: false, vertical: true)
        }
      }
      .opacity(isEnabled ? 1 : SettingsTheme.disabledOpacity)
      Spacer(minLength: 12)
      actions
        .accessibilityHint(sentence)
    }
    .frame(maxWidth: .infinity)
    // No vertical padding of its own, unlike `SettingRow`: the trailing button
    // carries its own, and a row's worth on top stacked about twenty points of
    // air over a one-line sentence. A row a divider follows gets the card's
    // padding above and a bare hairline below, so it restates that value here.
    .padding(.bottom, dividerFollows ? SettingsTheme.cardVerticalPadding : 0)
    // A nested row component adds no padding of its own.
    .environment(\.settingsRowIsPadded, true)
  }
}
