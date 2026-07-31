#!/usr/bin/env bash
# Idempotent server-side setup: install Perses + Caddy, render config from env, (re)start services.
# Run as root on the target host. Secrets come from ./deploy.env (scp'd in, chmod 600, never in git).
set -euo pipefail

PERSES_VERSION="0.54.0"
REPO_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$REPO_DIR"

# Load deploy-time secrets/vars.
set -a
# shellcheck disable=SC1091
source "$REPO_DIR/deploy.env"
set +a
: "${PERSES_DOMAIN:?}" "${PERSES_ENCRYPTION_KEY:?}" "${DISCORD_CLIENT_ID:?}" "${DISCORD_CLIENT_SECRET:?}"

# Prod is always HTTPS behind Caddy; derive the values the config template expects.
export PERSES_EXTERNAL_URL="https://${PERSES_DOMAIN}"
export PERSES_COOKIE_SECURE="true"

export DEBIAN_FRONTEND=noninteractive
apt-get update -y
apt-get install -y curl gettext-base debian-keyring debian-archive-keyring apt-transport-https gnupg ufw

# --- Perses -----------------------------------------------------------------
if [ ! -x /usr/local/bin/perses ] || ! /usr/local/bin/perses --version 2>/dev/null | grep -q "$PERSES_VERSION"; then
  tmp="$(mktemp -d)"
  curl -fsSL "https://github.com/perses/perses/releases/download/v${PERSES_VERSION}/perses_${PERSES_VERSION}_linux_amd64.tar.gz" -o "$tmp/p.tgz"
  tar xzf "$tmp/p.tgz" -C "$tmp"
  install -m 0755 "$tmp/perses" /usr/local/bin/perses
  mkdir -p /var/lib/perses/data
  cp -r "$tmp/plugins-archive" /var/lib/perses/ 2>/dev/null || true
  rm -rf "$tmp"
fi

# --- Caddy (official apt repo, provides automatic HTTPS) --------------------
if ! command -v caddy >/dev/null 2>&1; then
  curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/gpg.key' | gpg --dearmor -o /usr/share/keyrings/caddy-stable-archive-keyring.gpg
  curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/debian.deb.txt' \
    | sed 's|https://dl.cloudsmith.io|[signed-by=/usr/share/keyrings/caddy-stable-archive-keyring.gpg] https://dl.cloudsmith.io|' \
    > /etc/apt/sources.list.d/caddy-stable.list
  apt-get update -y
  apt-get install -y caddy
fi

# --- Render configs ---------------------------------------------------------
mkdir -p /etc/perses
envsubst < "$REPO_DIR/perses/perses.yaml" > /etc/perses/perses.yaml
chmod 600 /etc/perses/perses.yaml

# Caddyfile: literal domain (no reliance on Caddy env at runtime).
printf '%s {\n\tencode zstd gzip\n\treverse_proxy 127.0.0.1:8080\n}\n' "$PERSES_DOMAIN" > /etc/caddy/Caddyfile

# --- Perses systemd unit ----------------------------------------------------
cat > /etc/systemd/system/perses.service <<'UNIT'
[Unit]
Description=Perses
After=network-online.target
Wants=network-online.target
[Service]
WorkingDirectory=/var/lib/perses
ExecStart=/usr/local/bin/perses --config /etc/perses/perses.yaml
Restart=always
RestartSec=3
[Install]
WantedBy=multi-user.target
UNIT

# --- Firewall ---------------------------------------------------------------
ufw allow OpenSSH >/dev/null 2>&1 || true
ufw allow 80/tcp  >/dev/null 2>&1 || true
ufw allow 443/tcp >/dev/null 2>&1 || true
yes | ufw enable   >/dev/null 2>&1 || true

# --- Start / restart --------------------------------------------------------
systemctl daemon-reload
systemctl enable --now perses
systemctl restart perses
systemctl enable --now caddy
systemctl reload caddy || systemctl restart caddy

echo "Deployed. Point ${PERSES_DOMAIN} at this host; Caddy will obtain the TLS cert automatically."
systemctl is-active perses caddy || true
