#if DEBUG
  import SwiftUI

  /// Fixture data and navigation model for the settings visual mock: the whole
  /// settings surface re-imagined in the guided setup flow's dark cinematic
  /// style. Nothing here reads or writes real prefs; every control binds to
  /// local state so the mock is safe to click through on any machine.
  enum SettingsMockSection: String, CaseIterable, Identifiable {
    case general
    case menuBar
    case arrangement
    case oledCare
    case virtualDisplays
    case keyboard
    case updates
    case about

    var id: String { rawValue }

    var title: String {
      switch self {
      case .general: "General"
      case .menuBar: "Menu Bar"
      case .arrangement: "Arrangement"
      case .oledCare: "OLED Care"
      case .virtualDisplays: "Virtual Displays"
      case .keyboard: "Keyboard"
      case .updates: "Updates"
      case .about: "About"
      }
    }

    var symbol: String {
      switch self {
      case .general: "gearshape.fill"
      case .menuBar: "menubar.rectangle"
      case .arrangement: "rectangle.3.group"
      case .oledCare: "shield.lefthalf.filled"
      case .virtualDisplays: "rectangle.badge.plus"
      case .keyboard: "keyboard.fill"
      case .updates: "arrow.triangle.2.circlepath"
      case .about: "sparkles"
      }
    }

    /// Per-section stage lighting, the mock's version of the flow's per-act
    /// accents: cool utility hues for the mechanical panes, the care ember
    /// for OLED, violet for the synthetic displays.
    var accent: Color {
      switch self {
      case .general: Color(red: 0.29, green: 0.67, blue: 0.64)
      case .menuBar: Color(red: 0.30, green: 0.70, blue: 0.82)
      case .arrangement: Color(red: 0.46, green: 0.54, blue: 0.89)
      case .oledCare: Color(red: 0.91, green: 0.60, blue: 0.31)
      case .virtualDisplays: Color(red: 0.58, green: 0.43, blue: 0.89)
      case .keyboard: Color(red: 0.38, green: 0.54, blue: 0.89)
      case .updates: Color(red: 0.37, green: 0.76, blue: 0.50)
      case .about: Color(red: 0.63, green: 0.67, blue: 0.87)
      }
    }

    var secondary: Color {
      switch self {
      case .general: Color(red: 0.25, green: 0.51, blue: 0.81)
      case .menuBar: Color(red: 0.30, green: 0.41, blue: 0.84)
      case .arrangement: Color(red: 0.30, green: 0.33, blue: 0.80)
      case .oledCare: Color(red: 0.75, green: 0.35, blue: 0.52)
      case .virtualDisplays: Color(red: 0.30, green: 0.33, blue: 0.80)
      case .keyboard: Color(red: 0.45, green: 0.34, blue: 0.81)
      case .updates: Color(red: 0.22, green: 0.55, blue: 0.67)
      case .about: Color(red: 0.33, green: 0.38, blue: 0.74)
      }
    }
  }

  /// A sidebar destination: a section pane or one display's page.
  enum SettingsMockDestination: Hashable {
    case section(SettingsMockSection)
    case display(String)

    var accent: Color {
      switch self {
      case let .section(section): section.accent
      case let .display(id):
        SettingsMockFixtures.displays.first { $0.id == id }?.accent
          ?? SettingsMockSection.general.accent
      }
    }

    var secondary: Color {
      switch self {
      case let .section(section): section.secondary
      case .display: Color(red: 0.30, green: 0.41, blue: 0.84)
      }
    }
  }

  /// One display of the mock rig, enough shape for a hub page and the set
  /// pieces: mounted aspect for the glyph, current values for the controls.
  struct SettingsMockDisplay: Identifiable {
    let id: String
    let name: String
    /// Width over height as mounted (the rotated Dell is below 1).
    let aspect: Double
    let isBuiltIn: Bool
    let isOled: Bool
    let sizeLine: String
    let refreshLine: String
    let hasVolume: Bool
    /// A one-line hardware story for hero captions ("DDC over DisplayPort").
    let controlLine: String
    let accent: Color

    var brightness: Double
    var contrast: Double
    var volume: Double
  }

  enum SettingsMockFixtures {
    static let builtIn = SettingsMockDisplay(
      id: "builtIn", name: "Built-in Display", aspect: 1.55, isBuiltIn: true,
      isOled: false, sizeLine: "1512 x 982", refreshLine: "120 Hz ProMotion",
      hasVolume: false, controlLine: "Driven natively by macOS",
      accent: Color(red: 0.69, green: 0.76, blue: 0.90),
      brightness: 0.72, contrast: 0.5, volume: 0)

    static let dell = SettingsMockDisplay(
      id: "dell", name: "DELL U2725QE", aspect: 9.0 / 16.0, isBuiltIn: false,
      isOled: false, sizeLine: "2160 x 3840", refreshLine: "120 Hz",
      hasVolume: false, controlLine: "DDC over DisplayPort, rotated 270 degrees",
      accent: Color(red: 0.36, green: 0.57, blue: 0.90),
      brightness: 0.64, contrast: 0.75, volume: 0)

    static let mag = SettingsMockDisplay(
      id: "mag", name: "MAG 341C OLED", aspect: 21.5 / 9.0, isBuiltIn: false,
      isOled: true, sizeLine: "3440 x 1440", refreshLine: "175 Hz",
      hasVolume: true, controlLine: "DDC over DisplayPort",
      accent: Color(red: 0.91, green: 0.60, blue: 0.31),
      brightness: 0.81, contrast: 0.8, volume: 0.45)

    static let displays: [SettingsMockDisplay] = [builtIn, dell, mag]

    static func display(for id: String) -> SettingsMockDisplay {
      displays.first { $0.id == id } ?? builtIn
    }
  }
#endif
