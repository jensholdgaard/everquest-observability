#!/usr/bin/env bash
# Manage guild members: ingest token + Perses dashboard access (run locally; talks over SSH).
#   ./deploy/tokens.sh add <member> [discord_username]  -> token + dashboard user; PRINTS token once
#   ./deploy/tokens.sh revoke <member> [discord_username] -> removes both
#   ./deploy/tokens.sh list                              -> members (never prints tokens)
# discord_username defaults to <member>; it must match the Discord username (Perses login subject).
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
IP="${EQ_SERVER_IP:-2.28.18.70}"
SSH=(ssh -i "$ROOT/.local/deploy_key" -o StrictHostKeyChecking=accept-new -o UserKnownHostsFile="$ROOT/.local/known" "root@$IP")

cmd="${1:-}"; member="${2:-}"; discord="${3:-${2:-}}"
case "$cmd" in
  add)
    [ -n "$member" ] || { echo "usage: tokens.sh add <member> [discord_username]"; exit 1; }
    token=$(openssl rand -hex 24)
    "${SSH[@]}" "set -e
      mkdir -p /etc/eq-otel /etc/perses/provisioning
      touch /etc/eq-otel/tokens.txt; chmod 600 /etc/eq-otel/tokens.txt
      if grep -q ' # $member\$' /etc/eq-otel/tokens.txt 2>/dev/null; then echo 'member already has a token (revoke first)'; exit 2; fi
      echo '$token # $member' >> /etc/eq-otel/tokens.txt
      cat > /etc/perses/provisioning/user-$discord.yaml <<USR
apiVersion: perses.dev/v1alpha1
kind: User
metadata:
  name: $discord
spec:
  nativeProvider:
    password: \"\$(openssl rand -hex 16)\"
  oauthProviders:
    - issuer: discord.com
      subject: $discord
USR
      systemctl restart eq-gateway perses"
    echo "Member '$member' added (dashboard login: $discord)."
    echo "Token (share once, not stored locally):"
    echo "  $token"
    ;;
  revoke)
    [ -n "$member" ] || { echo "usage: tokens.sh revoke <member> [discord_username]"; exit 1; }
    "${SSH[@]}" "grep -v ' # $member\$' /etc/eq-otel/tokens.txt > /tmp/tk.\$\$ || true
      cat /tmp/tk.\$\$ > /etc/eq-otel/tokens.txt; rm -f /tmp/tk.\$\$   # in-place: keep inode/ownership for the bot's mount
      rm -f /etc/perses/provisioning/user-$discord.yaml /var/lib/perses/data/users/$discord.json
      systemctl restart eq-gateway perses"
    echo "Revoked $member (dashboard user $discord removed)."
    ;;
  list)
    "${SSH[@]}" "awk '{print \$3}' /etc/eq-otel/tokens.txt 2>/dev/null | sort" || true
    ;;
  *)
    echo "usage: tokens.sh add|revoke|list [member] [discord_username]"; exit 1;;
esac
