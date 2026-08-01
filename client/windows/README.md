# Guild DPS meter — Windows setup (for guild members)

Get your character on the guild's live DPS/heal dashboard at
**https://dps.nocturnal-guild.de** (log in with Discord).

## What you need
Just your **ingest token** — run `/dpstoken` in the guild Discord and the bot DMs you one, along
with the exact command below, token already filled in.

## Install (one line, no admin)
1. Open **PowerShell** (Start → type `powershell`).
2. Paste the line the bot DM'd you. It looks like this:
   ```powershell
   & ([scriptblock]::Create((irm https://raw.githubusercontent.com/jensholdgaard/everquest-observability/main/client/windows/install.ps1))) -Token YOUR-TOKEN
   ```
3. Start EQ, log in, and type: **`/otlp on`** (once — it persists).

The installer finds your EverQuest folder on its own (from the running game, the usual install
locations, or a folder picker), backs up any existing `Zeal.asi`, verifies each download against a
published SHA256, and confirms the collector is really listening before it says "done".

That's it. Your DPS and heals now appear on the dashboard, attributed to your character
(pets included). The collector runs hidden in the background and starts with Windows.

## What it does / privacy
- The game only talks to `localhost` — a small [OpenTelemetry Collector](https://opentelemetry.io)
  on **your** machine forwards **metrics** (damage/heal counters, attack/haste) to the guild server,
  authenticated with your token.
- Your chat and combat log **lines are never uploaded** — the collector drops them on your machine.
  Only numeric metrics (damage/heal counters, attack, haste) and fight timings leave your PC.
- Turn it off anytime: `/otlp off` in game, and/or disable the `EQ-OTel-Collector` task in Task
  Scheduler.

## Uninstall
```powershell
& ([scriptblock]::Create((irm https://raw.githubusercontent.com/jensholdgaard/everquest-observability/main/client/windows/install.ps1))) -Uninstall
```
Removes the collector, its config (token included) and the logon task. Restore your backed-up
`Zeal.asi.bak-*` in the EQ folder if you want stock Zeal back.

## Other options
```powershell
.\install.ps1 -Token abc -EqDir "C:\TAKP"   # skip detection, use this folder
.\install.ps1 -Token abc -NoZeal            # collector only, leave Zeal.asi alone
```

## For maintainers
`.github/workflows/client-install.yml` runs this script on a real `windows-latest` runner on every
change: install → verify exe/config/logon task/port → POST a real OTLP payload at it → re-install
(idempotency) → uninstall.
