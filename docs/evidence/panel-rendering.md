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
