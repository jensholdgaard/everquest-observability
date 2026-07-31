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

### Test the Discord login locally first (no server, no Docker, no CI)
Discord permits `http://localhost` redirects, so you can trial the whole login on your machine:
1. In the Discord app, add the redirect `http://localhost:8080/api/auth/providers/oauth/discord/callback`.
2. `cp .env.example .env`, then set `DISCORD_CLIENT_ID` / `DISCORD_CLIENT_SECRET` (and `PERSES_ENCRYPTION_KEY` = `openssl rand -hex 16`). Local defaults (`http://localhost:8080`, `secure=false`) are already set.
3. `./deploy/run-local.sh` — downloads Perses once, renders the config, serves on `:8080`.
4. Open http://localhost:8080 → **Log in with Discord**.

### Deploy via GitHub Actions (no local secrets, no token handling)
The `deploy` workflow provisions a Hetzner Cloud VM (if absent) and installs Perses + Caddy over
SSH, rendering the config from secrets at deploy time. Run it from the **Actions** tab
(`workflow_dispatch`).

Add these under **Settings → Secrets and variables → Actions**:

| Kind | Name | Value |
|---|---|---|
| Secret | `HCLOUD_TOKEN` | Hetzner Cloud API token (read-write; dedicated, revocable) |
| Secret | `SSH_PRIVATE_KEY` | Private key CI uses to reach the server (its public half is auto-registered with Hetzner) |
| Secret | `PERSES_ENCRYPTION_KEY` | `openssl rand -hex 16` |
| Secret | `DISCORD_CLIENT_ID` | Discord app client id |
| Secret | `DISCORD_CLIENT_SECRET` | Discord app client secret |
| Variable | `PERSES_DOMAIN` | e.g. `dps.example.com` |

Flow:
1. Add the secrets/variable above; generate an SSH keypair (`ssh-keygen -t ed25519`) and paste the **private** key into `SSH_PRIVATE_KEY`.
2. Run the **deploy** workflow. It prints the server IP.
3. Point `PERSES_DOMAIN`'s A record at that IP (Caddy then obtains the TLS cert automatically).
4. Set the Discord app's redirect to `https://<PERSES_DOMAIN>/api/auth/providers/oauth/discord/callback`.
5. Visit `https://<PERSES_DOMAIN>` → **Log in with Discord**.

Because all code here is public, security rests entirely on the Actions secrets and real auth — never
on the repo being hidden.

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
