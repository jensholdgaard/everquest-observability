# Guild DPS meter — Windows setup (for guild members)

Get your character on the guild's live DPS/heal dashboard at
**https://dps.nocturnal-guild.de** (log in with Discord).

## What you need
- The guild **ingest token** — ask Jens (Discord).
- Your EverQuest folder path (where `eqgame.exe` lives).

## Install (2 minutes)
1. Open **PowerShell** (no admin needed).
2. Run:
   ```powershell
   irm https://raw.githubusercontent.com/jensholdgaard/everquest-observability/main/client/windows/install.ps1 -OutFile install.ps1
   powershell -ExecutionPolicy Bypass -File .\install.ps1
   ```
3. Paste the token when asked, and your EQ folder (it backs up your old `Zeal.asi` automatically).
4. Start EQ, log in, and type: **`/otlp on`** (once — it persists).

That's it. Your DPS and heals now appear on the dashboard, attributed to your character
(pets included). The collector runs hidden in the background and starts with Windows.

## What it does / privacy
- The game only talks to `localhost` — a small [OpenTelemetry Collector](https://opentelemetry.io)
  on **your** machine forwards **metrics** (damage/heal counters, attack/haste) to the guild server,
  authenticated with your token.
- Your combat log **lines are not uploaded** (logs are dropped locally for now).
- Turn it off anytime: `/otlp off` in game, and/or disable the `EQ-OTel-Collector` task in Task
  Scheduler.

## Uninstall
```powershell
Unregister-ScheduledTask -TaskName EQ-OTel-Collector -Confirm:$false
Remove-Item -Recurse -Force "$env:LOCALAPPDATA\eq-otel"
```
Restore your backed-up `Zeal.asi.bak-*` in the EQ folder if you want stock Zeal back.
