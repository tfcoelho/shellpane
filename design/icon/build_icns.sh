#!/bin/sh
# Builds Resources/AppIcon.icns and the site's favicon PNG from the SVGs in this folder.
#   design/icon/build_icns.sh
set -eu
cd "$(dirname "$0")"
python3 make_icon.py
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
swiftc -O render_png.swift -o "$TMP/render_png" 2>/dev/null
"$TMP/render_png" icon.svg "$TMP" big 1024 512 256 128 64
"$TMP/render_png" icon-small.svg "$TMP" small 32 16
"$TMP/render_png" favicon.svg "$TMP" fav 180 32
SET="$TMP/AppIcon.iconset"; mkdir "$SET"
cp "$TMP/small-16.png"  "$SET/icon_16x16.png"
cp "$TMP/small-32.png"  "$SET/icon_16x16@2x.png"
cp "$TMP/small-32.png"  "$SET/icon_32x32.png"
cp "$TMP/big-64.png"    "$SET/icon_32x32@2x.png"
cp "$TMP/big-128.png"   "$SET/icon_128x128.png"
cp "$TMP/big-256.png"   "$SET/icon_128x128@2x.png"
cp "$TMP/big-256.png"   "$SET/icon_256x256.png"
cp "$TMP/big-512.png"   "$SET/icon_256x256@2x.png"
cp "$TMP/big-512.png"   "$SET/icon_512x512.png"
cp "$TMP/big-1024.png"  "$SET/icon_512x512@2x.png"
mkdir -p ../../Resources ../../site/assets
iconutil -c icns "$SET" -o ../../Resources/AppIcon.icns
cp "$TMP/big-1024.png" ../../Resources/AppIcon-1024.png
cp "$TMP/fav-180.png" ../../site/assets/apple-touch-icon.png
cp favicon.svg ../../site/assets/favicon.svg
echo "wrote Resources/AppIcon.icns, site/assets/favicon.svg, site/assets/apple-touch-icon.png"
