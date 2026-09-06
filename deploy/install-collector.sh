#!/usr/bin/env bash
# Put the custom-built gateway collector on the VM, or take it off again.
#
#   install-collector.sh            download the rolling `eq-gateway` release, verify, validate the
#                                   live config with it, install, switch the unit over, check
#   install-collector.sh --rollback  point the unit back at /usr/local/bin/otelcol-contrib
#
# The unit's ExecStart is overridden by a drop-in, so the contrib binary stays installed and a
# rollback is deleting one file and restarting. Run as root on the box.
set -euo pipefail

REPO="jensholdgaard/everquest-observability"
BIN=/usr/local/bin/eq-gateway
DROPIN=/etc/systemd/system/eq-gateway.service.d/binary.conf
CONFIG=/etc/eq-otel/gateway.yaml

check() {
  sleep 5
  systemctl is-active eq-gateway
  local t
  t=$(systemctl show eq-gateway -p ActiveEnterTimestamp --value)
  echo "warn+error lines since start: $(journalctl -u eq-gateway --since "$t" --no-pager -o cat | grep -ciE '"level":"(warn|error)"' || true)"
  # Something must arrive through it: the collector's own uptime series, pushed to Prometheus.
  sleep 40
  curl -s "http://127.0.0.1:9090/api/v1/query" --data-urlencode 'query=time() - max(timestamp(otelcol_process_uptime_seconds_total))' \
    | python3 -c 'import sys,json; r=json.load(sys.stdin)["data"]["result"]; print("seconds since the collector last reported itself:", round(float(r[0]["value"][1])) if r else "none")'
}

if [ "${1:-}" = "--rollback" ]; then
  rm -f "$DROPIN"
  systemctl daemon-reload
  systemctl restart eq-gateway
  echo "unit back on: $(systemctl show eq-gateway -p ExecStart --value | grep -oE 'path=[^ ]+' | head -1)"
  check
  exit 0
fi

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
base="https://github.com/$REPO/releases/download/eq-gateway"
cb="?cb=$(date +%s)" # the CDN serves the previous asset for ~1 min after an upload
curl -fsSL -o "$tmp/eq-gateway.sha256" "$base/eq-gateway.sha256$cb"
curl -fsSL -o "$tmp/build.txt" "$base/build.txt$cb"
curl -fsSL -o "$tmp/eq-gateway" "$base/eq-gateway$cb"
(cd "$tmp" && sha256sum -c eq-gateway.sha256)
chmod 755 "$tmp/eq-gateway"
echo "build $(cat "$tmp/build.txt"): $("$tmp/eq-gateway" --version)"

# The live config, as the service user, before anything is touched.
chown root:eqgw "$tmp/eq-gateway"
sudo -u eqgw "$tmp/eq-gateway" validate --config "$CONFIG"
echo "$CONFIG validates"

install -m 0755 -o root -g root "$tmp/eq-gateway" "$BIN"
mkdir -p "$(dirname "$DROPIN")"
cat > "$DROPIN" <<EOF
# Managed by everquest-observability/deploy/install-collector.sh (build $(cat "$tmp/build.txt")).
# The custom-built collector (collector/builder-config.yaml) instead of otelcol-contrib.
# Rollback: delete this file, daemon-reload, restart - or run the script with --rollback.
[Service]
ExecStart=
ExecStart=$BIN --config $CONFIG
EOF
systemctl daemon-reload
systemctl restart eq-gateway
echo "unit now on: $(systemctl show eq-gateway -p ExecStart --value | grep -oE 'path=[^ ]+' | head -1)"
check
ls -la "$BIN" /usr/local/bin/otelcol-contrib | awk '{printf "%-36s %4.0f MB\n", $9, $5/1048576}'
