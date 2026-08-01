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

The game only talks to `localhost`. A small [OpenTelemetry Collector](https://opentelemetry.io) on
**your** machine forwards numbers to the guild server, authenticated with your token.

**What leaves your PC:**
- Damage and healing counters — who hit what, for how much, by damage type (melee skill, `spell`,
  `dot`, `damage_shield`), and in which zone
- Your attack rating and haste percentage
- Fight timings (when an encounter started and ended, and how)
- **Your group's roster** — the names of everyone in your group, so the dashboard can show who is
  in it rather than only the people running this meter. This means your group-mates' character
  names are sent even if they have never installed anything. Those names are already visible in
  game to everyone in the group, and nothing else about them is sent — no damage, no location, no
  chat — but it is worth knowing that it happens.

**What never leaves your PC:**
- Chat of any kind — tells, guild, officer, group. The collector's logs pipeline drops them locally;
  they are never uploaded. Only numbers and fight timings are sent.

**Verify it yourself.** The generated `config.yaml` has an AUDIT MODE comment: set
`verbosity: detailed` and point the pipelines at the `debug` exporter instead, and the collector
prints locally, in full, everything the game sends it — before any of it goes anywhere.

Turn it off anytime: `/otlp off` in game, and/or disable the `EQ-OTel-Collector` task in Task
Scheduler.

## Meter commands (in game)
| Command | What it does |
|---|---|
| `/otlp on` / `/otlp off` | Start / stop reporting (persists across sessions) |
| `/otlp status` | Endpoint, flush interval, scope, and how many posts have succeeded or failed |
| `/otlp scope self` | Default — report only your own and your pet's damage |
| `/otlp scope all` | Report every attacker you can see, including other players and mobs |

`scope self` is the right setting when the whole guild reports: everyone is the authority on their
own damage, and nothing is double-counted.

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
.\install.ps1 -Token abc -NoAutostart       # no logon task; start run-otelcol.bat yourself
```

`-NoAutostart` exists because a hidden task that runs at logon looks, from the outside, exactly
like malware behaviour. With it you get a `run-otelcol.bat` in `%LOCALAPPDATA%\eq-otel` and the
collector runs only while you have that window open.

If you save the script and run it with `-File`, note that Windows PowerShell 5.1 reads a BOM-less
`.ps1` as Windows-1252 — the script is deliberately pure ASCII so that works. CI enforces it.

## For maintainers
`.github/workflows/client-install.yml` runs this script on a real `windows-latest` runner on every
change: install → verify exe/config/logon task/port → POST a real OTLP payload at it → re-install
(idempotency) → uninstall.
