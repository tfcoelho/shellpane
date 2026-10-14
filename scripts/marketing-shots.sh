#!/bin/sh
# Website screenshots of the real app: the organised sidebar and a server just added, from the same story as
# the launch video (DemoStates.swift), in light and dark. Writes site/assets/shot-{light,dark}.png.
# Recording mode keeps your Mac out of them: neutral sidebar, stand-in user "deploy", demo Finder tags.
set -eu
cd "$(dirname "$0")/.."
. scripts/demo-site.sh
T=$(mktemp -d)
for mode in light dark; do
  rm -rf "$D/data"; mkdir -p "$D/data"
  SHELLPANE_SSH_CONFIG="$D/ssh_config" SHELLPANE_DATA_DIR="$D/data" SHELLPANE_KEYCHAIN_SERVICE=app.shellpane.demo SHELLPANE_SKIP_SHELL_ENV=1 \
  SHELLPANE_DEMO_SIDEBAR=1 SHELLPANE_DISPLAY_USER=deploy \
  SHELLPANE_DEMO_TAGS="Client:6,Review:7,Archive:4" SHELLPANE_DEMO_TAG_ROOT="$D/acme-site" \
    perl -e 'alarm 120; exec @ARGV' "$BIN" --states "$T/$mode" \
    --left "$D/acme-site" --server-root "$D/srv/acme-site" --shop-root "$D/srv/shop" "--$mode" \
    -AppleAccentColor 3 -AppleHighlightColor "0.752941 0.964706 0.678431 Green" >/dev/null
  shot=$(python3 -I -c 'import json,sys; print(next(s["file"] for s in json.load(open(sys.argv[1]))["states"] if s["name"] == "added"))' "$T/$mode/states.json")
  mkdir -p site/assets
  sips -z 1440 2360 "$T/$mode/$shot" --out "site/assets/shot-$mode.png" >/dev/null
  echo "wrote site/assets/shot-$mode.png"
done
rm -rf "$T"
