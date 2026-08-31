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
install -m 0755 "$REPO_DIR/deploy/render-reporters.sh" /usr/local/bin/eq-render-reporters
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


# --- Jaeger (OTLP trace backend for fight/zone spans) ------------------------
JAEGER_VERSION="2.20.0"
if [ ! -x /usr/local/bin/jaeger ]; then
  tmp="$(mktemp -d)"
  curl -fsSL "https://github.com/jaegertracing/jaeger/releases/download/v${JAEGER_VERSION}/jaeger-${JAEGER_VERSION}-linux-amd64.tar.gz" -o "$tmp/j.tgz"
  tar xzf "$tmp/j.tgz" -C "$tmp"
  install -m 0755 "$tmp"/jaeger-*/jaeger /usr/local/bin/jaeger
  rm -rf "$tmp"
fi
id -u jaeger >/dev/null 2>&1 || useradd --system --no-create-home --shell /usr/sbin/nologin jaeger
mkdir -p /etc/jaeger /var/lib/jaeger
cp -f "$REPO_DIR/jaeger/config.yaml" /etc/jaeger/config.yaml
chown root:jaeger /etc/jaeger/config.yaml; chmod 640 /etc/jaeger/config.yaml
chown -R jaeger:jaeger /var/lib/jaeger
cat > /etc/systemd/system/jaeger.service <<'UNIT'
[Unit]
Description=Jaeger (OTLP trace backend)
After=network-online.target
Wants=network-online.target
[Service]
User=jaeger
Group=jaeger
ExecStart=/usr/local/bin/jaeger --config /etc/jaeger/config.yaml
Restart=always
RestartSec=3
NoNewPrivileges=yes
ProtectSystem=strict
ProtectHome=yes
PrivateTmp=yes
ReadWritePaths=/var/lib/jaeger
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
# The login wall. forward_auth written out: ask Perses who the viewer is with
# the viewer's own cookies; on 2xx carry on to the real handler, on anything
# else send the browser through the Discord login and back to the page it
# asked for. Data and chart queries are fetched by the page, so those get 401.
(wall) {
	reverse_proxy 127.0.0.1:8080 {
		method GET
		rewrite /perses/api/v1/user/whoami
		header_up X-Forwarded-Method {method}
		header_up X-Forwarded-Uri {uri}
		@ok status 2xx
		handle_response @ok {
		}
		@nope status 401 403
		handle_response @nope {
			redir * "/perses/api/auth/providers/oauth/discord/login?rd={http.request.orig_uri}" 302
		}
	}
}
(wall_xhr) {
	forward_auth 127.0.0.1:8080 {
		uri /perses/api/v1/user/whoami
	}
}

${PERSES_DOMAIN} {
	encode zstd gzip

	# OTLP ingest -> gateway collector (authenticates, then routes metrics to Prometheus).
	#
	# The bearer token identifies a member, but the collector's auth extension never reveals which
	# token matched - so the lookup happens here, and the answer rides along as a header the client
	# cannot set (handle_path strips anything inbound by matching on our own map only).
	handle_path /otlp/* {
		map {header.Authorization} {eq_reporter} {
			import /etc/caddy/eq-reporters.map
			default ""
		}
		reverse_proxy 127.0.0.1:4319 {
			header_up X-EQ-Reporter {eq_reporter}
		}
	}

	# The guild roster page: the bot writes /var/www/roster/data.json from its
	# ledger; the page is the roster repo's index.html with one constant changed.
	# Perses lives under /perses (api_prefix in perses.yaml). The Discord app
	# still has the old callback URL registered, so that one path is kept
	# reachable and rewritten onto the prefix — no Developer Portal change.
	handle /api/auth/providers/oauth/discord/callback* {
		rewrite * /perses{uri}
		reverse_proxy 127.0.0.1:8080
	}
	handle /perses* {
		reverse_proxy 127.0.0.1:8080
	}

	# Everything else is behind the login (see the wall snippets above).
	handle_path /data/* {
		import wall_xhr
		root * /var/www/roster
		file_server
	}
	handle_path /prom/* {
		import wall_xhr
		reverse_proxy 127.0.0.1:9090
	}
	handle /roster/data.json {
		import wall_xhr
		root * /var/www
		file_server
	}
	handle_path /roster/* {
		import wall
		root * /var/www/roster
		file_server
	}
	redir /site /
	redir /site/* / 301
	handle {
		import wall
		root * /var/www/site
		file_server
	}
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

# --- Reporter map: token -> Discord member, regenerated whenever tokens change ----
touch /etc/caddy/eq-reporters.map
cat > /etc/systemd/system/eq-reporters-reload.service <<'UNIT'
[Unit]
Description=Render the Caddy token->member map and reload Caddy
[Service]
Type=oneshot
ExecStart=/usr/local/bin/eq-render-reporters
UNIT
cat > /etc/systemd/system/eq-reporters-reload.path <<'UNIT'
[Unit]
Description=Watch the ingest token file for membership changes
[Path]
PathModified=/etc/eq-otel/tokens.txt
Unit=eq-reporters-reload.service
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
systemctl enable --now jaeger
systemctl restart jaeger
systemctl enable --now eq-gateway
systemctl restart eq-gateway
systemctl enable --now perses
systemctl restart perses
systemctl enable --now caddy
systemctl enable --now eq-reporters-reload.path
/usr/local/bin/eq-render-reporters || true   # renders the map, then reloads Caddy itself

echo "Deployed. Point ${PERSES_DOMAIN} at this host; Caddy will obtain the TLS cert automatically."
systemctl is-active perses caddy || true
