#!/bin/bash
# Installs ASCII Wallpaper: builds the app from source on this Mac, puts it in
# ~/Applications, starts it, and starts it at login.
#   curl -fsSL https://raw.githubusercontent.com/Arz-Gev/visual/main/install.sh | bash
set -euo pipefail

REPO="Arz-Gev/visual"
BRANCH="${ASCII_WALLPAPER_BRANCH:-main}"
APP="ASCII Wallpaper"
EXE="ASCIIWallpaper"
ID="com.arzgev.asciiwallpaper"
DEST="$HOME/Applications/$APP.app"
AGENT="$HOME/Library/LaunchAgents/$ID.plist"

[[ "$(uname)" == Darwin ]] || { echo "ASCII Wallpaper is for macOS only."; exit 1; }
if ! xcrun --find swiftc >/dev/null 2>&1; then
  echo "This needs Apple's command line tools to build the app. Run:"
  echo "  xcode-select --install"
  echo "then run this installer again."
  exit 1
fi

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# Use the checkout this script sits in, or download the repo.
HERE="$(cd "$(dirname "${BASH_SOURCE[0]:-.}")" 2>/dev/null && pwd || true)"
if [[ -n "$HERE" && -f "$HERE/app/main.swift" ]]; then
  SRC="$HERE"
else
  echo "Downloading $REPO..."
  mkdir "$WORK/src"
  curl -fsSL "https://codeload.github.com/$REPO/tar.gz/refs/heads/$BRANCH" | tar xz -C "$WORK/src" --strip-components 1
  SRC="$WORK/src"
fi

echo "Building..."
BUNDLE="$WORK/$APP.app"
mkdir -p "$BUNDLE/Contents/MacOS" "$BUNDLE/Contents/Resources/web/ascii-magic-art"
xcrun swiftc -O -swift-version 5 -o "$BUNDLE/Contents/MacOS/$EXE" "$SRC/app/main.swift" \
  -framework Cocoa -framework WebKit
cp "$SRC/app/Info.plist" "$BUNDLE/Contents/Info.plist"
cp "$SRC/wallpaper.html" "$BUNDLE/Contents/Resources/web/"
for f in runtime lib pieces categories.json LICENSE NOTICE; do
  cp -R "$SRC/ascii-magic-art/$f" "$BUNDLE/Contents/Resources/web/ascii-magic-art/"
done
codesign --force --deep --sign - "$BUNDLE" >/dev/null 2>&1

echo "Installing to $DEST..."
pkill -x "$EXE" 2>/dev/null && sleep 1 || true
mkdir -p "$HOME/Applications"
rm -rf "$DEST"
mv "$BUNDLE" "$DEST"

mkdir -p "$(dirname "$AGENT")"
cat > "$AGENT" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>$ID</string>
  <key>ProgramArguments</key>
  <array><string>/usr/bin/open</string><string>-a</string><string>$DEST</string></array>
  <key>RunAtLoad</key><true/>
</dict>
</plist>
EOF

open "$DEST"
echo "Done. ASCII Wallpaper is running; use the ✨ icon in the menu bar to change it."
echo "Uninstall: curl -fsSL https://raw.githubusercontent.com/$REPO/main/uninstall.sh | bash"
