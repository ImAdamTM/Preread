#!/bin/bash
# paste_to_simulator.sh
# Usage: ./paste_to_simulator.sh "your text here"
#    or: echo "your text" | ./paste_to_simulator.sh

set -e

# Get text from argument or stdin
if [ $# -ge 1 ]; then
    TEXT="$*"
elif ! [ -t 0 ]; then
    TEXT="$(cat)"
else
    echo "Usage: $0 \"text to paste\""
    echo "   or: echo \"text\" | $0"
    exit 1
fi

# Check that a simulator is booted
BOOTED=$(xcrun simctl list devices | grep -i booted | head -1)
if [ -z "$BOOTED" ]; then
    echo "Error: No booted simulator found. Boot a simulator first."
    exit 1
fi

echo "Copying to simulator pasteboard..."
printf '%s' "$TEXT" | xcrun simctl pbcopy booted

echo "Activating Simulator and pasting..."
osascript <<'APPLESCRIPT'
tell application "Simulator" to activate
delay 0.4
tell application "System Events"
    keystroke "v" using {command down}
end tell
APPLESCRIPT

echo "Done."