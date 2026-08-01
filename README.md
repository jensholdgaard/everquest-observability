# EverQuest Observability Platform

The guild-side backend for the EverQuest/Zeal OTLP telemetry: a **Perses** dashboard
gated by **Discord SSO**, plus the collector configs that route Zeal telemetry to a central
OTLP backend. Companion to the [Zeal OTLP exporter](https://github.com/jensholdgaard/NewZeal)
and the [everquest-semconv](https://github.com/jensholdgaard/everquest-semconv) registry.

## Layout

```
perses/perses.yaml     # Perses server config with Discord OAuth SSO (validated on Perses v0.54.0)
perses/provisioning/   # project, datasources, and the stock dashboards (read-only to members)
deploy/                # setup.sh (installs everything), Caddyfile, tokens.sh, harden.sh
collector/             # local + gateway OTLP collector configs
jaeger/                # Jaeger config: OTLP trace backend for fight/zone spans
bot/                   # Discord bot: /dpstoken, /dpsrevoke, role mapping (roles.yaml)
client/windows/        # the member-facing installer + README
.env.example           # secrets template (copy to .env, never commit)
```

## What runs on the box

| Service | Port (localhost) | Role |
|---|---|---|
| Caddy | 80/443 | TLS, routes `/otlp/*` to the gateway and everything else to Perses |
| eq-gateway (otelcol) | 4319 | Authenticates per-member bearer tokens, routes metrics to Prometheus, traces to Jaeger |
| Prometheus | 9090 | Native OTLP receiver (`/api/v1/otlp/v1/metrics`), the metrics store |
| Jaeger | 16686 | Trace backend for fight/zone spans (Badger storage, 72h) |
| Perses | 8080 | Dashboards, Discord SSO |
| dpsbot | — | Discord bot; provisions tokens, roles and personal projects |

Members never reach Prometheus or Jaeger directly: Perses proxies both through project-scoped
datasources, so the browser only ever talks to Perses' own origin.

## Dashboards

**EverQuest DPS** — group DPS/HPS, a DPS meter bar chart, leaderboard, damage mix by type, damage
by target, plus attack/haste. Three selectors: **group** (by leader), **zone**, and **player**.

A group is identified by its leader (`everquest.group.leader`), not by zone — two groups in one
zone used to merge into a single "group DPS" number. The **Who is in the group** row shows group
size, how many members are reporting damage, and the roster, so a low total reads as "3 of 6
reporting" instead of being a mystery. The roster comes from the game's group info, so it includes
members who are not running the client at all.

Note the group selector's "All" is `.*`, not `.+`: in PromQL a regex match against an absent label
tests the empty string, so `.+` would hide all solo and pre-upgrade play.

**EverQuest Fights** — a table of recent fight traces and a Gantt timeline. Click a row to load its
timeline; the Gantt panel renders exactly one trace and is driven by the `fight` variable, because
the plugin rejects search results outright.

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
Perses' OAuth state cookies are `Secure; SameSite=None`, so the login only completes over **HTTPS** —
`run-local.sh` generates a self-signed `localhost` cert for this (accept the browser warning once).
1. In the Discord app, add the redirect `https://localhost:8080/api/auth/providers/oauth/discord/callback`.
2. `cp .env.example .env`, then set `DISCORD_CLIENT_ID` / `DISCORD_CLIENT_SECRET` and `PERSES_ENCRYPTION_KEY` (`openssl rand -hex 16`). The HTTPS localhost defaults are already set.
3. `./deploy/run-local.sh` — downloads Perses once, makes the cert, serves on `:8080` over TLS.
4. Open https://localhost:8080 → accept the cert warning → **Log in with Discord**.

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

## Access model (and a Perses caveat)

Perses **0.54.0 cannot provision an OAuth-only user**: a file with only `oauthProviders` is
rejected (`password cannot be empty`), and adding a `nativeProvider` password makes the two
"mutually exclusive" — which breaks the Discord login sync for that user. So membership is
enforced with **RoleBindings** instead:

- `disable_sign_up: false` — logging in with Discord creates the account, and nothing else.
- No `guest_permissions` — a logged-in stranger sees **no projects and no dashboards**.
- `/dpstoken` (or `deploy/tokens.sh add`) provisions a **RoleBinding** granting a role in the
  shared `everquest` project, mapped from the member's Discord rank (`bot/roles.yaml`):
  officers → `editor`, ranks → `viewer`, no rank → no access. Re-run it after a promotion.

### Personal dashboards

Perses permissions are per *project*, not per dashboard, so each member also gets their own
project `u-<username>` where they are `owner`. They can build and save whatever they like there,
while the shared `everquest` dashboards stay read-only to them. Each personal project carries its
own datasource copy, so no global datasource permissions are needed anywhere.

Anyone who logged in before this was in place needs to run `/dpstoken` once to regain access.

## Privacy

Chat never leaves a player's machine — the local collector's logs pipeline drops it. What is sent
is numeric: damage and heal counters, attack and haste, fight timings, and the player's **group
roster** (character names of everyone in their group, including people not running the client;
see `client/windows/README.md`, which discloses this to members). Members can audit the whole
stream locally before it leaves: the generated `config.yaml` carries an AUDIT MODE comment.

## Notes / roadmap
- **Guild gating:** Discord OAuth logs in *any* Discord user, but logging in grants nothing —
  access comes from a RoleBinding the bot provisions, mapped from the member's Discord rank.
  Tightening this further (`disable_sign_up: true`) is still open.
- **Raids:** a group is identified by its leader, so a raid fragments into one series per group.
  Reading `RaidInfo` for a raid-level identity is not done yet.
- **Automatic revocation:** when someone leaves the Discord, an officer must `/dpsrevoke` them;
  doing it automatically needs the privileged Server Members intent.
- **Incoming damage:** with the default `/otlp scope self`, only damage *you deal* is recorded, so
  "damage taken" panels only fill for players running `scope all`.
- **Stability:** nothing here has outside consumers yet, so metric names and attributes are still
  cheap to change.

## Secrets
Never commit real credentials. `.env`, `*.secret`, and `perses/data/` are git-ignored. The committed
config carries only `REPLACE_*` placeholders.
