#!/usr/bin/env bash
# Run the local forwarding collector: Zeal (localhost:4318) -> central ingest (token) + logs.
# Needs INGEST_TOKEN in ../.env (or the environment). Downloads otelcol-contrib once into ../.local.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

[ -f .env ] && { set -a; . ./.env; set +a; }
: "${INGEST_TOKEN:?set INGEST_TOKEN (in .env or env)}"
export INGEST_TOKEN
export EQ_METRICS_ENDPOINT="${EQ_METRICS_ENDPOINT:-https://dps.nocturnal-guild.de/otlp/v1/metrics}"

BIN="$ROOT/.local/otelcol-contrib"
if [ ! -x "$BIN" ]; then
  mkdir -p "$ROOT/.local"
  ver=$(curl -s https://api.github.com/repos/open-telemetry/opentelemetry-collector-releases/releases/latest | grep -m1 tag_name | sed -E 's/.*"v?([^"]+)".*/\1/')
  echo "downloading otelcol-contrib v${ver}..."
  curl -fsSL "https://github.com/open-telemetry/opentelemetry-collector-releases/releases/download/v${ver}/otelcol-contrib_${ver}_linux_amd64.tar.gz" | tar xz -C "$ROOT/.local" otelcol-contrib
fi

echo "forwarding metrics -> $EQ_METRICS_ENDPOINT ; receiving Zeal on 127.0.0.1:4318"
exec "$BIN" --config "$ROOT/collector/local.yaml"
