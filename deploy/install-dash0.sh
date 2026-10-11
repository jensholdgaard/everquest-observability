#!/usr/bin/env bash
# Run on YOUR machine, from the everquest-observability checkout:
#   deploy/install-dash0.sh
# Sends Ourios's own telemetry to Dash0 (2026-10-11). Reads DASH0_TOKEN from
# ~/nocturnal-discord/.env and pipes it over ssh into `systemd-creds encrypt` on the VM: the token
# is never printed, never an argument (ps), never written in plaintext on either side. Then ships
# the gateway config + the credential drop-in, validates, and restarts eq-gateway. Re-run it to
# rotate the token. On a failed validation nothing is restarted and the old config is put back.
set -euo pipefail
cd "$(dirname "$0")/.."
ENV_FILE=${ENV_FILE:-$HOME/nocturnal-discord/.env}
VM=root@2.28.18.70
SSH=(ssh -i .local/deploy_key -o UserKnownHostsFile=.local/known -o BatchMode=yes "$VM")

token=$(grep -m1 '^DASH0_TOKEN=' "$ENV_FILE" | cut -d= -f2- | tr -d '"'"'"'\r\n') || true
[ -n "$token" ] || { echo "DASH0_TOKEN not found in $ENV_FILE" >&2; exit 1; }

# One connection for the token, one for the files, one for the switch (ufw allows 6 per 30 s).
printf '%s' "$token" | "${SSH[@]}" 'umask 077 && systemd-creds encrypt --name=dash0_token - /etc/eq-otel/dash0_token.cred.new && mv -f /etc/eq-otel/dash0_token.cred.new /etc/eq-otel/dash0_token.cred'
unset token
tar -cf - collector/gateway.yaml deploy/eq-gateway-dash0.conf | "${SSH[@]}" 'mkdir -p /root/dash0-stage && tar -xf - -C /root/dash0-stage'
"${SSH[@]}" 'bash -s' <<'REMOTE'
set -euo pipefail
S=/root/dash0-stage
cp -p /etc/eq-otel/gateway.yaml /etc/eq-otel/gateway.yaml.pre-dash0
install -m 640 -o root -g eqgw "$S/collector/gateway.yaml" /etc/eq-otel/gateway.yaml
install -m 644 "$S/deploy/eq-gateway-dash0.conf" /etc/systemd/system/eq-gateway.service.d/dash0.conf
BIN=$(systemctl show eq-gateway -p ExecStart --value | grep -oE 'path=[^ ]+' | head -1 | cut -d= -f2)
# validate parses and builds every component; the credential path only exists inside the unit,
# so this checks the config shape, and the restart below checks the token is readable.
if ! "$BIN" validate --config /etc/eq-otel/gateway.yaml; then
  echo "validate failed: restoring the previous config" >&2
  install -m 640 -o root -g eqgw /etc/eq-otel/gateway.yaml.pre-dash0 /etc/eq-otel/gateway.yaml
  rm -f /etc/systemd/system/eq-gateway.service.d/dash0.conf
  exit 1
fi
systemctl daemon-reload
systemctl restart eq-gateway
sleep 20
systemctl is-active eq-gateway
journalctl -u eq-gateway --since -25s -o cat | grep -iE 'error|dash0' | grep -v 'journalctl command exited' | head -20 || true
echo "dash0 exporter sent: $(curl -s --get http://127.0.0.1:9090/api/v1/query --data-urlencode 'query=sum by (exporter)(otelcol_exporter_sent_spans_total{exporter="otlp_http/dash0"} or otelcol_exporter_sent_metric_points_total{exporter="otlp_http/dash0"})' | head -c 400)"
rm -rf "$S"
REMOTE
echo "Done. Rollback: on the VM, cp /etc/eq-otel/gateway.yaml.pre-dash0 /etc/eq-otel/gateway.yaml; rm /etc/systemd/system/eq-gateway.service.d/dash0.conf; systemctl daemon-reload; systemctl restart eq-gateway"
