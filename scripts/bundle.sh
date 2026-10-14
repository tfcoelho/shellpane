#!/bin/sh
# Builds Shellpane.app from the Swift package. No Xcode needed.
#
#   scripts/bundle.sh            release build (universal: Apple silicon + Intel), ad-hoc signed, into build/Shellpane.app
#   SIGN_ID="Developer ID Application: …" scripts/bundle.sh   signed for distribution (notarise separately)
set -eu

cd "$(dirname "$0")/.."
CONFIG=${CONFIG:-release}
VERSION=${VERSION:-0.1.0}
BUILD=${BUILD:-$(date +%Y%m%d%H%M)}
APP=build/Shellpane.app

ARCHS=${ARCHS:-arm64 x86_64}   # universal by default; ARCHS=arm64 for a quicker local build

# Each architecture builds into the same products folder, so set each result aside before the next.
PARTS=$(mktemp -d); trap 'rm -rf "$PARTS"' EXIT
for arch in $ARCHS; do
  swift build -c "$CONFIG" --triple "$arch-apple-macosx14.0" --product ShellpaneApp
  swift build -c "$CONFIG" --triple "$arch-apple-macosx14.0" --product shellpane-askpass
  BIN=$(swift build -c "$CONFIG" --triple "$arch-apple-macosx14.0" --show-bin-path)
  mkdir -p "$PARTS/$arch"
  cp "$BIN/ShellpaneApp" "$BIN/shellpane-askpass" "$PARTS/$arch/"
done

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
lipo -create $(for a in $ARCHS; do echo "$PARTS/$a/ShellpaneApp"; done) -output "$APP/Contents/MacOS/Shellpane"
# SSHConnection looks for the helper next to the app binary
lipo -create $(for a in $ARCHS; do echo "$PARTS/$a/shellpane-askpass"; done) -output "$APP/Contents/MacOS/shellpane-askpass"
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"        # from design/icon/build_icns.sh

cat > "$APP/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>Shellpane</string>
  <key>CFBundleDisplayName</key><string>Shellpane</string>
  <key>CFBundleIdentifier</key><string>com.shellpane.Shellpane</string>
  <key>CFBundleExecutable</key><string>Shellpane</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleVersion</key><string>$BUILD</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSApplicationCategoryType</key><string>public.app-category.developer-tools</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSPrincipalClass</key><string>NSApplication</string>
  <key>NSHumanReadableCopyright</key><string>© 2026 Shellpane</string>
</dict>
</plist>
EOF

# Sign the helper first, then the app. Not sandboxed by design: Shellpane runs /usr/bin/ssh and reads ~/.ssh.
SIGN_ID=${SIGN_ID:--}
codesign --force --options runtime --sign "$SIGN_ID" "$APP/Contents/MacOS/shellpane-askpass"
codesign --force --options runtime --sign "$SIGN_ID" "$APP"
codesign --verify --strict "$APP"
echo "Built $APP ($VERSION, $BUILD, $(lipo -archs "$APP/Contents/MacOS/Shellpane")), signed with: $SIGN_ID"
