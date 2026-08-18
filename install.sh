#!/usr/bin/env bash
# Install v2rayA on Debian and set it up as a domain-routed local proxy.
#
# This script holds no keys and no subscription. Servers are read from
# /etc/ai-proxy/servers.list, which is created here and never leaves the machine.
#
# Verified against v2rayA 2.4.11.
set -euo pipefail

VERSION='2.4.11'
CONF_DIR='/etc/ai-proxy'
API='http://127.0.0.1:2017/api'
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

die() { echo "error: $*" >&2; exit 1; }

[ "$(id -u)" -eq 0 ] || die "run as root: sudo ./install.sh"

case "$(dpkg --print-architecture)" in
  amd64) ARCH='x64' ;;
  arm64) ARCH='arm64' ;;
  *) die "unsupported architecture $(dpkg --print-architecture); pick a package manually from the v2rayA releases page" ;;
esac

ASSET="installer_debian_${ARCH}_${VERSION}.deb"
BASE="https://github.com/v2rayA/v2rayA/releases/download/v${VERSION}"
WORKDIR="$(mktemp -d)"
trap 'rm -rf "$WORKDIR"' EXIT

echo "==> dependencies"
apt-get update
apt-get install -y ca-certificates curl jq

echo "==> download $ASSET"
curl --fail --location --proto '=https' --proto-redir '=https' --tlsv1.2 \
  --output "$WORKDIR/$ASSET" "$BASE/$ASSET"
curl --fail --location --proto '=https' --proto-redir '=https' --tlsv1.2 \
  --output "$WORKDIR/$ASSET.sha256.txt" "$BASE/$ASSET.sha256.txt"

# The published .sha256.txt is a bare hash with no filename, which `sha256sum -c`
# refuses to read ("no properly formatted checksum lines found"). Feed it the
# two-column form it expects.
( cd "$WORKDIR" && echo "$(cat "$ASSET.sha256.txt")  $ASSET" | sha256sum -c - )

echo "==> install the package"
# --force-confold keeps our /etc/default/v2raya on re-runs and package upgrades.
apt-get install -y \
  -o Dpkg::Options::=--force-confold \
  -o Dpkg::Options::=--force-confdef \
  "$WORKDIR/$ASSET"

echo "==> bind the admin UI to loopback"
# The package default is 0.0.0.0:2017 and the first visitor to that page gets to
# create the admin account. Safe to write here: the package's postinst does not
# start the service on a fresh install, so it has never listened yet.
cat > /etc/default/v2raya <<'EOF'
# Managed by ai-proxy-bootstrap.
V2RAYA_ADDRESS=127.0.0.1:2017
EOF

systemctl daemon-reload
systemctl enable --now v2raya

install -d -m 0755 "$CONF_DIR"

echo "==> wait for the local API"
curl -s --retry 30 --retry-delay 1 --retry-connrefused --max-time 60 -o /dev/null "$API/version" \
  || die "v2rayA did not come up — check: journalctl -u v2raya -n 50"

if [ "$(curl -sS "$API/version" | jq -r '.data.hasAccounts')" = 'true' ]; then
  echo "    admin account already exists, keeping it"
  [ -r "$CONF_DIR/admin.secret" ] \
    || die "an admin account exists but $CONF_DIR/admin.secret is gone; reset it with: systemctl stop v2raya && v2raya --reset-password"
else
  echo "==> create the admin account"
  # Created straight away so nobody else can claim it. The password is written to
  # a root-only file and never printed.
  umask 077
  head -c 48 /dev/urandom | base64 | tr -dc 'A-Za-z0-9' | cut -c1-24 > "$CONF_DIR/admin.secret"
  chmod 0600 "$CONF_DIR/admin.secret"
  [ "$(wc -c < "$CONF_DIR/admin.secret")" -ge 12 ] || die "could not generate a password"
  resp=$(curl -sS -X POST "$API/account" -H 'Content-Type: application/json' \
    --data "$(jq -nc --arg u admin --rawfile p "$CONF_DIR/admin.secret" \
              '{username:$u, password:($p|rtrimstr("\n"))}')")
  [ "$(jq -r '.code' <<<"$resp")" = 'SUCCESS' ] \
    || die "could not create the admin account: $(jq -r '.message // "unknown"' <<<"$resp")"
fi

if [ ! -f "$CONF_DIR/servers.list" ]; then
  echo "==> create $CONF_DIR/servers.list"
  umask 077
  cat > "$CONF_DIR/servers.list" <<'EOF'
# Your servers. One entry per line, either kind:
#   vless://...    a single server (vmess/trojan/ss/hysteria2/... work too)
#   https://...    a subscription URL, expanded into all of its servers
# Lines starting with # are ignored.
#
# This file stays on this machine. Do not copy it into the git repository.
EOF
  chmod 0600 "$CONF_DIR/servers.list"
fi

echo
exec "$HERE/apply.sh"
