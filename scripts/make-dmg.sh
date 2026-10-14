#!/bin/sh
# Packs build/Shellpane.app into a disk image with an Applications shortcut and a short note.
#   scripts/make-dmg.sh                 → build/Shellpane-<version>-beta.dmg and build/Shellpane.dmg
#                                         (run scripts/bundle.sh first)
# Until it is signed with a Developer ID and notarised, macOS blocks the first open on other Macs; the note says
# how to allow it.
set -eu
cd "$(dirname "$0")/.."
APP=build/Shellpane.app
[ -d "$APP" ] || { echo "no $APP: run scripts/bundle.sh first"; exit 1; }
VERSION=$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" "$APP/Contents/Info.plist")
DMG="build/Shellpane-$VERSION-beta.dmg"
STAGE=$(mktemp -d); trap 'rm -rf "$STAGE"' EXIT
ditto "$APP" "$STAGE/Shellpane.app"
ln -s /Applications "$STAGE/Applications"
cat > "$STAGE/How to open Shellpane.txt" <<NOTE
Shellpane $VERSION beta

1. Drag Shellpane onto Applications.

2. Open it from Applications. This beta isn't notarised by Apple yet, so the first time macOS says
   it can't verify it. Click Done (not Move to Trash), then:
   System Settings > Privacy & Security > scroll down > "Shellpane was blocked…" > Open Anyway.
   You only do this once.

3. The hosts in your ~/.ssh/config are in the sidebar. Click one to connect.
   No config? Use Add Server… in the sidebar.

Keys: Space marks, F5 copies to the other pane, F6 moves, F4 edits on the server, / filters,
→ and ← open and close a folder in place.
Click the empty part of the path bar (or ⌘L) to type a path; the ☆ there keeps a folder, on your Mac
or on a server, under Favorite Folders in the sidebar. Your Finder Favorites and tags are in the
sidebar too; click a tag to list everything with it.

Needs macOS 14 or later. Works on Apple silicon and Intel Macs.
Shellpane collects nothing and connects only to the servers you open.
Found a problem? Open an issue at https://github.com/tfcoelho/shellpane/issues
NOTE
rm -f "$DMG"
hdiutil create -quiet -volname "Shellpane $VERSION beta" -srcfolder "$STAGE" -fs HFS+ -format UDZO -ov "$DMG"
# The same image under a fixed name, for GitHub Releases: the website's Download button points at
# releases/latest/download/Shellpane.dmg, which always serves the newest release's copy.
cp "$DMG" build/Shellpane.dmg
echo "wrote $DMG ($(du -h "$DMG" | cut -f1)) and build/Shellpane.dmg"
