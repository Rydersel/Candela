# Virtual Displays

A virtual display adds a desktop without another physical monitor. Windows can
move onto it, it appears in Arrangement, and it can be shared or recorded. It
is useful for a separate screen-sharing desktop or for trying a display layout
without connecting more hardware. Windows moved there are no longer on your
physical display.

Open **Settings → Virtual Displays**, under **Controls** in the sidebar.

## Create a display

Choose **Add Display** to create a display and select its tile. Edit the
settings below it, then choose **Apply and Recreate** to use your changes.
If the display is not running, **Create Display** starts it.

- **Name** identifies the display.
- **Size** offers common presets. Type directly into **Width and Height** for
  another size; the picker then reads **Custom**. The caption below the fields
  gives the supported range.
- **Retina (HiDPI)** renders text at double resolution when the display is next
  created. The doubled size must fit within the supported range.
- **Create Display** applies these choices. Once it is running, arrange it in
  [Arrangement](arrangement.md) or macOS Displays settings.

The page reports how many slots are available. A display that has been added
but is not running still occupies a slot.

## Status and changes

Select a display tile to see its **Status** and controls:

- **Not created** means the display is not running.
- **Working** means Candela is creating or recreating it.
- **Running**, with the achieved size when available, means the display exists.

Editing the fields does not immediately interrupt a running display. Choose
**Apply and Recreate** to apply pending changes. This stops and recreates that
display, so its windows may move during the change. If creation fails, the
page shows the reason rather than reporting that it is running.

## Come Back at Launch

Turn on **Come Back at Launch** to create that display again the next time
Candela opens, using its saved settings.

Hold Shift while launching Candela for a Safe Mode session. Displays marked to
come back are not recreated automatically, and the pane says so. **Create
Display** still works manually. Relaunch without Shift to leave Safe Mode;
your saved settings are kept.

## Remove a display

Choose **Remove Display…**, then confirm **Remove**. The display stops, its
windows move to your other displays, and the slot returns to its defaults,
including its name, size, Retina setting, and launch choice.

Use **Apply and Recreate** to change an existing display's size without
resetting its other settings.

## Limits

Virtual displays have no physical brightness or DDC controls. They do not add
another monitor you can see on your desk.

The feature depends on an undocumented macOS interface and can become
unavailable after a macOS update. See [A note on private APIs](../../README.md#a-note-on-private-apis).

macOS keeps a colour profile for each virtual display identity. Candela reuses
one stable monitor identity per slot, so recreating a display does not create a
new profile identity each time. This is separate from the slot settings that
**Remove Display…** clears.
