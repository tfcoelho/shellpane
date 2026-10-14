# Shared by e2e/run.sh and e2e/demo-server.sh: a throwaway sshd on 127.0.0.1 with a fake website.
# Sets T (temp root), S (server folder), L (local folder), PORT. Call `cleanup` when done.
# Never touches ~/.ssh.

T=$(mktemp -d "${TMPDIR:-/tmp}/shellpane-e2e.XXXXXX"); T=$(cd "$T" && pwd -P)
# A port the OS says is free (a fixed or PID-based one can collide with something already listening).
PORT=$(python3 -I -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1", 0)); print(s.getsockname()[1]); s.close()')
cleanup() {
  [ -f "$T/sshd.pid" ] && kill "$(cat "$T/sshd.pid")" 2>/dev/null || true
  chmod -R u+rwx "$T" 2>/dev/null || true
  rm -rf "$T" "$HOME/Library/Caches/Shellpane/Edits"
}

# The "server": a small website.
S="$T/srv/www/blog"
mkdir -p "$S/releases/2026-10-01" "$S/assets/img/icons"
printf '<!doctype html><title>Blog</title>' > "$S/index.html"
printf 'User-agent: *\n' > "$S/robots.txt"
printf 'RewriteEngine On\n' > "$S/.htaccess"
printf '#!/bin/sh\necho deploy\n' > "$S/deploy.sh"
head -c 9100 /dev/urandom > "$S/styles.css"
head -c 2000000 /dev/urandom > "$S/access.log"
head -c 240000 /dev/urandom > "$S/assets/img/hero.jpg"
printf '<svg/>' > "$S/assets/img/icons/menu.svg"

# The "Mac" side.
L="$T/local"
mkdir -p "$L/docs"
printf 'notes\n' > "$L/docs/notes.txt"
head -c 31000 /dev/urandom > "$L/app.js"
head -c 9400 /dev/urandom > "$L/styles.css"
head -c 530000 /dev/urandom > "$L/release.zip"
printf 'User-agent: *\nDisallow: /tmp/\n' > "$L/robots.txt"
printf '<!doctype html><title>Blog v2</title>' > "$L/index.html"

ssh-keygen -q -t ed25519 -N "" -f "$T/hostkey"
ssh-keygen -q -t ed25519 -N "" -f "$T/client"
cp "$T/client.pub" "$T/authorized_keys"
echo "[127.0.0.1]:$PORT $(cut -d' ' -f1,2 "$T/hostkey.pub")" > "$T/known_hosts"
cat > "$T/sshd_config" <<EOF
Port $PORT
ListenAddress 127.0.0.1
HostKey $T/hostkey
PidFile $T/sshd.pid
AuthorizedKeysFile $T/authorized_keys
PasswordAuthentication no
KbdInteractiveAuthentication no
UsePAM no
StrictModes no
PerSourcePenalties no
Subsystem sftp /usr/libexec/sftp-server -d $S
EOF
cat > "$T/ssh_config" <<EOF
Host web-1
  HostName 127.0.0.1
  Port $PORT
  User $(whoami)
  IdentityFile $T/client
  IdentitiesOnly yes
  IdentityAgent none
  UserKnownHostsFile $T/known_hosts
  ControlMaster no
  ControlPath none
EOF
/usr/sbin/sshd -f "$T/sshd_config" -E "$T/sshd.log"
n=0; until nc -z 127.0.0.1 "$PORT" 2>/dev/null || [ $n -ge 50 ]; do sleep 0.1; n=$((n+1)); done
if ! nc -z 127.0.0.1 "$PORT" 2>/dev/null; then
  echo "e2e: the test sshd didn't start on port $PORT:" >&2
  cat "$T/sshd.log" >&2
  exit 2
fi

