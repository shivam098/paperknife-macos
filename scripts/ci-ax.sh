#!/usr/bin/env bash
# Accessibility helpers for the CI scripts that drive PaperKnife's window. Source this file. Needs
# accessibility access for the shell.

# Every element of PaperKnife's window, one per line: role, description, left, top, width, height,
# value (of text fields and static texts, with line breaks as spaces), title and accessibility
# identifier, separated by tabs.
elements() {
  osascript <<'APPLESCRIPT'
on flatten(textValue)
  set AppleScript's text item delimiters to {return, linefeed, tab}
  set parts to text items of textValue
  set AppleScript's text item delimiters to " "
  set flat to parts as text
  set AppleScript's text item delimiters to ""
  return flat
end flatten

set output to ""
tell application "System Events" to tell process "PaperKnife"
  set found to entire contents of window 1
  repeat with i from 1 to count of found
    set element to item i of found
    try
      set elementRole to role of element
      set elementDescription to ""
      try
        set elementDescription to description of element
      end try
      set {x, y} to {0, 0}
      set {w, h} to {0, 0}
      try
        set {x, y} to position of element
        set {w, h} to size of element
      end try
      set elementValue to ""
      if elementRole is "AXTextField" or elementRole is "AXStaticText" then
        try
          set elementValue to my flatten(value of element as text)
        end try
      end if
      set elementTitle to ""
      try
        set elementTitle to title of element
      end try
      set elementIdentifier to ""
      try
        set elementIdentifier to value of attribute "AXIdentifier" of element
      end try
      set output to output & elementRole & tab & elementDescription & tab & x & tab & y & tab & w & tab & h & tab & elementValue & tab & elementTitle & tab & elementIdentifier & linefeed
    end try
  end repeat
end tell
return output
APPLESCRIPT
}