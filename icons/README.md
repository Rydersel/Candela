# Candela app icon

Designer-delivered set (2026-08-06): a gold "C" monogram with a glowing tip
on a dark rounded square.

## Contents
- `Candela.icns` — packaged icon, ready to drop into your Xcode target or app bundle
- `Candela.iconset/` — the ten PNGs macOS expects, correctly named
- `candela-monogram.svg` — the editable master (1024×1024, full art including background)

## Rebuilding
The PNGs and `.icns` come from the designer; if the master changes, re-export
the ten sizes into `Candela.iconset/`, then on a Mac:

    iconutil -c icns Candela.iconset

Keep `Candela/Assets.xcassets/AppIcon.appiconset/` in sync — it holds the same
ten PNGs and is what the app actually compiles in
(`ASSETCATALOG_COMPILER_APPICON_NAME: AppIcon` in `project.yml`).
The site reuses the master at `site/src/assets/candela-icon.svg` (hero mark)
and `site/public/favicon.svg`.
