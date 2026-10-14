#!/bin/sh
# Password logins, end to end: Shellpane → /usr/bin/ssh → askpass → a password-only test server
# (e2e/password_server.py, paramiko) → OpenSSH's sftp-server. Needs Python 3 with paramiko:
#   SHELLPANE_PW_PYTHON=/path/to/venv/bin/python e2e/password.sh
# Uses a throwaway Keychain service (app.shellpane.e2e) and deletes its items afterwards.
set -eu
cd "$(dirname "$0")/.."
PY=${SHELLPANE_PW_PYTHON:-python3}
"$PY" -I -c "import paramiko" 2>/dev/null || { echo "e2e/password.sh: needs paramiko (set SHELLPANE_PW_PYTHON to a venv's python)" >&2; exit 2; }
swift build --product ShellpaneApp >/dev/null
swift build --product shellpane-askpass >/dev/null
BIN="$(swift build --show-bin-path)/ShellpaneApp"

T=$(mktemp -d "${TMPDIR:-/tmp}/shellpane-pw.XXXXXX"); T=$(cd "$T" && pwd -P)
PORT=$(python3 -I -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1", 0)); print(s.getsockname()[1]); s.close()')
PID=""
cleanup() {
  [ -n "$PID" ] && kill "$PID" 2>/dev/null || true
  security delete-generic-password -s app.shellpane.e2e >/dev/null 2>&1 || true
  rm -rf "$T"
}
trap cleanup EXIT INT TERM

mkdir -p "$T/root/site" "$T/data"
printf 'hello over a password login\n' > "$T/root/site/hello.txt"
ssh-keygen -q -t rsa -b 2048 -m PEM -N "" -f "$T/hostkey"
cat > "$T/ssh_config" <<CFG
Host pwbox
  HostName 127.0.0.1
  Port $PORT
  User tester
  UserKnownHostsFile $T/known_hosts
  StrictHostKeyChecking ask
  PubkeyAuthentication no
  IdentityAgent none
  ControlMaster no
  ControlPath none
CFG
"$PY" -I e2e/password_server.py "$PORT" tester "correct horse 42" "$T/root" "$T/hostkey" > "$T/server.log" 2>&1 &
PID=$!
n=0; until grep -q ready "$T/server.log" 2>/dev/null || [ $n -ge 50 ]; do sleep 0.1; n=$((n+1)); done

SHELLPANE_SSH_CONFIG="$T/ssh_config" SHELLPANE_DATA_DIR="$T/data" SHELLPANE_KEYCHAIN_SERVICE=app.shellpane.e2e \
SHELLPANE_PW_ROOT="$T/root" SHELLPANE_PW_PASSWORD="correct horse 42" \
  perl -e 'alarm 120; exec @ARGV' "$BIN" --selftest-password
