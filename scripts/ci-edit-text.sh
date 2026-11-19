#!/usr/bin/env bash
# Types new text over the text ci-click-page.sh selected, applies it with Return, checks that
# PaperKnife reports what it should, and takes a screenshot. Needs cliclick, and accessibility
# access for this shell.
#
# Usage: ci-edit-text.sh <new text> <expected report> <screenshot.png>
set -euo pipefail
source "$(dirname "$0")/ci-ax.sh"

cliclick "t:$1" "kp:return"
sleep 5
screencapture -x "$3"

list=$(elements)
if ! awk -F '\t' -v want="$2" '$1 == "AXStaticText" && index($7, want) { found = 1 } END { exit !found }' <<< "$list"; then
  echo "PaperKnife didn't report \"$2\". The window has:"
  echo "$list"
  exit 1
fi

echo "PaperKnife reported \"$2\"."