#!/usr/bin/env bash
# Install the Healthchecks.io heartbeat on the VM. Run as root on the box, with the files
# from deploy/ in the working directory and the check URL either in the environment
# (HC_URL=https://hc-ping.com/<uuid>) or already in /etc/healthchecks/eq-perses.url.
set -euo pipefail
install -d -m 0700 /etc/healthchecks
if [ -n "${HC_URL:-}" ]; then
  printf '%s\n' "$HC_URL" > /etc/healthchecks/eq-perses.url
  chmod 0600 /etc/healthchecks/eq-perses.url
fi
[ -s /etc/healthchecks/eq-perses.url ] || { echo "no check url: set HC_URL"; exit 1; }
install -m 0755 eq-heartbeat.sh /usr/local/bin/eq-heartbeat
install -m 0644 eq-heartbeat.service eq-heartbeat.timer /etc/systemd/system/
systemctl daemon-reload
systemctl enable --now eq-heartbeat.timer
systemctl start eq-heartbeat.service
systemctl list-timers eq-heartbeat.timer --no-pager | head -2
journalctl -u eq-heartbeat --since "-1min" --no-pager -o cat | tail -3
