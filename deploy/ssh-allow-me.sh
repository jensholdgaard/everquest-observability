#!/usr/bin/env bash
# Hetzner Cloud Firewall for eq-perses: 80/443/ping from anywhere, SSH (22) only from the
# address this script runs on. Packets from everyone else are dropped at Hetzner's edge and
# never reach the VM — no sshd log line, no fail2ban work. Run it again whenever your home
# IP changes (before you try to ssh): it creates the firewall on first run and only rewrites
# the SSH source afterwards. Locked out anyway? The Hetzner console (VNC) still works.
#
#   HCLOUD_TOKEN=... deploy/ssh-allow-me.sh          # or put the token in the repo's .env
set -euo pipefail
here=$(cd "$(dirname "$0")/.." && pwd)
if [ -z "${HCLOUD_TOKEN:-}" ] && [ -f "$here/.env" ]; then
  HCLOUD_TOKEN=$(sed -n 's/^HCLOUD_TOKEN=//p' "$here/.env" | tr -d '"' | tr -d "'")
fi
[ -n "${HCLOUD_TOKEN:-}" ] || { echo "HCLOUD_TOKEN not set" >&2; exit 1; }
SERVER_ID=${SERVER_ID:-157630702}
NAME=${FIREWALL_NAME:-eq-perses}
me=$(curl -4 -fsS https://api.ipify.org)
echo "this machine: $me"

api() { curl -fsS -X "$1" "https://api.hetzner.cloud/v1$2" \
          -H "Authorization: Bearer $HCLOUD_TOKEN" -H "Content-Type: application/json" \
          ${3:+-d "$3"}; }

rules=$(cat <<JSON
[
  {"direction":"in","protocol":"tcp","port":"22","source_ips":["$me/32"],
   "description":"ssh from the operator only — deploy/ssh-allow-me.sh rewrites this"},
  {"direction":"in","protocol":"tcp","port":"80","source_ips":["0.0.0.0/0","::/0"],
   "description":"caddy http (redirect + acme)"},
  {"direction":"in","protocol":"tcp","port":"443","source_ips":["0.0.0.0/0","::/0"],
   "description":"caddy https: site, perses, otlp"},
  {"direction":"in","protocol":"icmp","source_ips":["0.0.0.0/0","::/0"],"description":"ping"}
]
JSON
)

fid=$(api GET "/firewalls?name=$NAME" | python3 -c 'import sys,json; f=json.load(sys.stdin)["firewalls"]; print(f[0]["id"] if f else "")')
if [ -z "$fid" ]; then
  api POST /firewalls "{\"name\":\"$NAME\",\"rules\":$rules,\"apply_to\":[{\"type\":\"server\",\"server\":{\"id\":$SERVER_ID}}]}" >/dev/null
  echo "created firewall '$NAME' and applied it to server $SERVER_ID"
else
  api POST "/firewalls/$fid/actions/set_rules" "{\"rules\":$rules}" >/dev/null
  echo "firewall '$NAME' ($fid): ssh now allowed from $me only"
fi
