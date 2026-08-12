#!/bin/zsh
# AX helpers for driving the Candela settings window during Checkpoint 1 §6.
# The settings window must be found by exclusion: Candela also owns a 1x1
# "Candela Gamma Activity Enforcer" window whose presence shifts window indices.

# Select by EXCLUSION, not by geometry and not by index. Candela also owns a 1x1
# gamma enforcer window and a full-screen OLED care overlay, both of which come
# and go and shift every index, and both are named "Candela ...". The settings
# window is named for its current pane ("General", "Keyboard", "MAG 341C OLED"),
# so nothing else can match.
#
# This used to select on `size is {900, 568}`. That broke on 2026-08-11 when the
# window silently became 1005x580 (#149): every script here failed at once, and
# the size is now known not to be stable. Do not put a literal size back.
W='first window whose name does not start with "Candela "'
SB="UI element 1 of UI element 1 of UI element 1 of UI element 1 of w"
DETAIL="UI element 1 of UI element 3 of UI element 1 of UI element 1 of w"

# nav <sidebar-index>
nav() {
  osascript <<EOF 2>&1
tell application "System Events"
  tell process "Candela"
    set w to $W
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
    set w to $W
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
    set w to $W
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
    set w to $W
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
