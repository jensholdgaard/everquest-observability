#!/usr/bin/env bash
# Install (or update) Alertmanager and the alerting rules on the VM. Run as root on the box
# with deploy/alerting/* and, optionally, nocturnal-rules.yml (from nocturnal-discord) in the
# working directory. Webhook URLs: BOT_DISCORD_WEBHOOK_URL / VM_DISCORD_WEBHOOK_URL in the
# environment on the first run (they are written to root-only files and never asked again),
# or the files already in place.
set -euo pipefail

AM_VERSION="0.34.0"  # pinned like the collector; bump deliberately

id -u alertmanager >/dev/null 2>&1 || useradd --system --no-create-home --shell /usr/sbin/nologin alertmanager
install -d -m 0750 -o root -g alertmanager /etc/alertmanager
install -d -m 0750 -o alertmanager -g alertmanager /var/lib/alertmanager
install -d -m 0755 /etc/prometheus/rules

for pair in "BOT_DISCORD_WEBHOOK_URL:bot" "VM_DISCORD_WEBHOOK_URL:vm"; do
  var=${pair%%:*}; name=${pair##*:}
  if [ -n "${!var:-}" ]; then
    (umask 027; printf '%s\n' "${!var}" > "/etc/alertmanager/$name.webhook")
    chown root:alertmanager "/etc/alertmanager/$name.webhook"
  fi
  [ -s "/etc/alertmanager/$name.webhook" ] || { echo "missing /etc/alertmanager/$name.webhook: set $var"; exit 1; }
done

if [ ! -x /usr/local/bin/alertmanager ] || ! /usr/local/bin/alertmanager --version 2>&1 | grep -q "version $AM_VERSION"; then
  tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
  curl -fsSL "https://github.com/prometheus/alertmanager/releases/download/v${AM_VERSION}/alertmanager-${AM_VERSION}.linux-amd64.tar.gz" -o "$tmp/am.tgz"
  curl -fsSL "https://github.com/prometheus/alertmanager/releases/download/v${AM_VERSION}/sha256sums.txt" -o "$tmp/sums"
  (cd "$tmp" && grep "alertmanager-${AM_VERSION}.linux-amd64.tar.gz" sums | sed 's#  .*#  am.tgz#' | sha256sum -c)
  tar xzf "$tmp/am.tgz" -C "$tmp"
  install -m 0755 "$tmp"/alertmanager-*/alertmanager /usr/local/bin/alertmanager
  install -m 0755 "$tmp"/alertmanager-*/amtool /usr/local/bin/amtool
fi

install -m 0640 -o root -g alertmanager alertmanager.yml /etc/alertmanager/alertmanager.yml
/usr/local/bin/amtool check-config /etc/alertmanager/alertmanager.yml

# --log.level=debug (2026-09-12): a *successful* send is logged only at debug, so
# "which alert went to which channel, and when" was unanswerable after the fact -
# the only trace was a counter going up, and its labels name the integration, not
# the receiver. At this size that costs nothing: the steady state is a handful of
# lines a day, and the journald receiver ships them to Ourios, so the history is a
# log query. The two lines that matter are `msg="Received alert"` and
# `msg=flushing ... aggrGroup=` - the latter names the route that matched.
cat > /etc/systemd/system/alertmanager.service <<'UNIT'
[Unit]
Description=Alertmanager (Prometheus alerts -> Discord)
After=network-online.target
Wants=network-online.target
[Service]
User=alertmanager
Group=alertmanager
ExecStart=/usr/local/bin/alertmanager --config.file=/etc/alertmanager/alertmanager.yml --storage.path=/var/lib/alertmanager --web.listen-address=127.0.0.1:9093 --web.external-url=http://127.0.0.1:9093 --cluster.listen-address="" --log.level=debug
Restart=always
RestartSec=3
NoNewPrivileges=true
ProtectSystem=strict
ProtectHome=true
ReadWritePaths=/var/lib/alertmanager
PrivateTmp=true
[Install]
WantedBy=multi-user.target
UNIT
systemctl daemon-reload
systemctl enable --now alertmanager
systemctl restart alertmanager

# Rules: the VM's from here, the bot's from nocturnal-discord when present.
install -m 0644 rules-vm.yml /etc/prometheus/rules/vm.yml
[ -f nocturnal-rules.yml ] && install -m 0644 nocturnal-rules.yml /etc/prometheus/rules/nocturnal.yml

# Prometheus: point at Alertmanager and load the rules directory (idempotent), then reload.
if ! grep -q "^alerting:" /etc/prometheus/prometheus.yml; then
  cat >> /etc/prometheus/prometheus.yml <<'YML'
# Alerting (2026-09-06): rules in /etc/prometheus/rules, Alertmanager on the box -> Discord.
alerting:
  alertmanagers:
    - static_configs:
        - targets: ['127.0.0.1:9093']
rule_files:
  - /etc/prometheus/rules/*.yml
YML
fi
systemctl kill -s HUP prometheus
sleep 3
systemctl is-active alertmanager prometheus
curl -s http://127.0.0.1:9090/api/v1/rules | python3 -c '
import sys, json
gs = json.load(sys.stdin)["data"]["groups"]
for g in gs: print(g["name"], len(g["rules"]), "rules,", [r["name"] for r in g["rules"] if r.get("health") != "ok"] or "all healthy")'
curl -s http://127.0.0.1:9090/api/v1/alertmanagers | python3 -c 'import sys,json; print("alertmanagers:", json.load(sys.stdin)["data"]["activeAlertmanagers"])'
