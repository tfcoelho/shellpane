#!/bin/sh
# Starts the same demo server the end-to-end tests use and leaves it running until Ctrl-C,
# so you can point Shellpane and another SFTP client at identical data (for side-by-side screenshots).
set -eu
cd "$(dirname "$0")/.."
swift build --product ShellpaneApp >/dev/null
swift build --product shellpane-askpass >/dev/null
. e2e/server.sh
trap cleanup EXIT INT TERM
cat <<EOF

Demo server running. Same data in both apps:

  Shellpane:     SHELLPANE_SSH_CONFIG=$T/ssh_config $(swift build --show-bin-path)/ShellpaneApp
             (then click "web-1" in the sidebar)
  Other app: SFTP
             Server 127.0.0.1   Port $PORT   User $(whoami)
             Password field, key icon, private key: $T/client
  Terminal:  ssh -F $T/ssh_config web-1

The "server" folder is $S
The "Mac" folder is    $L

Press Ctrl-C to stop and delete everything.
EOF
while :; do sleep 3600; done
