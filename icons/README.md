# Candela app icon

## Contents
- `Candela.icns` — packaged icon, ready to drop into your Xcode target or app bundle
- `Candela.iconset/` — the ten PNGs macOS expects, correctly named
- `candela-full.svg` / `candela-medium.svg` / `candela-small.svg` — editable masters

## Size ladder
| Rendered size | Master | Content inset |
|---|---|---|
| 1024, 512, 256 | full | 80.5% |
| 128 | medium | 81.3% |
| 64 | medium | 87.5% |
| 32, 16 | small | none (full bleed) |

## Rebuilding
With the SVGs edited, regenerate on a Mac with:

    iconutil -c icns Candela.iconset

## Notes
The 16 and 32 px sizes are drawn full bleed rather than inset, so panel edges land
on whole pixels. Insetting them would put edges on half pixels and soften the icon
at the size it is seen most.

The masters are hand-tuned per tier, not one drawing scaled. Editing the full master
does not propagate to the others.
