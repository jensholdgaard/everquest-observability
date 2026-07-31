# EverQuest Observability Platform

The guild-side backend for the EverQuest/Zeal OTLP telemetry: a **Perses** dashboard
gated by **Discord SSO**, plus the collector configs that route Zeal telemetry to a central
OTLP backend. Companion to the [Zeal OTLP exporter](https://github.com/jensholdgaard/NewZeal)
and the [everquest-semconv](https://github.com/jensholdgaard/everquest-semconv) registry.

## Layout

```
perses/perses.yaml     # Perses server config with Discord OAuth SSO (validated on Perses v0.54.0)
deploy/Caddyfile       # Caddy reverse proxy w/ automatic HTTPS in front of Perses
collector/             # local + gateway OTLP collector configs (transport-layer auth — later phase)
.env.example           # secrets template (copy to .env, never commit)
```

## Current focus: Perses + Discord login

Perses has a generic OAuth provider, and Discord is OAuth2, so **Perses authenticates against
Discord directly — no proxy or broker.**

### Prerequisites (you provide)
1. **Discord application** — [Developer Portal](https://discord.com/developers/applications) → New Application → OAuth2.
   Copy the **Client ID** and **Client Secret**, and add this **Redirect URL**:
   `https://<your-domain>/api/auth/providers/oauth/discord/callback`
2. **Domain** — an A record pointing at the server's public IP (Discord requires HTTPS for
   non-`localhost` redirects; Caddy issues the certificate automatically).
3. **Server** — e.g. a small Hetzner Cloud VM.

### Deploy (outline)
1. `cp .env.example .env` and fill in `PERSES_DOMAIN`, `PERSES_ENCRYPTION_KEY`
   (`openssl rand -hex 16`), `DISCORD_CLIENT_ID`, `DISCORD_CLIENT_SECRET`.
2. Render `perses/perses.yaml` with those values (the `REPLACE_*` placeholders).
3. Run Perses (`:8080`) behind Caddy (`PERSES_DOMAIN` → auto-TLS → `127.0.0.1:8080`).
4. Visit `https://<your-domain>` → **Log in with Discord**.

## Notes / roadmap
- **Guild gating:** Discord OAuth logs in *any* Discord user. Restricting to guild members is a
  follow-up (`disable_sign_up: true` + provisioning members, or a guild-membership check layer).
- **Transport auth / anti-spam:** the `collector/` configs (per-member bearer tokens at the gateway,
  `memory_limiter`, reverse-proxy rate limiting) are the next phase once the dashboard is up.
- **Data source:** Perses needs a metrics source (the central OTLP backend, e.g. Ourios, exposing a
  Perses-compatible datasource) to render the DPS panels.

## Secrets
Never commit real credentials. `.env`, `*.secret`, and `perses/data/` are git-ignored. The committed
config carries only `REPLACE_*` placeholders.
