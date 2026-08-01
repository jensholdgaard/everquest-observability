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
PROVISION = pathlib.Path("/etc/perses/provisioning")
DASHBOARD = "https://dps.nocturnal-guild.de"
NAME_RE = re.compile(r"^[a-z0-9._]{2,32}$")  # post-2023 Discord usernames

DM_TEMPLATE = """Your personal DPS meter token (keep it private):
```
{token}
```
**Windows setup (2 min):**
```powershell
irm https://raw.githubusercontent.com/jensholdgaard/everquest-observability/main/client/windows/install.ps1 -OutFile install.ps1
powershell -ExecutionPolicy Bypass -File .\\install.ps1
```
Paste the token when asked, then in game: `/otlp on`
Dashboard: {dashboard} (log in with Discord — your access is already set up)
Lost the token? Ask an officer to `/dpsrevoke` you, then run `/dpstoken` again."""


def has_token(user: str) -> bool:
    if not TOKENS.exists():
        return False
    return any(line.strip().endswith(f"# {user}") for line in TOKENS.read_text().splitlines())


def provision(user: str) -> str:
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
        f"  name: viewer-{user}\n"
        "  project: everquest\n"
        "spec:\n"
        "  role: viewer\n"
        "  subjects:\n"
        "    - kind: User\n"
        f"      name: {user}\n"
    )
    (PROVISION / f"rb-{user}.yaml").write_text(rb)
    return token


def deprovision(user: str) -> None:
    if TOKENS.exists():
        kept = [l for l in TOKENS.read_text().splitlines() if not l.strip().endswith(f"# {user}")]
        TOKENS.write_text("\n".join(kept) + ("\n" if kept else ""))
    (PROVISION / f"rb-{user}.yaml").unlink(missing_ok=True)
    (PROVISION / f"user-{user}.yaml").unlink(missing_ok=True)  # legacy


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
    if has_token(user):
        return await interaction.response.send_message(
            "You already have a token. Lost it? Ask an officer to `/dpsrevoke` you first.", ephemeral=True)
    token = provision(user)
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
