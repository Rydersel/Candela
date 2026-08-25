import CandelaKit
import SwiftUI

/// The three settings SO15 allows two sentences, because each of them names a
/// state a person may not be able to undo from inside the app: a blank display,
/// a display muted over its own mute command, and a DDC control the monitor has
/// locked under HDR.
///
/// Closed on purpose. The spec names exactly three, so the compiler carries the
/// count: a fourth safety case cannot appear by someone writing a longer caption
/// at a call site, only by adding a case here and deciding what it says and
/// where it is spoken.
enum SafetySentence {
  /// General: the brightness slider can reach 0% on a display dimming in
  /// software.
  case blankDisplay
  /// A display's Sound section, D29's mute strand. `isAvailable` is the
  /// display's volume availability: SO5 gives the unavailable state a sentence
  /// of its own rather than letting a recoverable state borrow this one.
  ///
  /// `dedicatedCommandInReach` is whether switching this ON would actually send
  /// the display's own mute command: `VolumeSliderPolicy.usesDedicatedMuteCommand`
  /// asked with the pref held on, so it answers the switch's promise rather than
  /// its current position. A clean denial of that register, or the "always off"
  /// volume-slider override, makes the promise false, and this sentence is the
  /// UNSUPPRESSIBLE channel: it goes into the control's label, where a VoiceOver
  /// user who has turned hints off hears it and nothing else. Stating the
  /// dedicated command there while the engine writes the volume register put the
  /// overclaim in the one place the reader cannot get past.
  case hardwareMute(isAvailable: Bool, dedicatedCommandInReach: Bool)
  /// The Advanced page's hardware-control toggle. Takes the whole block rather
  /// than a bool so the row can be a safety row unconditionally: only live HDR
  /// is the safety case, and a row that changed shape when HDR engaged would
  /// swap `_ConditionalContent` branches and rebuild the control underneath the
  /// person using it.
  case hdrBlock(DDCTrafficBlock?)

  /// Appended to the control's accessibility label. Nil means there is nothing
  /// to add in the current state, never that the row has stopped being a safety
  /// row.
  var spoken: String? {
    switch self {
    case .blankDisplay:
      "The slider can reach 0% on any display dimming in software, which blanks it completely. If keyboard control is also off, a blank display can be hard to undo."
    case let .hardwareMute(isAvailable, dedicatedCommandInReach):
      if !isAvailable {
        "Volume control is off for this display, so mute is unavailable."
      } else if dedicatedCommandInReach {
        // "All the way down" rather than "to zero": the degraded mute goes out
        // through the volume command's own value path, so a floor set on that
        // command sends the floor and Invert sends the top of the range.
        "Off: muting turns the volume all the way down. On: sends the display's own mute command."
      } else {
        // Says what the SWITCH does, and leaves the level and the cause to the
        // row's status caption rather than saying either twice. Scoped to the
        // mute direction on purpose: an unmute still sends the mute command's
        // release on the pref alone, ungated by the verdict (D29 rule 3), so a
        // sentence about the command in general would be false.
        "Off or On, a mute here goes to the volume command instead."
      }
    case let .hdrBlock(block):
      block == .macOSDrivesBrightness ? Self.trafficBlockExplanation(.macOSDrivesBrightness) : nil
    }
  }

  /// The same sentence shown under the control. Nil for the HDR block, which
  /// SO12 states ONCE for the whole page at the foot of Control Method;
  /// repeating it under the toggle is the duplication SO12 exists to remove, so
  /// that case is promoted into the label and nowhere else.
  var visibleCaption: SettingsCaption? {
    switch self {
    case .blankDisplay, .hardwareMute: spoken.map { SettingsCaption(verbatim: $0) }
    case .hdrBlock: nil
    }
  }

  /// Why no DDC command is reaching this display, if none is. Lives here rather
  /// than on `AdvancedPage` because the HDR half is spoken as part of a control
  /// label as well as shown as the page's one caption, and two copies of the
  /// sentence would drift.
  static func trafficBlockExplanation(_ block: DDCTrafficBlock) -> String {
    switch block {
    case .macOSDrivesBrightness:
      "This display is in HDR mode. macOS is setting its brightness directly, so the settings below have no effect until HDR turns off."
    case .hardwareControlOff:
      "Hardware (DDC) control is off for this display, so the settings below have no effect."
    }
  }
}

/// A control and the caption explaining it, as ONE `Form` row.
///
/// A caption placed as its own row gets a divider above it and full row
/// padding, so every piece of help text reads as a separate setting and the
/// page grows to roughly twice the height it needs. `listRowSeparator` and
/// `listRowInsets` do not fix that — neither applies inside a grouped `Form`
/// on macOS (measured: no visible change). Putting both in one row is what
/// actually binds the explanation to the thing it explains, which is how
/// System Settings tucks its secondary text under a control.
///
/// The caption is also published as the control's `accessibilityHint`
/// (accessibility contract 3) from here rather than per call site, so it cannot
/// be forgotten on a new row. Both initialisers go through the same seam.
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
  /// app (accessibility contract 3).
  ///
  /// The sentence goes into the control's LABEL, not its hint. A hint is the
  /// suppressible channel: VoiceOver users routinely turn hints off, and a hint
  /// is spoken last, after the label and the value, so the three sentences that
  /// exist to prevent an unrecoverable state are exactly the three a VoiceOver
  /// user is least likely to hear. `SafetySentence` is a type of its own for the
  /// same reason: the two initialisers above take a `SettingsCaption` and cannot
  /// be handed one, so a safety sentence has no route into the hint.
  ///
  /// `label` is handed BACK to the control builder rather than read off the
  /// finished control, because SwiftUI has no append-to-a-label modifier and a
  /// control's own label is not readable from here. One value used twice, so the
  /// spoken and the visible label cannot drift.
  ///
  /// `caption` is the row's ordinary explanation, which still becomes the hint.
  /// The blank-display case IS its caption and passes none; the HDR block and
  /// the mute row both pass one, the mute row's being the status that names WHY
  /// the strategy in force is not the one the switch asks for.
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
      // Which branch runs is fixed by the initialiser the call site chose and
      // cannot flip while the row is on screen, so this `if` is safe where one
      // on the caption would not be: that would swap `_ConditionalContent`
      // branches whenever a caption appeared or disappeared
      // (`MirroringSection`'s cannot-start reason does), rebuilding the control
      // and losing its focus and in-progress edits. A safety sentence going
      // empty, which the HDR block does when HDR turns off, changes the `Text`
      // and not the branch.
      if let spokenLabel {
        hinted(control).accessibilityLabel(spokenLabel)
      } else {
        hinted(control)
      }
      rowCaption(safety?.visibleCaption)
      rowCaption(caption)
    }
    // The row's content takes the card's full width, not just its own ideal
    // one: the dominant shape here is a labeled control, and a control given
    // the whole row is what puts its label at the leading edge and its switch
    // or pop-up at the trailing one.
    .frame(maxWidth: .infinity, alignment: .leading)
    .padding(.vertical, SettingsTheme.rowVerticalPadding)
    .foregroundStyle(SettingsTheme.titleColor)
    // This row's rhythm is supplied here, so a row component nested inside it
    // adds none of its own and the card keeps one rhythm.
    .environment(\.settingsRowIsPadded, true)
  }

  /// The row's own denser rendering of a caption: `SettingsCaption`'s sentence
  /// at row weight rather than its standalone weight, which on a card would
  /// compete with the control's label. The `Text` is taken rather than the
  /// view, because a caption styles itself and an outer font cannot override
  /// it.
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
  /// `isEnabled:` overload that would say this directly is macOS 15+.
  private func hinted(_ view: Control) -> some View {
    view.accessibilityHint(caption?.text ?? Text(verbatim: ""))
  }

  private var spokenLabel: Text? {
    guard let controlLabel else { return nil }
    guard let sentence = safety?.spoken else { return Text(controlLabel) }
    return Text(controlLabel) + Text(verbatim: ". \(sentence)")
  }
}

/// Secondary explanatory text under a control — the pane-wide caption idiom
/// (replaces the fork's three divergent sectionBox helpers with one component).
///
/// Two initialisers because a sentence with a display name or a count in it
/// cannot be a `LocalizedStringKey` literal, and the alternative — the caller
/// hand-rolling `Text` with the same three modifiers — is how the styling drifts
/// one caption at a time.
struct SettingsCaption: View {
  /// The unstyled sentence, so `SettingRow` can republish it as a hint.
  /// Deliberately `Text` and not `String`: a `LocalizedStringKey` cannot be read
  /// back as a string, and most callers hand one over — several through
  /// `MirroringCopy`/`RotationCopy`/`DisplayModeCopy`, which are shared with the
  /// confirmation panels and cannot become `String` for this alone.
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
      // A caption explaining a disabled section is not the brightest thing on
      // it: the theme paints an opaque color, so nothing else dims this.
      .opacity(isEnabled ? 1 : SettingsTheme.disabledOpacity)
  }
}

extension View {
  /// Every settings section header is a VoiceOver heading (accessibility
  /// contract 4).
  func settingsHeading() -> some View { accessibilityAddTraits(.isHeader) }
}

/// A row whose control is an ACTION rather than a setting: the sentence at the
/// leading edge, the button (or buttons) at the trailing one.
///
/// `SettingRow` cannot draw this shape, and the reason is in its own comment: it
/// hands the control the card's full width so the control can place its own
/// label, which is what puts a `Toggle`'s switch at the trailing edge. A
/// `Button` carries no such label, so it collapses to its natural width at the
/// leading edge and the rest of the card reads as dead space. One of those is
/// unremarkable; the About page had three stacked, which is what made it look
/// like the content had slid off the right of the card.
///
/// The sentence is the row's visible explanation AND the actions'
/// `accessibilityHint`, the same seam and the same reason as `SettingRow`: a new
/// row cannot forget it.
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
  /// `LocalizedStringKey` literal.
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
      // The sentence keeps its ideal width and this takes the rest, so the
      // actions sit on the trailing edge whatever the sentence is.
      Spacer(minLength: 12)
      actions
        .accessibilityHint(sentence)
    }
    .frame(maxWidth: .infinity)
    // No vertical padding of its own, unlike `SettingRow`: the trailing button
    // carries its own, and adding a row's worth on top of that stacked about
    // twenty points of air over a one-line sentence at the head of a card.
    //
    // What is left is the card's own padding, which centres a row that is the
    // card's only one. A row a divider follows is not centred by it: that row
    // takes the card's padding above and a bare hairline below, which reads as
    // a button shoved against the line under a card's worth of air. So it
    // stands the missing padding in itself, by name so the two cannot drift.
    .padding(.bottom, dividerFollows ? SettingsTheme.cardVerticalPadding : 0)
    // This row's rhythm is supplied here, so a row component nested inside it
    // adds none of its own and the card keeps one rhythm.
    .environment(\.settingsRowIsPadded, true)
  }
}
