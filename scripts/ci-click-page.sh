#!/usr/bin/env bash
# Clicks the page PaperKnife shows, checks that the text there is selected for editing, and takes a
# screenshot. The point is given from the page's top-left corner in fractions of the page's width,
# as the page can be taller than the window. Needs cliclick, and accessibility access for this shell.
#
# Usage: ci-click-page.sh <x> <y> <expected text> <screenshot.png>
set -euo pipefail

# Runs AppleScript in PaperKnife's window: "element" goes over everything in it, and the script's
# result is printed.
in_window() {
  osascript - <<APPLESCRIPT
tell application "System Events" to tell process "PaperKnife"
  repeat with element in (entire contents of window 1)
    try
      $1
    end try
  end repeat
end tell
return ""
APPLESCRIPT
}

frame=$(in_window 'if role of element is "AXImage" and description of element is "Page" then return (position of element) & (size of element)')
if [ -z "$frame" ]; then
  echo "PaperKnife doesn't show a page. Its window has:"
  osascript -e 'tell application "System Events" to tell process "PaperKnife" to get {role, description} of entire contents of window 1' || true
  exit 1
fi

IFS=', ' read -r left top width _ <<< "$frame"
x=$(awk -v l="$left" -v w="$width" -v f="$1" 'BEGIN { printf "%d", l + f * w }')
y=$(awk -v t="$top" -v w="$width" -v f="$2" 'BEGIN { printf "%d", t + f * w }')
echo "The page is at $frame; clicking ($x, $y)."
cliclick "c:$x,$y"
sleep 3
screencapture -x "$4"

value=$(in_window 'if role of element is "AXTextField" then return value of element')
if [ "$value" != "$3" ]; then
  echo "The selected text is \"$value\", not \"$3\"."
  exit 1
fi

echo "\"$3\" is selected for editing."
