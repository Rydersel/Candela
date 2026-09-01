#!/bin/zsh
# AX helpers for driving the Candela settings window during a hardware pass.
# The settings window must be found by exclusion: Candela also owns a 1x1
# "Candela Gamma Activity Enforcer" window whose presence shifts window indices.

# Select by EXCLUSION, not by geometry and not by index. Candela also owns a 1x1
# gamma enforcer window and a full-screen OLED care overlay, both of which come
# and go and shift every index.
#
# NEVER select on size. AppKit autosaves this window's frame under `NSWindow
# Frame com_apple_SwiftUI_Settings_window` in com.rydersel.Candela and restores
# it ahead of anything SwiftUI computes, so the size is not a property of the app
# and any resize sticks for good.
#
# A `name does not start with "Candela "` rule has its own hole: the window is
# usually named for its current pane, but it was measured reporting "Candela
# Settings", the scene default, while it was the app's only window. So the decoys
# are excluded by their OWN names, which admits the window under either name.
#
# That trades one fragility for another, since this rule does not survive a new
# decoy. Hence the count check below: a zero-match selector reports every control
# missing, which reads exactly like a real defect in the app, and that has
# already cost one issue filed against a defect that did not exist.
# The keep/revert countdown windows and the checkup windows are excluded too:
# transient, legitimate, and open exactly when a pick or a checkup just landed,
# so a bind that errors on them misdiagnoses success as a selector failure
# (measured 2026-09-01: both cases read as the settings window being gone).
# axprobe reaches INTO them, which is how Keep is pressed. Any window that can
# be open beside settings belongs on this list.
BIND='set cands to (every window whose name does not start with "Candela Gamma Activity Enforcer" and name does not start with "Candela OLED Care Overlay" and name does not start with "Display resolution" and name does not start with "Display orientation" and name does not start with "Display mirroring" and name does not start with "Candela Checkup" and name is not "Display Health" and name is not "Heat Map" and name is not "Candela Setup")
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
# MEASURED 2026-08-20 against the hand-built shell (SV4): the window is one
# AXGroup holding two scroll areas, sidebar first, detail second. The map window
# coexists with settings (OCR-A1) and is excluded under BOTH its titles, so this
# selector keeps working against an older installed build.
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
# sidebar index table is a property of the current build, and an inert row (a
# header, the wordmark) leaves the title on the PREVIOUS pane rather than
# erroring, so a script trusting the table reads the wrong pane and reports ok.
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
