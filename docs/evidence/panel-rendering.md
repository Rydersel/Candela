# Panel image rendering investigation

Related issue: [#94](https://github.com/Rydersel/Candela/issues/94).

## Findings

On macOS 26.7, full app-suite runs reproduced a one-pixel vertical movement of
the footer's gear and power SF Symbols between captures through SwiftUI's
`ImageRenderer`. The maximum channel difference was 127. The glyph shapes and
alpha totals were unchanged; translating the first glyph crop down one pixel
made it identical to the later crop. A large channel difference did not indicate
a color change.

Cold isolated runs could produce identical captures. Disabling animations and
fixing the icon height did not eliminate the full-suite difference. The
framework trigger and any corresponding visible change in the running menu
remain unknown.

## A discarded capture is not a stability guarantee

On September 23, 2026, a fresh full app-suite run failed the assertion that the
second and third captures differ by at most four channel units, despite an
explicit discarded first capture. A later full-suite run passed unchanged.

A diagnostic that immediately copied each image into owned sRGB RGBA bytes while
retaining its renderer also passed. The restored original code then passed as
well. These results do not establish that immediate copying fixes the issue or
that retaining a CGImage after its renderer is unsafe.

The new determinism assertion was removed because its fixed warm-up premise is
not supported. Its movement-control test only exercised the comparison helper
and was removed with it. The existing render smoke tests, product-specific
appearance comparisons, and native panel sizing/scrolling tests remain.

## Reproducing the diagnostic

The original probe is preserved in commit
`7407b9fbc8c873b21eb9c3e950d52f4830cb6365` at
`CandelaAppTests/PanelRenderDeterminismTests.swift`. In a disposable checkout:

```sh
git show 7407b9fbc8c873b21eb9c3e950d52f4830cb6365:CandelaAppTests/PanelRenderDeterminismTests.swift > CandelaAppTests/PanelRenderDeterminismTests.swift
make test-app
```

Run the complete app suite: a cold isolated test has not reliably reproduced the
movement. Record whether it reproduces, the capture dimensions, and the maximum
channel difference. For localization, save each capture as PNG or copy it into
a defined sRGB RGBA format, then compare the footer crops before and after a
one-pixel translation. Keep the deliberate one-pixel content offset as a
positive control for the comparison instrument.

Remove the restored diagnostic file afterwards. Do not increase the tolerance
or the discarded-capture count to turn an unexplained result into a passing
regression test. Issue #94 remains open until the cause is understood or the
first-render behavior is fixed.

## Bounded follow-up, September 27, 2026

The current footer uses a plain `HStack` with separately sized SF Symbol and
text views inside a fixed-height button. No application offset, conditional
symbol placement or first-capture state was found in that path. That source
trace does not explain the framework's intermittent raster movement.

`PanelRenderProbeTests` is an opt-in evidence collector. It retains the
original probe's renderer lifetime and compares four consecutive captures,
including the first. It saves PNGs plus the dimensions, maximum channel
difference, changed-pixel count and bounds for each adjacent pair. A deliberate
one-pixel offset remains the comparison's positive control. Unexplained
capture differences do not become pass/fail assertions or alter product code.

Run it as part of the complete host-free app suite:

```sh
TEST_RUNNER_CANDELA_RENDER_PROBE_DIR=/tmp/candela-panel-render-probe make test-app
```

Xcode forwards the prefixed variable to the test runner as
`CANDELA_RENDER_PROBE_DIR`. Confirm that the directory contains `report.json`
and `panel-0.png` through `panel-3.png`; a suite pass without those files is not
evidence that the opt-in probe ran. Use a fresh output directory for each pass.
A run with identical captures does not disprove the earlier intermittent
movement. Native panel sizing tests still cover the AppKit host independently;
visible menu movement requires a separate interactive observation.

### Result of the full-suite probe

The September 27 run on macOS 26.7, build 25G229, produced four 280 by 243
captures. The opt-in test ran in the full app suite, and the renderer probe
and its positive control passed.

| Pair | Maximum channel difference | Changed pixels |
| --- | ---: | ---: |
| First to second | 127 | 376 |
| Second to third | 1 | 10 |
| Third to fourth | 0 | 0 |
| Deliberate one-pixel offset | 255 | 5,631 |

This run moved the gear and power glyphs **85 pixels downward**, rather than
the one-pixel movement recorded earlier. In PNG coordinates, the gear moved
from x 17–29, y 136–148 to y 221–233. The power glyph moved by the same amount.
The gear's alpha total remained 7,388 and the power glyph's remained 4,867.
Translating the first glyph crops down 85 pixels made each byte-identical to
the second capture's corresponding crop. The large channel difference again
came from placement, not a changed glyph or color.

The captures are diagnostic renders, not native menu screenshots. The varying displacement leaves the
framework trigger unresolved and provides no basis for a fixed offset,
warm-up count, relaxed tolerance, or shipping UI change.

### Native pause-control capture

Offscreen native captures show the paused OLED status and expanded pause
actions in light and dark appearances. The closed panel is 280 by 468
points and the expanded panel is 280 by 570 points, rendered at scale 2.
The deadline, all three pause actions and the explanatory caption fit. The
brightness and volume sliders remain prominent, and the footer is not clipped.

The dark OLED settings capture is 684 by 1,050 points. The deadline, Resume Now
button and Change Duration menu fit on one row within the existing Dimming
card. The first fixture also produced a light settings image, but that image
is not representative: `SettingsRootView` pins dark appearance in the app.
The probe now captures the settings page only in that supported appearance.

These native captures use fake displays and windows that are never ordered
on screen. The test opens the care disclosure through its accessibility
action. It does not activate Keep Awake, and it does not exercise live NSMenu
tracking or physical monitor output. Timed Keep Awake presentation and the
interactive menu remain part of the manual pass.

The test also confirms that opening the Keep Awake disclosure does not
activate Keep Awake. OLED settings are captured in the supported dark
appearance only. No product code changed for these fixture corrections.

## Keep Awake slider and native menu sizing, September 30

Keep Awake now exposes a stepped duration slider only after expansion. The
compact row retains its on/off toggle. The seven stops are 15 minutes, 30
minutes, 1 hour, 2 hours, 4 hours, 8 hours and Until turned off. Choosing a
stop starts a hold for that long whether Keep Awake was off or on, and choosing
one while on, the stop already shown included, replaces the deadline from the
current time. Opening the disclosure alone starts nothing. Custom End Time
opens the shared picker, styled with the same dark window, card and button
tokens as Settings.

The one-display report reproduced a native tracking defect. SwiftUI's host grew
while AppKit retained the compact menu window height, squeezing the display
viewport and clipping the footer. Offscreen captures and host-only sizing tests
did not detect that tracking-window mismatch.

The initial refit finished tracking without animation and reopened the menu
at the same anchor after layout. The disclosure stays expanded through that
transition, and the normal menu-close hardware refresh is skipped during the
refit. Explicit closing actions cancel pending refits so the custom-time picker
does not reopen the compact menu behind it.

The opt-in native tracking regression reproduces both the original geometry
defect and the picker reopening the menu, and passes on the fix, covering
sustained expanded tracking, footer containment and menu dismissal for the
picker. Run it with
`TEST_RUNNER_CANDELA_NATIVE_MENU_TEST=1 xcodebuild -project Candela.xcodeproj
-scheme CandelaAppTests -destination 'platform=macOS' -derivedDataPath DerivedData
-only-testing:CandelaAppTests/PanelSizingTests test`.

The capture-enabled probe writes the expanded menu in light and dark and the
end-time picker in its valid and invalid states. The picker is captured dark
only: `EndTimePickerView` pins the dark scheme itself, so a light capture would
show the same window. The running candidate's one-display menu grew from 154 to
257 points. Live actions started a one-hour hold, replaced it with 15 minutes
and switched to indefinite; all three states reused the same Candela Keep Awake
assertion, and switching off removed it.


## Anchored menu animation, September 30

The initial cancel-and-reopen refit above has been replaced. Disclosure changes
now resize the same native tracking window around its top edge, using the
existing window-resize duration and Reduce Motion policy. Keep Awake animates
only its chevron and the new controls' opacity. A second SwiftUI layout animation
would temporarily expand and shrink the flexible display viewport while the
native window was already growing.

The native regression reproduced a 103-point vertical movement in existing
brightness controls. AppKit laid out its menu scroll container at the final
height before the window animation, retaining its default bottom anchor. The
container now follows the content view's top edge. The resize starts from the
frame captured before disclosure layout can cause an automatic AppKit resize.
A legacy scrollbar also briefly narrowed the slider by 17 points during
collapse. The panel now uses the same overlay scrollbar helper as Settings.

A built-in-only case additionally reproduced about 12 points of movement while
both SwiftUI layout and AppKit window geometry animated. Limiting Keep Awake's
SwiftUI animation to opacity and the chevron removes that competing layout
animation. The final native test samples brightness control position and size
every 16 ms through expansion, collapse and another expansion. It waits for the
initial menu entrance to finish before recording its baseline.

With the native menu checks enabled, both the Color LCD-only fixture and the fixture with a scripted
external display measured **0 points of brightness-control movement**. Their
window heights were 239 → 342 → 239 and 416 → 519 → 416 points respectively.
These fixtures include an accessibility warning banner, so their heights differ
from the user's ordinary compact menu. The test also verifies the same window,
a stationary top edge, intermediate resize frames, complete footer visibility,
the duration slider disappearing on collapse and dismissal before the custom
picker opens.

This verifies real native menu tracking and control geometry on the built-in
screen. The external display in the second case is scripted; it adds no physical
external-display, HDR or OLED verification.


## Rendered compact-header correction, September 30

The earlier geometry checks missed a rendered frame in the smallest menu: Color
LCD and Keep Awake, without the accessibility banner. A recording of actual
pointer clicks reproduced the report. In frame 34, the Keep Awake header briefly
rendered at the top of the window before returning to its normal position.
Accessibility measurements taken after layout had settled did not show this.

The native host now owns the disclosure input and updates that input and the
tracking window geometry synchronously in the click action. A custom panel
layout measures pinned rows independently of the previous host height and caps
only the display viewport. This prevents an expanded disclosure from temporarily
using the old compact window's space. The existing top-anchored resize, chevron
animation, opacity transition and Reduce Motion behavior remain in use.

The final live recording contains 81 captured frames across two expansions and
two collapses. The Keep Awake cup remained at the same vertical position in every
frame; the brightness slider also remained stationary. This is a
variable-frame-rate recording of actual rendered changes, not a claim of
continuous fixed-rate sampling.

The native regression now includes the exact no-banner compact case and samples
both brightness and Keep Awake controls. All three fixtures measured zero points
of existing-control movement: 154 → 257 → 154 points without a banner,
239 → 342 → 239 with a banner, and 416 → 519 → 416 with a scripted external
screen and banner. A separate regression checks disclosure layout while the
host still has its old height.

The scripted display does not add physical external-display verification.
