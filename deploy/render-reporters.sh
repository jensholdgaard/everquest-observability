#!/usr/bin/env bash
# Renders the bearer-token -> Discord-member map that Caddy uses to stamp X-EQ-Reporter on ingest,
# from the same tokens.txt the gateway authenticates against, then reloads Caddy.
#
# Why this exists: the collector's bearertokenauth extension validates a token and returns the
# context unchanged - it never reveals *which* token matched, so the collector cannot tell one
# member from another. Caddy is the only place in the path that can, so it does the lookup and
# passes the answer along as a header.
#
# Run by eq-reporters-reload.path whenever the bot adds or revokes a token.
set -euo pipefail

TOKENS="${TOKENS:-/etc/eq-otel/tokens.txt}"
OUT="${OUT:-/etc/caddy/eq-reporters.map}"

tmp="$(mktemp)"
trap 'rm -f "$tmp"' EXIT

# tokens.txt lines look like: <token> # <discord-name>
# Emitted lines look like:    "Bearer <token>" "<discord-name>"
while read -r token _hash name; do
  [ -n "${token:-}" ] || continue
  case "$token" in \#*) continue ;; esac      # skip comment-only lines
  name="${name:-unknown}"
  printf '"Bearer %s" "%s"\n' "$token" "$name" >> "$tmp"
done < "$TOKENS"

install -m 0640 -o root -g caddy "$tmp" "$OUT" 2>/dev/null || install -m 0644 "$tmp" "$OUT"

# A config error must not take ingest down: validate before reloading, and leave the running config
# in place if the new map is malformed.
if caddy validate --config /etc/caddy/Caddyfile --adapter caddyfile >/dev/null 2>&1; then
  systemctl reload caddy || systemctl restart caddy
  echo "rendered $(wc -l < "$OUT") reporter mapping(s) and reloaded Caddy"
else
  echo "Caddyfile failed validation with the new map; leaving the previous config running" >&2
  exit 1
fi
