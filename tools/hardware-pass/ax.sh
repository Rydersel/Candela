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
BIND='set cands to (every window whose name does not start with "Candela Gamma Activity Enforcer" and name does not start with "Candela OLED Care Overlay")
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
SB="UI element 1 of UI element 1 of UI element 1 of UI element 1 of w"
DETAIL="UI element 1 of UI element 3 of UI element 1 of UI element 1 of w"

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
            return "$1 -> " & (value of u as text)
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
