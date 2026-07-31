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
  /// checker: `isGranted` is observable and Task 9 monitors it for the app's
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
    VStack(alignment: .leading, spacing: 22) {
      hero
      Divider()
      openAtLogin
      Divider()
      keyboard
      Divider()
      accessibility
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

  private var hero: some View {
    VStack(spacing: 10) {
      Image(nsImage: NSImage(named: NSImage.applicationIconName) ?? NSImage())
        .resizable()
        .frame(width: 96, height: 96)
        .accessibilityHidden(true)
      Text("Welcome to \(AppInfo.productName)")
        .font(.largeTitle.weight(.semibold))
      Text("Control the brightness, volume and contrast of your external displays from the menu bar — or straight from the keys you already use.")
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
      Text("Always there when you need it")
        .font(.title3.weight(.semibold))
      // BYTE-IDENTICAL to the General pane's toggle (Task 10). Same setting,
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
      SettingsCaption("Off unless you turn it on. \(AppInfo.productName) has no Dock icon — it lives in the menu bar.")
    }
  }

  private var keyboard: some View {
    VStack(alignment: .leading, spacing: 8) {
      Text("Your keyboard already works")
        .font(.title3.weight(.semibold))
      keyRow(symbol: "sun.max", label: "Brightness up and down")
      keyRow(symbol: "speaker.wave.2", label: "Volume up and down")
      keyRow(symbol: "speaker.slash", label: "Mute")
      SettingsCaption("These keys act on whichever display your pointer is on. Hold Shift and Option together for fine steps. You can change all of this later in Settings → Keyboard.")
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
      Text("One permission to ask for")
        .font(.title3.weight(.semibold))
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
