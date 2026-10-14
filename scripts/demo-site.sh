# Sourced by marketing-shots.sh and demo-video.sh: builds the app, makes a small fictional website
# project on "your Mac" ($D/acme-site) and "the server" ($D/srv/acme-site), and starts a throwaway
# user-mode sshd for the ssh_config host acme-web. Sets D and BIN; cleans up on exit.
cd "$(dirname "$0")/.."
swift build --product ShellpaneApp >/dev/null && swift build --product shellpane-askpass >/dev/null
BIN="$(swift build --show-bin-path)/ShellpaneApp"
D=/private/tmp/shellpane-demo
rm -rf "$D"; mkdir -p "$D/srv/acme-site" "$D/acme-site"
for side in "$D/srv/acme-site" "$D/acme-site"; do
  mkdir -p "$side/assets/img" "$side/css" "$side/js" "$side/posts"
  printf '<!doctype html><title>Acme</title>\n' > "$side/index.html"
  printf '<!doctype html><title>About</title>\n' > "$side/about.html"
  printf 'body{font:16px system-ui}\n' > "$side/css/site.css"
  head -c 48000 /dev/zero > "$side/js/app.js"
  printf 'User-agent: *\n' > "$side/robots.txt"
  printf '#!/bin/sh\nrsync -a ./ /srv/acme-site/\n' > "$side/deploy.sh"
  printf 'API_KEY=example\n' > "$side/.env"
done
# The client's shop, the server added on camera: a few files of its own, nothing that clashes with acme-site.
mkdir -p "$D/srv/shop/products" "$D/srv/shop/uploads"
printf '<?php echo "shop";\n' > "$D/srv/shop/index.php"
printf 'id,total\n1,49.00\n' > "$D/srv/shop/orders.csv"
head -c 2400000 /dev/zero > "$D/srv/acme-site/access.log"
head -c 820000 /dev/zero > "$D/srv/acme-site/backup-2026-10-12.tar.gz"
printf '<!doctype html><title>New post</title>\n' > "$D/acme-site/posts/shipping-friday.html"
# New on the Mac, not yet on the server: what the demo video marks and uploads.
printf '<!doctype html><title>Release notes</title>\n' > "$D/acme-site/release-notes.html"
printf '<?xml version="1.0"?><urlset/>\n' > "$D/acme-site/sitemap.xml"
printf '<?xml version="1.0"?><feed/>\n' > "$D/acme-site/feed.xml"
touch -t 202610091412 "$D/srv/acme-site"/* ; touch -t 202610121030 "$D/acme-site"/*
# Finder tags on demo files, written the way Finder writes them (a binary plist of "name\ncolour").
tag() { hex=$(python3 -I -c 'import plistlib,sys; print(plistlib.dumps([sys.argv[1]], fmt=plistlib.FMT_BINARY).hex())' "$1"); shift
        for f in "$@"; do xattr -wx com.apple.metadata:_kMDItemUserTags "$hex" "$f"; done; }
tag "Client
6" "$D/acme-site/index.html" "$D/acme-site/about.html"
tag "Review
7" "$D/acme-site/release-notes.html" "$D/acme-site/feed.xml"
tag "Archive
4" "$D/acme-site/posts"
ssh-keygen -q -t ed25519 -N "" -f "$D/hostkey"; ssh-keygen -q -t ed25519 -N "" -f "$D/client"; cp "$D/client.pub" "$D/authorized_keys"
PORT=$(python3 -I -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1", 0)); print(s.getsockname()[1]); s.close()')
echo "[127.0.0.1]:$PORT $(cut -d' ' -f1,2 "$D/hostkey.pub")" > "$D/known_hosts"
cat > "$D/sshd_config" <<CFG
Port $PORT
ListenAddress 127.0.0.1
HostKey $D/hostkey
PidFile $D/sshd.pid
AuthorizedKeysFile $D/authorized_keys
PasswordAuthentication no
KbdInteractiveAuthentication no
UsePAM no
StrictModes no
PerSourcePenalties no
Subsystem sftp /usr/libexec/sftp-server -d $D/srv/acme-site
CFG
cat > "$D/ssh_config" <<CFG
Host acme-web
  HostName 127.0.0.1
  Port $PORT
  IdentityFile $D/client
  IdentitiesOnly yes
  IdentityAgent none
  UserKnownHostsFile $D/known_hosts
# The server added on camera, typed as a real-looking address. A pattern, so it isn't listed in the sidebar.
Host *.example.com
  HostName 127.0.0.1
  Port $PORT
  IdentityFile $D/client
  IdentitiesOnly yes
  IdentityAgent none
  UserKnownHostsFile $D/known_hosts
Host staging
  HostName 127.0.0.1
  Port 1
Host db-backup
  HostName 127.0.0.1
  Port 1
CFG
/usr/sbin/sshd -f "$D/sshd_config" -E "$D/sshd.log"
trap 'kill $(cat "$D/sshd.pid") 2>/dev/null; rm -rf "$D"' EXIT
mkdir -p "$D/data"
