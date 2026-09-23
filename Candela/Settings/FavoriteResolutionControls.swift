import CandelaKit
import CoreGraphics
import SwiftUI

/// Copy also works when the saved mode is temporarily absent from the catalog.
@MainActor
struct FavoriteResolutionLabel {
  let title: String
  let detail: String
  let spoken: String

  init(_ favorite: FavoriteResolution, mode: DisplayMode?, catalog: DisplayModeCoordinator.Catalog) {
    let descriptor = mode?.descriptor ?? favorite.descriptor
    title = DisplayModeCopy.size(descriptor)
    let rate = favorite.isSynthesized ? "Keeps refresh rate" : DisplayModeCopy.refresh(descriptor.refreshHz)
    let tags: String
    if favorite.isSynthesized {
      tags = SynthesisCopy.badge
    } else if let mode {
      tags = catalog.tags(for: mode,
        isLowResolutionDuplicate: DisplayModeCatalog.lowResolutionDuplicates(catalog.all).contains(mode.ioModeID))
        .joined(separator: ", ")
    } else {
      tags = "Rendered at \(descriptor.pixelWidth) × \(descriptor.pixelHeight)"
    }
    detail = [rate, tags, mode == nil ? "Unavailable" : ""].filter { !$0.isEmpty }.joined(separator: " · ")
    spoken = [ModeSpeech.spoken(logicalWidth: descriptor.logicalWidth, logicalHeight: descriptor.logicalHeight,
                                refreshHz: favorite.isSynthesized ? nil : descriptor.refreshHz),
              favorite.isSynthesized ? rate : "", tags, mode == nil ? "Unavailable" : ""]
      .filter { !$0.isEmpty }.joined(separator: ", ")
  }
}

/// A separate button, so starring never activates the adjacent mode choice.
struct ResolutionFavoriteButton: View {
  let isFavorite: Bool
  let label: String
  let persistenceKey: String
  let action: () -> Void
  @State private var isHovering = false

  var body: some View {
    Button(action: action) {
      Image(systemName: isFavorite ? "star.fill" : "star")
        .font(.system(size: 11))
        .foregroundStyle(isFavorite || isHovering ? SettingsTheme.bodyColor : SettingsTheme.faintColor)
        .frame(width: 24, height: 24)
        .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .onHover { isHovering = $0 }
    .onDisappear { isHovering = false }
    .animation(SettingsTheme.hoverMotion, value: isHovering)
    .accessibilityLabel(Text(verbatim: "\(isFavorite ? "Remove" : "Add") \(label) \(isFavorite ? "from" : "to") favorites"))
    .accessibilityValue(isFavorite ? "Favorite" : "Not favorite")
    .help(isFavorite ? "Remove from Favorites" : "Add to Favorites")
    .prefIdentifier(.favoriteDisplayModes, persistenceKey: persistenceKey)
  }
}

@MainActor
struct ModeFavoriteButton: View {
  let mode: DisplayMode
  let catalog: DisplayModeCoordinator.Catalog
  let coordinator: DisplayModeCoordinator

  var body: some View {
    ResolutionFavoriteButton(
      isFavorite: coordinator.isFavorite(mode, on: catalog.display.id),
      label: "\(catalog.display.name), \(FavoriteResolutionLabel(FavoriteResolution(mode: mode), mode: mode, catalog: catalog).spoken)",
      persistenceKey: catalog.display.identity.key
    ) {
      coordinator.toggleFavorite(mode, on: catalog.display.id)
    }
  }
}

@MainActor
struct FavoriteResolutionRows: View {
  let catalog: DisplayModeCoordinator.Catalog
  let coordinator: DisplayModeCoordinator
  @Environment(\.controlActiveState) private var controlActiveState
  @Environment(\.settingsAccent) private var lighting
  @State private var hoveredFavorite: FavoriteResolution?

  var body: some View {
    let displayID = catalog.display.id
    let favorites = coordinator.favorites(for: displayID)
    if !favorites.isEmpty {
      VStack(alignment: .leading, spacing: 4) {
        Text("Favorites")
          .font(.system(size: 11, weight: .semibold))
          .foregroundStyle(SettingsTheme.faintColor)
        ForEach(favorites, id: \.self) { favorite in
          let mode = coordinator.resolvedFavorite(favorite, on: displayID)
          let label = FavoriteResolutionLabel(favorite, mode: mode, catalog: catalog)
          HStack(spacing: 6) {
            Button {
              coordinator.selectFavorite(favorite, on: displayID, from: .settings,
                surface: controlActiveState == .key ? .settingsBanner : .floatingPanel)
            } label: {
              HStack(spacing: 8) {
                Image(systemName: "checkmark")
                  .foregroundStyle(lighting.accent)
                  .opacity(coordinator.isCurrentFavorite(favorite, on: displayID) ? 1 : 0)
                  .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                  Text(verbatim: label.title).foregroundStyle(SettingsTheme.titleColor)
                  Text(verbatim: label.detail).font(.system(size: 11)).foregroundStyle(SettingsTheme.faintColor)
                }
                Spacer(minLength: 0)
              }
              .padding(.vertical, 4)
              .padding(.horizontal, 6)
              .contentShape(Rectangle())
            }
            .buttonStyle(ModeChoiceButtonStyle(isHovering: hoveredFavorite == favorite,
              isCurrent: coordinator.isCurrentFavorite(favorite, on: displayID), accent: lighting.accent))
            .onHover { hovering in
              if hovering { hoveredFavorite = favorite }
              else if hoveredFavorite == favorite { hoveredFavorite = nil }
            }
            .animation(SettingsTheme.hoverMotion, value: hoveredFavorite)
            .accessibilityLabel(Text(verbatim: label.spoken))
            .accessibilityAddTraits(coordinator.isCurrentFavorite(favorite, on: displayID) ? [.isSelected] : [])
            .disabled(mode == nil || coordinator.isApplying || coordinator.preview?.displayID == displayID)
            ResolutionFavoriteButton(isFavorite: true, label: "\(catalog.display.name), \(label.spoken)",
                                     persistenceKey: catalog.display.identity.key) {
              coordinator.removeFavorite(favorite, on: displayID)
            }
          }
        }
      }
    }
  }
}
