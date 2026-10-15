#!/usr/bin/env bash
# Box metrics and unit limits to Dash0 (2026-10-15). Run from the repo root on your machine:
# copies collector/gateway.yaml and the eq-unit-limits files to the VM, backs the live config
# up, validates the new one as the service user (restoring the backup if it does not), restarts
# eq-gateway only when no raid is open, then installs and starts eq-unit-limits.timer.
set -euo pipefail
K=(-i "$HOME/everquest-observability/.local/deploy_key" -o UserKnownHostsFile="$HOME/everquest-observability/.local/known" -o BatchMode=yes -o ConnectTimeout=10)
HOST=root@2.28.18.70
tar -cf - collector/gateway.yaml deploy/eq-unit-limits.py deploy/eq-unit-limits.service deploy/eq-unit-limits.timer \
  | ssh "${K[@]}" "$HOST" 'rm -rf /root/limits-stage && mkdir -p /root/limits-stage && tar -xf - -C /root/limits-stage'
ssh "${K[@]}" "$HOST" bash -s <<'REMOTE'
set -euo pipefail
S=/root/limits-stage
CONFIG=/etc/eq-otel/gateway.yaml
raids=$(curl -s --get http://127.0.0.1:9090/api/v1/query --data-urlencode 'query=nocturnal_raids_active' | grep -oE '"[0-9]+"\]' | tr -dc 0-9)
[ "${raids:-0}" = 0 ] || { echo "a raid is active ($raids): not restarting the gateway now"; exit 1; }
BAK="$CONFIG.bak.$(date +%F)"
[ -e "$BAK" ] || cp -p "$CONFIG" "$BAK"
install -m 640 -o root -g eqgw "$S/collector/gateway.yaml" "$CONFIG"
if ! sudo -u eqgw /usr/local/bin/eq-gateway validate --config "$CONFIG"; then
  echo "validate failed: restoring $BAK" >&2
  install -m 640 -o root -g eqgw "$BAK" "$CONFIG"
  exit 1
fi
systemctl restart eq-gateway
sleep 5
systemctl is-active eq-gateway
install -m 0755 "$S/deploy/eq-unit-limits.py" /usr/local/bin/eq-unit-limits
install -m 0644 "$S/deploy/eq-unit-limits.service" "$S/deploy/eq-unit-limits.timer" /etc/systemd/system/
systemctl daemon-reload
systemctl enable --now eq-unit-limits.timer
systemctl start eq-unit-limits.service
journalctl -u eq-unit-limits --since -1min -o cat --no-pager | tail -3
rm -rf "$S"
echo "Rollback: systemctl disable --now eq-unit-limits.timer; cp -p $BAK $CONFIG; systemctl restart eq-gateway"
REMOTE
