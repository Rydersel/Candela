# Third-party licenses

Candela is MIT licensed (see `LICENSE`). It also contains code from, and links
against, the projects below. The MIT license requires that its copyright notice
and permission notice travel with the code, so the full text of each is
reproduced here rather than linked: a reference to a license is not a copy of
one.

Individual source files carry their own attribution header naming what they were
transplanted from. This file is the licence text those headers point at.

---

## MonitorControl

<https://github.com/MonitorControl/MonitorControl>

The project Candela is descended from. Its DDC/CI transport for both Apple
Silicon and Intel, its media-key handling, its software-dimming approach and its
HDR toggle were transplanted or adapted here, and its behaviour is the baseline
this app is measured against.

Source files carrying MonitorControl's copyright header, because they contain
its code:

| File | What came from upstream |
|---|---|
| `CandelaKit/Sources/CandelaKit/DDC/Arm64DDC.swift` | the Apple Silicon DDC/CI transport |
| `CandelaKit/Sources/CandelaKit/DDC/IntelDDC.swift` | the Intel DDC/CI transport (see the note below) |
| `CandelaKit/Sources/CandelaKit/HDR/MonitorPanelService.swift` | the MonitorPanel HDR toggle (`HDRControl`) |
| `CandelaKit/Sources/CandelaKit/Brightness/BrightnessController.swift` | the combined-dimming split (attributed inline, at the function) |
| `CandelaKit/Sources/CandelaKit/Brightness/DimmingMath.swift` | the dimming curve |
| `CandelaKit/Sources/CandelaKit/Input/KeyRouter.swift` | the modifier semantics of `MediaKeyTapManager.handle` |
| `Candela/AppKitIslands/GammaController.swift` | the gamma activity enforcer and per-channel scaling |
| `Candela/AppKitIslands/ShadeOverlay.swift` | the per-display shade lifecycle (`getShade`, `createShadeOnDisplay`, `updateShade`, `destroyShade`) |
| `Candela/AppKitIslands/OverlayWindow.swift` | the overlay window recipe, moved out of `ShadeOverlay` (`createShadeOnDisplay`) |
| `Candela/AppKitIslands/VolumeFeedbackSound.swift` | the feedback sound and the global-prefs read (`playVolumeChangedSound`, `getSystemSettings`) |
| `Candela/AppKitIslands/BrightnessHUD.swift` | the custom HUD |
| `Candela/AppKitIslands/MediaKeyEventTap.swift` | the event tap (and MediaKeyTap below) |

```
MIT License

Copyright © 2017

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
```

The upstream `License.txt` carries no names on its copyright line. The
individual file headers do, and Candela's transplanted files reproduce that
header verbatim as upstream writes it:

```
//  Copyright © MonitorControl. @JoniVR, @theOneyouseek, @waydabber and others
```

---

## MediaKeyTap

<https://github.com/nhurden/MediaKeyTap>

Reached Candela through MonitorControl, which adapted it; `MediaKeyEventTap.swift`
credits both.

```
MIT License

Copyright (c) 2016 Nicholas Hurden

Permission is hereby granted, free of charge, to any person obtaining a copy of
this software and associated documentation files (the "Software"), to deal in
the Software without restriction, including without limitation the rights to
use, copy, modify, merge, publish, distribute, sublicense, and/or sell copies
of the Software, and to permit persons to whom the Software is furnished to do
so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
```

---

## KeyboardShortcuts

<https://github.com/sindresorhus/KeyboardShortcuts>

Candela's only third-party dependency, linked as a Swift package. It provides
the user-recordable global shortcuts in Settings, Keyboard.

```
MIT License

Copyright (c) Sindre Sorhus <sindresorhus@gmail.com> (https://sindresorhus.com)

Permission is hereby granted, free of charge, to any person obtaining a copy of
this software and associated documentation files (the "Software"), to deal in
the Software without restriction, including without limitation the rights to
use, copy, modify, merge, publish, distribute, sublicense, and/or sell copies
of the Software, and to permit persons to whom the Software is furnished to do
so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
```

---

## DDC.swift, and one unresolved link in the chain

<https://github.com/reitermarkus/DDC.swift>

`IntelDDC.swift` carries MonitorControl's own second attribution line,
`Adapted from IntelDDC.swift, @reitermarkus`, and Candela preserves it.

Recorded plainly because an audit that quietly rounded it off would be worth
less than no audit: **that repository publishes no license file**, so there is
no notice to reproduce here. What Candela relies on is MonitorControl's
position, which has been to ship this code under its own MIT since 2017 with the
attribution intact. Candela inherits that position and changes nothing about it.

The exposure is small and worth stating precisely. `IntelDDC` is the Intel
DDC/CI path; it compiles, but nothing constructs it (`DisplayDiscovery` returns
no Intel services, and the Intel adapter is a later milestone), so it ships as
unreachable code. If that stops being true, or if a clean provenance is wanted
sooner, the fix is to ask the author to add a license rather than to delete the
attribution line.
