#!/usr/bin/env bash
# Run Perses locally against .env to test the Discord login flow — no Docker, no server, no CI.
# Discord permits http://localhost redirects, so register that redirect in your Discord app for testing.
set -euo pipefail

PERSES_VERSION="0.54.0"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

[ -f .env ] || { echo "Create $ROOT/.env from .env.example first." >&2; exit 1; }
set -a; source .env; set +a
: "${PERSES_EXTERNAL_URL:?}" "${PERSES_COOKIE_SECURE:?}" "${PERSES_ENCRYPTION_KEY:?}" \
  "${DISCORD_CLIENT_ID:?}" "${DISCORD_CLIENT_SECRET:?}"

# Fetch the Perses binary once into .local/ (git-ignored).
BIN="$ROOT/.local/perses"
if [ ! -x "$BIN" ]; then
  mkdir -p "$ROOT/.local"
  echo "Downloading Perses v${PERSES_VERSION}..."
  curl -fsSL "https://github.com/perses/perses/releases/download/v${PERSES_VERSION}/perses_${PERSES_VERSION}_linux_amd64.tar.gz" \
    | tar xz -C "$ROOT/.local"
fi

mkdir -p "$ROOT/.local/data"
envsubst < perses/perses.yaml > "$ROOT/.local/perses.yaml"

echo "Perses starting on ${PERSES_EXTERNAL_URL} — open it and click 'Log in with Discord' (Ctrl-C to stop)."
cd "$ROOT/.local"
exec ./perses --config ./perses.yaml
