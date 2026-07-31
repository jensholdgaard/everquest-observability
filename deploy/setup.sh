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
  curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/gpg.key' | gpg --batch --yes --dearmor -o /usr/share/keyrings/caddy-stable-archive-keyring.gpg
  # debian.deb.txt already contains the [signed-by=...] reference; write it verbatim (no edits).
  curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/debian.deb.txt' > /etc/apt/sources.list.d/caddy-stable.list
  apt-get update -y
  apt-get install -y caddy
fi

# --- Prometheus (OTLP receiver → metrics store queried by Perses) -----------
if [ ! -x /usr/local/bin/prometheus ]; then
  pver=$(curl -s https://api.github.com/repos/prometheus/prometheus/releases/latest | grep -m1 tag_name | sed -E 's/.*"v?([^"]+)".*/\1/')
  tmp="$(mktemp -d)"
  curl -fsSL "https://github.com/prometheus/prometheus/releases/download/v${pver}/prometheus-${pver}.linux-amd64.tar.gz" -o "$tmp/prom.tgz"
  tar xzf "$tmp/prom.tgz" -C "$tmp"
  install -m 0755 "$tmp"/prometheus-*/prometheus /usr/local/bin/prometheus
  rm -rf "$tmp"
fi
mkdir -p /etc/prometheus /var/lib/prometheus
cat > /etc/prometheus/prometheus.yml <<'YML'
global:
  scrape_interval: 30s
# Native OTLP ingestion: metrics POSTed to /api/v1/otlp/v1/metrics. Promote key OTLP resource
# attributes (incl. the character identity) to Prometheus labels so panels can filter by player.
otlp:
  promote_resource_attributes:
    - service.name
    - service.instance.id
    - service.version
  keep_identifying_resource_attributes: true
  # Escape dots to underscores so PromQL names are plain (eq_combat_damage_total), no UTF-8 quoting.
  translation_strategy: UnderscoreEscapingWithSuffixes
storage:
  tsdb:
    out_of_order_time_window: 30m
YML
cat > /etc/systemd/system/prometheus.service <<'UNIT'
[Unit]
Description=Prometheus
After=network-online.target
Wants=network-online.target
[Service]
ExecStart=/usr/local/bin/prometheus --config.file=/etc/prometheus/prometheus.yml --storage.tsdb.path=/var/lib/prometheus --web.listen-address=127.0.0.1:9090 --web.enable-otlp-receiver
Restart=always
RestartSec=3
[Install]
WantedBy=multi-user.target
UNIT

# --- Gateway collector (per-member token auth; routes metrics -> Prometheus) -
OTELCOL_VERSION="0.157.0"  # pinned; the unauthenticated GitHub API "latest" lookup gets rate-limited
if [ ! -x /usr/local/bin/otelcol-contrib ]; then
  tmp="$(mktemp -d)"
  curl -fsSL "https://github.com/open-telemetry/opentelemetry-collector-releases/releases/download/v${OTELCOL_VERSION}/otelcol-contrib_${OTELCOL_VERSION}_linux_amd64.tar.gz" -o "$tmp/oc.tgz"
  tar xzf "$tmp/oc.tgz" -C "$tmp" otelcol-contrib
  install -m 0755 "$tmp/otelcol-contrib" /usr/local/bin/otelcol-contrib
  rm -rf "$tmp"
fi
mkdir -p /etc/eq-otel
cp -f "$REPO_DIR/collector/gateway.yaml" /etc/eq-otel/gateway.yaml
touch /etc/eq-otel/tokens.txt
chmod 600 /etc/eq-otel/tokens.txt
cat > /etc/systemd/system/eq-gateway.service <<'UNIT'
[Unit]
Description=EQ OTel gateway collector
After=network-online.target
Wants=network-online.target
[Service]
ExecStart=/usr/local/bin/otelcol-contrib --config /etc/eq-otel/gateway.yaml
Restart=always
RestartSec=3
[Install]
WantedBy=multi-user.target
UNIT

# --- Render configs ---------------------------------------------------------
mkdir -p /etc/perses
envsubst < "$REPO_DIR/perses/perses.yaml" > /etc/perses/perses.yaml
chmod 600 /etc/perses/perses.yaml

# Perses provisioning (the Prometheus datasource).
mkdir -p /etc/perses/provisioning
 rm -f /etc/perses/provisioning/*.yaml
cp -f "$REPO_DIR"/perses/provisioning/*.yaml /etc/perses/provisioning/

# Caddyfile: Perses dashboard + OTLP ingest. Auth happens at the gateway collector (per-member
# bearer tokens in /etc/eq-otel/tokens.txt), Caddy only terminates TLS and routes.
cat > /etc/caddy/Caddyfile <<CADDY
${PERSES_DOMAIN} {
	encode zstd gzip

	# OTLP ingest -> gateway collector (authenticates, then routes metrics to Prometheus).
	handle_path /otlp/* {
		reverse_proxy 127.0.0.1:4319
	}

	# Perses dashboard.
	reverse_proxy 127.0.0.1:8080
}
CADDY

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
systemctl enable --now prometheus
systemctl restart prometheus
systemctl enable --now eq-gateway
systemctl restart eq-gateway
systemctl enable --now perses
systemctl restart perses
systemctl enable --now caddy
systemctl reload caddy || systemctl restart caddy

echo "Deployed. Point ${PERSES_DOMAIN} at this host; Caddy will obtain the TLS cert automatically."
systemctl is-active perses caddy || true
