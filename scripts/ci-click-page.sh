#!/usr/bin/env bash
# Clicks the page PaperKnife shows, checks that the text there is selected for editing, and takes a
# screenshot. The point is given from the page's top-left corner in fractions of the page's width,
# as the page can be taller than the window. Needs cliclick, and accessibility access for this shell.
#
# Usage: ci-click-page.sh <x> <y> <expected text> <screenshot.png>
set -euo pipefail

# Every element of PaperKnife's window, one per line: role, description, left, top, width, height,
# value (for text fields), title and accessibility identifier, separated by tabs.
elements() {
  osascript <<'APPLESCRIPT'
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
      if elementRole is "AXTextField" then
        try
          set elementValue to value of element
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

list=$(elements)
page=$(awk -F '\t' '$1 == "AXImage" && $9 == "page" { print $3, $4, $5; exit }' <<< "$list")
if [ -z "$page" ]; then
  echo "PaperKnife doesn't show a page. Its window has:"
  echo "$list"
  exit 1
fi

read -r left top width <<< "$page"
x=$(awk -v l="$left" -v w="$width" -v f="$1" 'BEGIN { printf "%d", l + f * w }')
y=$(awk -v t="$top" -v w="$width" -v f="$2" 'BEGIN { printf "%d", t + f * w }')
echo "The page is at ($left, $top), $width wide; clicking ($x, $y)."
cliclick "c:$x,$y"
sleep 3
screencapture -x "$4"

list=$(elements)
value=$(awk -F '\t' '$1 == "AXTextField" { print $7; exit }' <<< "$list")
if [ "$value" != "$3" ]; then
  echo "The selected text is \"$value\", not \"$3\". The window has:"
  echo "$list"
  exit 1
fi

echo "\"$3\" is selected for editing."