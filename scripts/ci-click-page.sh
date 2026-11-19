#!/usr/bin/env bash
# Clicks the page PaperKnife shows, checks that the text there is selected for editing, and takes a
# screenshot. The point is given from the page's top-left corner in fractions of the page's width,
# as the page can be taller than the window. Needs cliclick, and accessibility access for this shell.
#
# Usage: ci-click-page.sh <x> <y> <expected text> <screenshot.png>
set -euo pipefail

ax() {
  osascript -e "tell application \"System Events\" to tell process \"PaperKnife\" to $1"
}

frame=$(ax 'get {position, size} of first image of entire contents of window 1 whose description is "Page"')
IFS=', ' read -r left top width _ <<< "$frame"
x=$(awk -v l="$left" -v w="$width" -v f="$1" 'BEGIN { printf "%d", l + f * w }')
y=$(awk -v t="$top" -v w="$width" -v f="$2" 'BEGIN { printf "%d", t + f * w }')
echo "The page is at $frame; clicking ($x, $y)."
cliclick "c:$x,$y"
sleep 3
screencapture -x "$4"

value=$(ax 'get value of first text field of entire contents of window 1')
if [ "$value" != "$3" ]; then
  echo "The selected text is \"$value\", not \"$3\"."
  exit 1
fi

echo "\"$3\" is selected for editing."
