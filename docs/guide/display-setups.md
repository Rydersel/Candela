# Remembering a display setup

Candela can remember the positions and rotations of a set of displays and
restore them when that set reconnects or Candela starts.

When you first arrange displays in Candela and choose **Keep**, **Remember this
display setup** is selected in the confirmation. Uncheck it if you only want to
change the current arrangement. Installing or opening Candela alone does not
enable restoration, and an existing decision to turn it off stays off.

You can also enable **Remember display rotations and positions** in
**Settings → Arrangement → Saved Display Setups**. This saves the current setup. Finish any active display-change preview first.
Keeping subsequent arrangement or rotation changes in Candela updates it.
Changes made in System Settings are left alone while the displays stay connected;
the saved setup is used on their next reconnect. Turn restoration off to let
macOS handle reconnects instead.

Candela matches monitors by their stored identities, since their temporary display
IDs can change after a reconnect. It restores rotations before placing displays,
then checks the actual dimensions. A rotation failure stops position restoration;
a changed resolution, missing monitor, or ambiguous identity can prevent the saved
setup from being restored. These cases are reported in Arrangement.

Existing saved layouts continue to restore positions. They gain rotation values
the next time you save the setup. Displays saved without a rotation reading,
and synthesized display sizes, keep position-only restoration.
Rotation and position changes use separate macOS operations, so a failed restore
can leave a partially restored setup; Candela reports the failure.
