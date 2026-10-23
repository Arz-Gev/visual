#!/bin/bash
# Removes ASCII Wallpaper, its login item and its settings.
#   curl -fsSL https://raw.githubusercontent.com/Arz-Gev/visual/main/uninstall.sh | bash
set -uo pipefail

ID="com.arzgev.asciiwallpaper"
pkill -x ASCIIWallpaper 2>/dev/null
rm -rf "$HOME/Applications/ASCII Wallpaper.app"
rm -f "$HOME/Library/LaunchAgents/$ID.plist"
defaults delete "$ID" >/dev/null 2>&1
echo "ASCII Wallpaper removed."
