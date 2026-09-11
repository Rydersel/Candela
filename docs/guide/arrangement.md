# Arrangement

Arrange displays to match where they sit on your desk, so the pointer crosses
between the edges you expect. Candela previews each change before saving it.

Open **Settings → Arrangement**, under **Controls** in the sidebar.

## The map

Each tile represents a display in the current desktop layout. Its shape follows
that display's current size and orientation. Tiles show the display name and
logical dimensions when there is room; hover over a small tile to read them.
The strip along the top marks the main display.

Drag a tile toward a neighbour to move it. Tiles snap to nearby edges. Displays
must touch along an edge and cannot overlap; a refused move returns the tile to
its previous position and explains why. You can also Tab to a display and use
the arrow keys to move it.

You need at least two independent desktop tiles to arrange them. Mirrored
displays share one tile, so two physical displays showing the same desktop do
not provide two tiles to arrange. With one tile, the map asks you to connect
another display. An extended [virtual display](virtual-displays.md) also counts.

## Main Display

Select a tile, then choose **Use as Main Display**. This changes which display
macOS treats as primary without changing the displays' positions relative to
one another. The map's menu-bar strip moves to the chosen display.

Main-display selection affects macOS's menu-bar placement. It does not move
all your existing windows to that display or override each app's window
placement. See Apple's [guide to arranging multiple displays](https://support.apple.com/guide/mac-help/mchlb5f905a1/mac)
for the related macOS settings.

The button's caption explains when the selected display is already main or a
change cannot be made. The section appears when at least two independent desktop tiles are
available.

## Keep or revert

A move or main-display change opens a confirmation with a countdown. Choose
**Keep** to accept it or **Revert** to put the displays back. If you cannot reach
the confirmation, let the countdown run out: Candela attempts to restore the
previous arrangement automatically.

If macOS could not apply or restore the layout, the confirmation reports what
happened. Finish an outstanding resolution, rotation, mirroring, or arrangement
preview before starting another display change.

## Remembering the setup

The **Saved Display Setups** section contains **Remember display rotations and
positions**. It records a setup for the connected display set and restores it
at launch or when that set reconnects. Keeping an arrangement or rotation in
Candela updates the saved setup while remembering is enabled.

Turning remembering off preserves the saved records and stops automatic
restoration. It does not undo the arrangement currently on screen. See
[Remembering a display setup](display-setups.md) for the first-use choice,
identity matching, rotation restoration, and stale-layout notices.

When a display is disconnected, the map follows the displays still present.
Its return can trigger saved-setup restoration if remembering is enabled.
Changes made in System Settings while the displays stay connected are left
alone until a later restore.

## Safe Mode

Hold Shift while launching Candela to enter Safe Mode for that session.
Arrangement reports that no arrangement will be restored, and your saved
records are kept. Relaunch without Shift to leave Safe Mode.
