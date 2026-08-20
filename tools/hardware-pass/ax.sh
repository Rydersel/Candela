#!/bin/zsh
# AX helpers for driving the Candela settings window during Checkpoint 1 §6.
# The settings window must be found by exclusion: Candela also owns a 1x1
# "Candela Gamma Activity Enforcer" window whose presence shifts window indices.

# Select by EXCLUSION, not by geometry and not by index. Candela also owns a 1x1
# gamma enforcer window and a full-screen OLED care overlay, both of which come
# and go and shift every index.
#
# This used to select on `size is {900, 568}`. That broke on 2026-08-11 when the
# This used to select on `size is {900, 568}`. That broke on 2026-08-11 when the
# window came up 1005x580 (#149), and the root cause makes a size selector
# permanently unusable rather than merely stale: **the size is not a property of
# the app at all.** AppKit autosaves this window's frame, size included, under
# `NSWindow Frame com_apple_SwiftUI_Settings_window` in com.rydersel.Candela and
# restores it ahead of anything SwiftUI computes, so any resize sticks for good.
# 900x568 was never an ideal either; with the key deleted the window comes up
# 900x520, and `idealHeight` is 560. Do not put a literal size back.
#
# It then selected on `name does not start with "Candela "`, which has its own
# hole: the settings window is USUALLY named for its current pane ("General",
# "Keyboard", "MAG 341C OLED"), but it was measured on 2026-08-11 reporting
# "Candela Settings", the scene's default name, while it was the app's only
# window. A prefix rule throws the real window away exactly then. So exclude the
# two decoys by their OWN names, which admits the settings window under either
# name.
#
# That trades one fragility for another: a prefix rule survives a new decoy
# nobody has seen, and this one does not. Hence the count check below. Neither
# rule can be trusted to be right forever, so the script's job is to FAIL LOUDLY
# when it is wrong rather than return a confident wrong window: a zero-match
# selector reports every control missing, which reads exactly like a real defect
# in the app, and that has already cost one issue filed against a defect that did
# not exist.
# "Display resolution" and "Display mirroring" are the keep/revert countdown
# windows: transient, legitimate, and open exactly when a pick just landed, so
# a selector that errors on them misdiagnoses a successful pick as a selector
# failure. They are excluded like the decoys; axprobe reaches INTO them (it
# walks every candidate), which is how Keep is pressed.
BIND='set cands to (every window whose name does not start with "Candela Gamma Activity Enforcer" and name does not start with "Candela OLED Care Overlay" and name does not start with "Display resolution" and name does not start with "Display mirroring" and name is not "Display Health")
    if (count of cands) is not 1 then
      set seen to ""
      repeat with x in windows
        set nm to "(unnamed)"
        try
          set nm to name of x as text
        end try
        set seen to seen & "  [" & nm & "]" & linefeed
      end repeat
      error "ax.sh: settings window not uniquely identified: " & (count of cands) & " candidates. Open windows:" & linefeed & seen
    end if
    set w to item 1 of cands'
# MEASURED 2026-08-20 against the restyled hand-built shell (SV4): the window
# is one AXGroup holding two scroll areas, sidebar first, detail second. The
# old four-level paths were the NavigationSplitView's and stopped resolving
# the day the shell changed; "Display Health" joined the exclusions the same
# day, since that window now coexists with settings (OCR-A1).
SB="UI element 1 of UI element 1 of w"
DETAIL="UI element 2 of UI element 1 of w"

# nav <sidebar-index>
nav() {
  osascript <<EOF 2>&1
tell application "System Events"
  tell process "Candela"
    $BIND
    click (UI element $1 of $SB)
    delay 1.0
  end tell
end tell
EOF
}

# dump — every labelled control in the detail pane, with its value
dump() {
  osascript <<EOF 2>&1
tell application "System Events"
  tell process "Candela"
    $BIND
    set dg to $DETAIL
    set out to ""
    set i to 0
    repeat with t in (UI elements of dg)
      set i to i + 1
      -- The restyled shell's detail area holds controls DIRECTLY (measured
      -- 2026-08-20); classify the child itself, then still descend one level
      -- for any row that nests its control.
      set cl to (class of t as text)
      set nm to ""
      try
        set nm to name of t as text
      end try
      set vl to ""
      try
        set vl to value of t as text
      end try
      if cl is "checkbox" or cl is "pop up button" or cl is "slider" or cl is "text field" then
        set out to out & i & " [" & cl & "] " & nm & " = " & vl & linefeed
      else if cl is "static text" then
        set out to out & i & " . " & vl & linefeed
      end if
      try
        repeat with u in (UI elements of t)
          set cl to (class of u as text)
          set nm to ""
          try
            set nm to name of u as text
          end try
          set vl to ""
          try
            set vl to value of u as text
          end try
          if cl is "checkbox" or cl is "pop up button" or cl is "slider" or cl is "text field" then
            set out to out & i & " [" & cl & "] " & nm & " = " & vl & linefeed
          else if cl is "static text" then
            set out to out & i & " . " & vl & linefeed
          end if
        end repeat
      end try
    end repeat
    return out
  end tell
end tell
EOF
}

# toggle <checkbox name> — click it, report before/after
toggle() {
  osascript <<EOF 2>&1
tell application "System Events"
  tell process "Candela"
    $BIND
    set dg to $DETAIL
    repeat with t in (UI elements of dg)
      set nm to ""
      try
        set nm to name of t as text
      end try
      if (class of t as text) is "checkbox" and nm is "$1" then
        set b to value of t as text
        click t
        delay 1.2
        set a to value of t as text
        return "$1: " & b & " -> " & a
      end if
      try
        repeat with u in (UI elements of t)
          set nm to ""
          try
            set nm to name of u as text
          end try
          if (class of u as text) is "checkbox" and nm is "$1" then
            set b to value of u as text
            click u
            delay 1.2
            set a to value of u as text
            return "$1: " & b & " -> " & a
          end if
        end repeat
      end try
    end repeat
    return "NOT FOUND: $1"
  end tell
end tell
EOF
}

# pick <popup name> <menu item> — choose an item from a pop-up
pick() {
  osascript <<EOF 2>&1
tell application "System Events"
  tell process "Candela"
    $BIND
    set dg to $DETAIL
    repeat with t in (UI elements of dg)
      set nm to ""
      try
        set nm to name of t as text
      end try
      if (class of t as text) is "pop up button" and nm is "$1" then
        click t
        delay 0.6
        click menu item "$2" of menu 1 of t
        delay 1.2
        set v to "(value unreadable: reconfigure in flight)"
        try
          set v to value of t as text
        end try
        return "$1 -> " & v
      end if
      try
        repeat with u in (UI elements of t)
          set nm to ""
          try
            set nm to name of u as text
          end try
          if (class of u as text) is "pop up button" and nm is "$1" then
            click u
            delay 0.6
            click menu item "$2" of menu 1 of u
            delay 1.2
            -- The click may fire a display reconfigure that tears the AX tree;
            -- reading the value back then throws, and the outer try would turn
            -- a SUCCESSFUL pick into NOT FOUND. The click is the deed; the
            -- readback is best-effort.
            set v to "(value unreadable: reconfigure in flight)"
            try
              set v to value of u as text
            end try
            return "$1 -> " & v
          end if
        end repeat
      end try
    end repeat
    return "NOT FOUND: $1"
  end tell
end tell
EOF
}

# title: the settings window's own name. Read it back after every `nav`: the
# sidebar index table is a property of the current build, and the inert rows
# (measured 2026-08-20: the wordmark at 1, headers at 3, 8 and 14) leave the
# title on the PREVIOUS pane rather than erroring, so a script that trusts the
# table reads the wrong pane's controls while every call reports success.
title() {
  osascript <<EOF 2>&1
tell application "System Events"
  tell process "Candela"
    $BIND
    return name of w
  end tell
end tell
EOF
}

# items <popup name>: the pop-up's menu item names, one per line, choosing
# nothing. The items do not exist in the tree until the menu is open, so this
# opens it and closes it with Escape. Needed because a size item's label carries
# whatever marks apply to it ("Recommended", "Rendered by Candela"), and a
# hard-coded label is a selector that silently matches nothing the day a mark
# changes.
items() {
  osascript <<EOF 2>&1
tell application "System Events"
  tell process "Candela"
    $BIND
    set dg to $DETAIL
    repeat with t in (UI elements of dg)
      set nm to ""
      try
        set nm to name of t as text
      end try
      if (class of t as text) is "pop up button" and nm is "$1" then
        click t
        delay 0.6
        set out to ""
        repeat with mi in (menu items of menu 1 of t)
          set mn to ""
          try
            set mn to name of mi as text
          end try
          set out to out & mn & linefeed
        end repeat
        key code 53
        delay 0.3
        return out
      end if
      try
        repeat with u in (UI elements of t)
          set nm to ""
          try
            set nm to name of u as text
          end try
          if (class of u as text) is "pop up button" and nm is "$1" then
            click u
            delay 0.6
            set out to ""
            repeat with mi in (menu items of menu 1 of u)
              set mn to ""
              try
                set mn to name of mi as text
              end try
              set out to out & mn & linefeed
            end repeat
            key code 53
            delay 0.3
            return out
          end if
        end repeat
      end try
    end repeat
    return "NOT FOUND: $1"
  end tell
end tell
EOF
}

# statusicon — is the menu-bar status item present?
statusicon() {
  osascript -e 'tell application "System Events" to tell process "Candela" to get count of menu bar items of menu bar 2' 2>&1
}

"$@"
