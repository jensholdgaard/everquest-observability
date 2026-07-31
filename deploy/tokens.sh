#!/usr/bin/env bash
# Manage per-member ingest tokens on the gateway (run locally; talks to the server over SSH).
#   ./deploy/tokens.sh add <member>      -> generates a token, installs it, PRINTS it once
#   ./deploy/tokens.sh revoke <member>   -> removes that member's token
#   ./deploy/tokens.sh list              -> members (never prints tokens)
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
IP="${EQ_SERVER_IP:-2.28.18.70}"
SSH=(ssh -i "$ROOT/.local/deploy_key" -o StrictHostKeyChecking=accept-new -o UserKnownHostsFile="$ROOT/.local/known" "root@$IP")

cmd="${1:-}"; member="${2:-}"
case "$cmd" in
  add)
    [ -n "$member" ] || { echo "usage: tokens.sh add <member>"; exit 1; }
    token=$(openssl rand -hex 24)
    "${SSH[@]}" "mkdir -p /etc/eq-otel; touch /etc/eq-otel/tokens.txt; chmod 600 /etc/eq-otel/tokens.txt
      if grep -q ' # $member\$' /etc/eq-otel/tokens.txt 2>/dev/null; then echo 'member already has a token (revoke first)'; exit 2; fi
      echo '$token # $member' >> /etc/eq-otel/tokens.txt
      systemctl restart eq-gateway"
    echo "Token for $member (share this once, it is not stored locally):"
    echo "  $token"
    ;;
  revoke)
    [ -n "$member" ] || { echo "usage: tokens.sh revoke <member>"; exit 1; }
    "${SSH[@]}" "sed -i '/ # $member\$/d' /etc/eq-otel/tokens.txt && systemctl restart eq-gateway"
    echo "Revoked $member."
    ;;
  list)
    "${SSH[@]}" "awk '{print \$3}' /etc/eq-otel/tokens.txt 2>/dev/null | sort" || true
    ;;
  *)
    echo "usage: tokens.sh add|revoke|list [member]"; exit 1;;
esac
