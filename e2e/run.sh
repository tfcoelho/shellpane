#!/bin/sh
# End-to-end check of the real app against a throwaway SSH server on 127.0.0.1.
# Builds the app, starts a user-mode sshd (its own host key, client key, known_hosts, ssh_config),
# fills it with a fake website, runs `ShellpaneApp --selftest`, and removes everything afterwards.
# Never touches ~/.ssh, your saved servers, or your Keychain.
#
#   e2e/run.sh            exit 0 = every case passed (SKIP lines are cases that need Shellpane frontmost;
#                         run it without using other apps meanwhile to get them too)
set -eu
cd "$(dirname "$0")/.."
swift build --product ShellpaneApp >/dev/null
swift build --product shellpane-askpass >/dev/null
BIN="$(swift build --show-bin-path)/ShellpaneApp"

. "$(dirname "$0")/server.sh"
trap cleanup EXIT INT TERM

mkdir -p "$T/data"
SHELLPANE_SSH_CONFIG="$T/ssh_config" SHELLPANE_DATA_DIR="$T/data" SHELLPANE_KEYCHAIN_SERVICE=app.shellpane.e2e \
SHELLPANE_EDIT_NO_OPEN=1 SHELLPANE_SELFTEST_LOCAL="$L" SHELLPANE_SELFTEST_SCREENS="${SHELLPANE_SELFTEST_SCREENS:-}" \
  perl -e 'alarm 240; exec @ARGV' "$BIN" --selftest
