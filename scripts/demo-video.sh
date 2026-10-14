#!/bin/sh
# Records the 30-second demo: the real app connects to acme-web from ~/.ssh/config, marks three new
# files with Space, copies them to the server with F5, and filters with /. Each key shows in a caption.
# Writes site/assets/demo-{light,dark}.mp4 (H.264, plays in every browser).
#   scripts/demo-video.sh            both appearances
#   scripts/demo-video.sh dark       one
# Uses a throwaway server and a fictional project; the green system accent is set for this run only.
# Recording mode: neutral sidebar and the stand-in user "deploy", so nothing of your Mac appears.
set -eu
cd "$(dirname "$0")/.."
. scripts/demo-site.sh
mkdir -p site/assets
for mode in ${1:-light dark}; do
  rm -rf "$D/data"; mkdir -p "$D/data"
  rm -f "$D/srv/acme-site/release-notes.html" "$D/srv/acme-site/sitemap.xml" "$D/srv/acme-site/feed.xml"
  SHELLPANE_SSH_CONFIG="$D/ssh_config" SHELLPANE_DATA_DIR="$D/data" SHELLPANE_KEYCHAIN_SERVICE=app.shellpane.demo SHELLPANE_SKIP_SHELL_ENV=1 \
  SHELLPANE_DEMO_SIDEBAR=1 SHELLPANE_DISPLAY_USER=deploy \
    perl -e 'alarm 90; exec @ARGV' "$BIN" --demo "site/assets/demo-$mode.mp4" --left "$D/acme-site" --right acme-web \
    --mark "feed.xml,release-notes.html,sitemap.xml" --filter "log" "--$mode" \
    -AppleAccentColor 3 -AppleHighlightColor "0.752941 0.964706 0.678431 Green"
done
