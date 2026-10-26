#!/bin/zsh
# AX helpers for driving the Candela settings window during a hardware pass.
# The title changes with the selected pane. macOS 27 also publishes an AppKit
# window titled "Window" beside Settings, so a title exclusion is ambiguous.
# The SwiftUI Settings scene keeps this AX identifier across those states.
# Never select by geometry: AppKit autosaves the window's size and position.
BIND='set cands to (every window whose value of attribute "AXIdentifier" is "com_apple_SwiftUI_Settings_window")
    if (count of cands) is not 1 then
      set seen to ""
      repeat with x in windows
        set nm to "(unnamed)"
        set ident to "(none)"
        try
          set nm to name of x as text
        end try
        try
          set ident to value of attribute "AXIdentifier" of x as text
        end try
        set seen to seen & "  [" & nm & "] id=" & ident & linefeed
      end repeat
      error "ax.sh: settings window not uniquely identified: " & (count of cands) & " candidates. Open windows:" & linefeed & seen
    end if
    set w to item 1 of cands'
# The window holds two scroll areas, sidebar first and detail second.
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
