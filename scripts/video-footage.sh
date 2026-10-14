#!/bin/sh
# Captures the real app for the Remotion video (video/): every step of the story (the organised sidebar,
# adding a server, a Finder tag, a favourite folder) as a 3× image, with video/public/states/states.json
# listing them in order. The video animates between them at 60 fps.
# Neutral sidebar and a stand-in user name, so nothing of your own Mac appears in a public video.
set -eu
cd "$(dirname "$0")/.."
. scripts/demo-site.sh
rm -rf video/public/states
SHELLPANE_SSH_CONFIG="$D/ssh_config" SHELLPANE_DATA_DIR="$D/data" SHELLPANE_KEYCHAIN_SERVICE=app.shellpane.demo SHELLPANE_SKIP_SHELL_ENV=1 \
SHELLPANE_DEMO_SIDEBAR=1 SHELLPANE_DISPLAY_USER=deploy \
  SHELLPANE_DEMO_TAGS="Client:6,Review:7,Archive:4" SHELLPANE_DEMO_TAG_ROOT="$D/acme-site" \
  perl -e 'alarm 120; exec @ARGV' "$BIN" --states video/public/states \
  --left "$D/acme-site" --server-root "$D/srv/acme-site" --shop-root "$D/srv/shop" --dark \
  -AppleAccentColor 3 -AppleHighlightColor "0.752941 0.964706 0.678431 Green"
rm -f video/public/footage.mp4 video/public/timeline.json
ls video/public/states
