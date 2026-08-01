#!/usr/bin/env python3
"""Guild membership bot: /dpstoken provisions a member's ingest token + dashboard access.

Runs on the VM next to the gateway, so it manages /etc/eq-otel/tokens.txt and the Perses
user provisioning directly (same semantics as deploy/tokens.sh). Minimal footprint: no
privileged intents, no guild permissions — it only responds to slash commands.
"""
import os
import pathlib
import re
import secrets

import discord
from discord import app_commands

TOKENS = pathlib.Path("/etc/eq-otel/tokens.txt")
ROLE_MAP = pathlib.Path("/etc/eq-otel/roles.yaml")
PROVISION = pathlib.Path("/etc/perses/provisioning")
DASHBOARD = "https://dps.nocturnal-guild.de"
NAME_RE = re.compile(r"^[a-z0-9._]{2,32}$")  # post-2023 Discord usernames

DM_TEMPLATE = """Your personal DPS meter token (keep it private):
```
{token}
```
**Windows setup — open PowerShell (no admin) and paste this one line:**
```powershell
& ([scriptblock]::Create((irm https://raw.githubusercontent.com/jensholdgaard/everquest-observability/main/client/windows/install.ps1))) -Token {token}
```
It finds your EverQuest folder by itself. Then in game: `/otlp on`
(That line contains your token — don't paste it in a public channel. It also stays in your
PowerShell history; `-Uninstall` on the same script removes everything later.)
Dashboard: {dashboard} (log in with Discord — your access is already set up)\nYou also get a personal project to save your own dashboards in; the guild ones stay read-only.
Lost the token? Ask an officer to `/dpsrevoke` you, then run `/dpstoken` again."""


def role_for(member) -> str | None:
    """Highest Perses role the member's Discord roles grant, or None if they hold no guild rank.
    The mapping lives in roles.yaml and is re-read each time so officers can edit it live."""
    mapping, current = {}, None
    try:
        for line in ROLE_MAP.read_text().splitlines():
            line = line.split("#")[0].rstrip()
            if not line:
                continue
            if not line.startswith(" ") and line.endswith(":"):
                current = line[:-1].strip()
                mapping[current] = []
            elif line.lstrip().startswith("- ") and current:
                mapping[current].append(line.lstrip()[2:].strip())
    except OSError:
        mapping = {"viewer": []}
    held = {r.name for r in getattr(member, "roles", [])}
    for perses_role in ("editor", "viewer"):  # highest first
        if held & set(mapping.get(perses_role, [])):
            return perses_role
    return None


def has_token(user: str) -> bool:
    if not TOKENS.exists():
        return False
    return any(line.strip().endswith(f"# {user}") for line in TOKENS.read_text().splitlines())


def provision(user: str, perses_role: str = "viewer") -> str:
    """Grant a member: append their ingest token and provision the Perses user. The bot runs
    unprivileged; root-owned systemd .path units watch these files and restart the services."""
    token = secrets.token_hex(24)
    with TOKENS.open("a") as f:
        f.write(f"{token} # {user}\n")
    # Grant dashboard access. This Perses version cannot provision an OAuth-only User (it demands a
    # native password, and adding one breaks the Discord login sync), but a RoleBinding provisions
    # fine: logging in creates the account, this gives it the project's viewer role.
    rb = (
        "apiVersion: perses.dev/v1alpha1\n"
        "kind: RoleBinding\n"
        "metadata:\n"
        f"  name: {perses_role}-{user}\n"
        "  project: everquest\n"
        "spec:\n"
        f"  role: {perses_role}\n"
        "  subjects:\n"
        "    - kind: User\n"
        f"      name: {user}\n"
    )
    (PROVISION / f"rb-{user}.yaml").write_text(rb)
    provision_personal_project(user)
    return token


DS_SPEC = """  display:
    name: Prometheus (EverQuest metrics)
  default: true
  plugin:
    kind: PrometheusDatasource
    spec:
      proxy:
        kind: HTTPProxy
        spec:
          url: http://127.0.0.1:9090
          allowedEndpoints:
            - endpointPattern: /api/v1/labels
              method: POST
            - endpointPattern: /api/v1/series
              method: POST
            - endpointPattern: /api/v1/metadata
              method: GET
            - endpointPattern: /api/v1/query
              method: POST
            - endpointPattern: /api/v1/query_range
              method: POST
            - endpointPattern: /api/v1/label/([a-zA-Z0-9_-]+)/values
              method: GET
"""


def provision_personal_project(user: str) -> None:
    """Give the member a project of their own, so they can build and save dashboards without
    being able to modify the shared ones (Perses permissions are per project, not per dashboard)."""
    proj = f"u-{user}"
    (PROVISION / f"50-project-{user}.yaml").write_text(
        "apiVersion: perses.dev/v1alpha1\n"
        "kind: Project\n"
        "metadata:\n"
        f"  name: {proj}\n"
        "spec:\n"
        "  display:\n"
        f"    name: \"{user} (personal)\"\n"
    )
    # Its own datasource copy, so no global datasource permissions are needed anywhere.
    (PROVISION / f"51-ds-{user}.yaml").write_text(
        "apiVersion: perses.dev/v1alpha1\n"
        "kind: Datasource\n"
        "metadata:\n"
        "  name: prometheus\n"
        f"  project: {proj}\n"
        "spec:\n" + DS_SPEC
    )
    (PROVISION / f"52-rb-own-{user}.yaml").write_text(
        "apiVersion: perses.dev/v1alpha1\n"
        "kind: RoleBinding\n"
        "metadata:\n"
        f"  name: owner-{user}\n"
        f"  project: {proj}\n"
        "spec:\n"
        "  role: owner\n"
        "  subjects:\n"
        "    - kind: User\n"
        f"      name: {user}\n"
    )


def provision_role_only(user: str, perses_role: str) -> None:
    """Rewrite just the RoleBinding, e.g. after a Discord rank change."""
    (PROVISION / f"rb-{user}.yaml").write_text(
        "apiVersion: perses.dev/v1alpha1\n"
        "kind: RoleBinding\n"
        "metadata:\n"
        f"  name: {perses_role}-{user}\n"
        "  project: everquest\n"
        "spec:\n"
        f"  role: {perses_role}\n"
        "  subjects:\n"
        "    - kind: User\n"
        f"      name: {user}\n"
    )


def deprovision(user: str) -> None:
    if TOKENS.exists():
        kept = [l for l in TOKENS.read_text().splitlines() if not l.strip().endswith(f"# {user}")]
        TOKENS.write_text("\n".join(kept) + ("\n" if kept else ""))
    (PROVISION / f"rb-{user}.yaml").unlink(missing_ok=True)
    (PROVISION / f"user-{user}.yaml").unlink(missing_ok=True)  # legacy
    for f in (f"50-project-{user}.yaml", f"51-ds-{user}.yaml", f"52-rb-own-{user}.yaml"):
        (PROVISION / f).unlink(missing_ok=True)


class Bot(discord.Client):
    def __init__(self):
        super().__init__(intents=discord.Intents.default())
        self.tree = app_commands.CommandTree(self)

    async def _sync(self, guild):
        self.tree.copy_global_to(guild=guild)
        cmds = await self.tree.sync(guild=guild)
        print(f"synced {[c.name for c in cmds]} to guild '{guild.name}'", flush=True)

    async def on_ready(self):
        print(f"ready as {self.user}; guilds: {[g.name for g in self.guilds]}", flush=True)
        for guild in self.guilds:
            await self._sync(guild)

    async def on_guild_join(self, guild):
        # Invited after startup: register the slash commands immediately.
        print(f"joined guild '{guild.name}'", flush=True)
        await self._sync(guild)


bot = Bot()


@bot.tree.command(name="dpstoken", description="Get your personal token for the guild DPS meter")
async def dpstoken(interaction: discord.Interaction):
    if interaction.guild is None:
        return await interaction.response.send_message("Run this in the guild server.", ephemeral=True)
    user = interaction.user.name
    if not NAME_RE.match(user):
        return await interaction.response.send_message("Sorry, can't handle that username.", ephemeral=True)
    perses_role = role_for(interaction.user)
    if perses_role is None:
        return await interaction.response.send_message(
            "You need a guild rank (Trial/Recruit/Member/Raider or officer) for dashboard access. "
            "Ask an officer if you think this is wrong.", ephemeral=True)
    if has_token(user):
        # Refresh their dashboard role in case their Discord rank changed, then stop.
        provision_role_only(user, perses_role)
        provision_personal_project(user)
        return await interaction.response.send_message(
            f"You already have a token — refreshed your dashboard access to `{perses_role}`. "
            "Lost the token? Ask an officer to `/dpsrevoke` you first.", ephemeral=True)
    token = provision(user, perses_role)
    msg = DM_TEMPLATE.format(token=token, dashboard=DASHBOARD)
    try:
        await interaction.user.send(msg)
        await interaction.response.send_message("Sent — check your DMs. 📨", ephemeral=True)
    except discord.Forbidden:
        # DMs closed: fall back to an ephemeral (only-you-can-see) reply with a spoiler.
        await interaction.response.send_message(
            f"Couldn't DM you (privacy settings). Only you can see this:\n||{token}||\n"
            f"Setup guide: {DASHBOARD} → see #announcements or the repo README.", ephemeral=True)


@bot.tree.command(name="dpsrevoke", description="(officers) Revoke a member's DPS meter token")
@app_commands.describe(member="The member to revoke")
async def dpsrevoke(interaction: discord.Interaction, member: discord.Member):
    if interaction.guild is None:
        return await interaction.response.send_message("Run this in the guild server.", ephemeral=True)
    perms = interaction.user.guild_permissions
    if not (perms.administrator or perms.manage_guild):
        return await interaction.response.send_message("Officers only.", ephemeral=True)
    user = member.name
    if not NAME_RE.match(user):
        return await interaction.response.send_message("Sorry, can't handle that username.", ephemeral=True)
    deprovision(user)
    await interaction.response.send_message(f"Revoked `{user}` (token + dashboard access).", ephemeral=True)


def bot_token() -> str:
    # Preferred: systemd LoadCredentialEncrypted (plaintext only in this unit's private ramfs).
    cred_dir = os.environ.get("CREDENTIALS_DIRECTORY")
    if cred_dir and (pathlib.Path(cred_dir) / "bot_token").exists():
        return (pathlib.Path(cred_dir) / "bot_token").read_text().strip()
    return os.environ["DISCORD_BOT_TOKEN"]  # fallback for local dev


bot.run(bot_token())
