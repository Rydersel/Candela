import AppKit
import CandelaKit
import SwiftUI

/// One screen, four blocks, no wizard (D14). Deliberately asset-free: Candela
/// has no `Assets.xcassets`, and the fork's `onboarding_keyboard` /
/// `onboarding_icon_*` imagesets were not transplanted — SF Symbols and the
/// bundle's own application icon carry the same information with no art to
/// commission or ship.
///
/// The view owns NO persistence. `onFinish` closes the window and the window
/// controller records completion, so "clicked the button" and "closed the
/// window" are the same event — which is exactly what makes skipping safe.
///
/// `@MainActor` on the struct, not just on `body`: `LoginItem` and
/// `AccessibilityPermission` are main-actor-isolated types, and a `View`'s
/// memberwise init and stored properties are otherwise nonisolated — which is
/// a hard error under this target's `SWIFT_STRICT_CONCURRENCY: complete`.
@MainActor
struct OnboardingView: View {
  let loginItem: LoginItem
  /// The app's ONE permission object (`AppModel.accessibility`), not a second
  /// checker: `isGranted` is observable and monitored for the app's
  /// lifetime, so this screen updates live when the grant lands while it is
  /// open. The fork computed its checkmark once in `viewDidLoad` and never
  /// refreshed it.
  let permission: AccessibilityPermission
  let onFinish: () -> Void

  /// The system Accessibility prompt appears at most once per process. After
  /// the first ask the only way forward is System Settings, so the button
  /// swaps rather than silently doing nothing a second time.
  @State private var didRequestAccessibility = false

  var body: some View {
    VStack(alignment: .leading, spacing: 18) {
      hero
      VStack(alignment: .leading, spacing: 14) {
        card { openAtLogin }
        card { keyboard }
        card { displayControl }
        card { accessibility }
      }
      footer
    }
    .padding(.horizontal, 32)
    // `.fullSizeContentView` puts the content under a transparent titlebar;
    // 28 pt keeps the hero clear of the close button.
    .padding(.top, 28)
    // layout.md: no critical control flush against the bottom edge.
    .padding(.bottom, 24)
    .frame(width: 520)
  }

  /// The same rounded, elevated surface a `Form(.grouped)` section draws in the
  /// settings window, so Setup and Settings read as one app rather than two.
  ///
  /// Built by hand rather than with a real `Form`: this screen is a single
  /// column with a hero and a default button, not a settings list, and a
  /// grouped `Form` would impose its own row metrics and inset headers on
  /// content that is prose and buttons.
  @ViewBuilder
  private func card(@ViewBuilder _ content: () -> some View) -> some View {
    VStack(alignment: .leading, spacing: 8) { content() }
      .frame(maxWidth: .infinity, alignment: .leading)
      .padding(14)
      .background(
        RoundedRectangle(cornerRadius: 10, style: .continuous)
          .fill(Color(nsColor: .controlBackgroundColor))
      )
  }

  /// Heading with the settings sidebar's tile, so the two windows share one
  /// visual vocabulary. The tile is decoration — the words carry the meaning.
  private func heading(_ text: LocalizedStringKey, symbol: String, tint: Color) -> some View {
    HStack(spacing: 8) {
      SettingsSymbolTile(symbol: symbol, tint: tint)
      Text(text)
        .font(.title3.weight(.semibold))
    }
  }

  private var hero: some View {
    VStack(spacing: 10) {
      Image(nsImage: NSImage(named: NSImage.applicationIconName) ?? NSImage())
        .resizable()
        .frame(width: 96, height: 96)
        .accessibilityHidden(true)
      Text("Welcome to \(AppInfo.productName)")
        .font(.largeTitle.weight(.semibold))
      Text("Control the brightness, volume and contrast of your external displays from the menu bar, or straight from the keys you already use.")
        .font(.callout)
        .foregroundStyle(.secondary)
        .multilineTextAlignment(.center)
        .fixedSize(horizontal: false, vertical: true)
    }
    .frame(maxWidth: .infinity)
  }

  private var openAtLogin: some View {
    VStack(alignment: .leading, spacing: 6) {
      // Benefit heading, not a restatement: the toggle's own label is the
      // General pane's exact string and must not be duplicated above it.
      heading("Always there when you need it", symbol: "power", tint: .gray)
      // BYTE-IDENTICAL to the General pane's toggle. Same setting,
      // same words, and macOS's own Login Items wording.
      Toggle("Open at Login", isOn: Binding(
        // D10: a LIVE read of `SMAppService.mainApp.status` — not a bool this
        // object is holding. The fork hardcoded `state="on"` in its storyboard
        // and only registered on *toggle*, so most users left onboarding
        // thinking it was enabled when nothing had been registered.
        get: { loginItem.isEnabled },
        set: { loginItem.setEnabled($0) }
      ))
      if let error = loginItem.lastError {
        // color.md: never communicate essential state by color alone — the
        // symbol carries it too. Same shape as the General pane's error row.
        HStack(alignment: .firstTextBaseline, spacing: 4) {
          Image(systemName: "exclamationmark.triangle.fill")
          Text(verbatim: error) // system error text — render it verbatim
        }
        .font(.callout)
        .foregroundStyle(.red)
        .fixedSize(horizontal: false, vertical: true)
      }
      SettingsCaption("Off unless you turn it on. \(AppInfo.productName) has no Dock icon; it lives in the menu bar.")
    }
  }

  private var keyboard: some View {
    VStack(alignment: .leading, spacing: 8) {
      heading("Your keyboard already works", symbol: "keyboard", tint: .indigo)
      keyRow(symbol: "sun.max", label: "Brightness up and down")
      keyRow(symbol: "speaker.wave.2", label: "Volume up and down")
      keyRow(symbol: "speaker.slash", label: "Mute")
      SettingsCaption("These keys act on whichever display your pointer is on. Hold Shift and Option together for fine steps. You can change all of this later in Settings → Keyboard.")
    }
  }

  /// The display-configuration pitch, under two copy constraints that pull the
  /// same way.
  ///
  /// RM11: never imply true native HiDPI — every revealed mode except one
  /// renders oversized and downsamples, so the app must not claim otherwise
  /// here and then be honest in the mode picker.
  ///
  /// And the measured rule that no API reports what Displays settings shows:
  /// "sizes macOS hides" was a claim about macOS we cannot check. State what
  /// our own list does instead. SO14 also retires "panel" from visible copy,
  /// which is why this says display throughout.
  private var displayControl: some View {
    VStack(alignment: .leading, spacing: 8) {
      heading("Your displays, on your terms", symbol: "display", tint: .teal)
      keyRow(symbol: "squares.leading.rectangle", label: "The full list of sizes and scaled options your display reports, not the short list you are usually offered")
      keyRow(symbol: "arrow.triangle.2.circlepath", label: "Refresh rate, rotation and mirroring")
      keyRow(symbol: "rectangle.3.group", label: "Arrange displays and save the layout for later")
      SettingsCaption("All of it lives in Settings, per display. A resolution change always previews first and reverts itself if you don't confirm.")
    }
  }

  private func keyRow(symbol: String, label: LocalizedStringKey) -> some View {
    HStack(spacing: 10) {
      Image(systemName: symbol)
        .frame(width: 20)
        .foregroundStyle(.secondary)
        .accessibilityHidden(true)
      Text(label)
    }
  }

  private var accessibility: some View {
    VStack(alignment: .leading, spacing: 10) {
      heading("One permission to ask for", symbol: "lock.shield", tint: .blue)
      // HIG: explain the benefit BEFORE the system dialog appears. Naming the
      // limit ("and nothing else") and the fallback ("the menu bar still
      // works") is the part that makes this an explanation rather than a
      // demand.
      Text("macOS delivers the brightness, volume and mute keys through Accessibility. \(AppInfo.productName) needs that access to see those key presses, and it reads nothing else. Without it the menu-bar sliders still work.")
        .font(.callout)
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
      if permission.isGranted {
        Label("Accessibility access granted", systemImage: "checkmark.circle.fill")
          .font(.callout)
          .foregroundStyle(.green)
      } else if didRequestAccessibility {
        VStack(alignment: .leading, spacing: 6) {
          Button("Open System Settings…") {
            AccessibilityPermission.openSystemSettings()
          }
          // Ventura+ pane name. The fork's copy still said "Security and
          // Privacy" (macOS 12).
          SettingsCaption("Turn \(AppInfo.productName) on under Privacy & Security → Accessibility. This screen updates on its own once you do.")
        }
      } else {
        // Plain bordered on purpose: the footer's default button is the only
        // emphasized control in the window (buttons.md).
        Button("Allow Accessibility Access") {
          didRequestAccessibility = true
          permission.promptIfNeeded()
        }
      }
    }
  }

  private var footer: some View {
    VStack(alignment: .leading, spacing: 8) {
      // Names the flow "Setup" — the same word Settings → General's reset
      // alert and Settings → About use. "Onboarding" never reaches the UI.
      SettingsCaption("You can run Setup again from Settings → About at any time.")
      HStack {
        Spacer()
        Button("Start Using \(AppInfo.productName)") { onFinish() }
          .keyboardShortcut(.defaultAction)
      }
    }
  }
}
