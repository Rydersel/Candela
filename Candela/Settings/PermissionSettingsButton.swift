import CandelaKit
import SwiftUI

struct PermissionSettingsButton: View {
  var pane: PermissionPane = .screenRecording

  var body: some View {
    Button("Open System Settings…") {
      PermissionGuide.shared.show(pane)
    }
    .buttonStyle(SettingsSecondaryButtonStyle())
    .accessibilityLabel("Open System Settings…")
  }
}
