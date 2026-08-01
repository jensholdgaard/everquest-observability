# EverQuest guild telemetry — Windows client installer.
# Installs the local OTel collector (forwards Zeal's metrics to the guild server with your token),
# registers it to start at logon, and (optionally) installs the custom Zeal.asi into your EQ folder.
#
# Usage (PowerShell, no admin needed):
#   # one-liner from the Discord DM — nothing saved to disk, no execution-policy flag:
#   & ([scriptblock]::Create((irm <raw-url>))) -Token abc123
#
#   .\install.ps1                              # interactive: prompts for the token, finds EQ itself
#   .\install.ps1 -Token abc -EqDir "C:\TAKP"  # non-interactive
#   .\install.ps1 -Token abc -NoZeal           # collector only, leave Zeal.asi alone
#   .\install.ps1 -Uninstall                   # remove the collector, task and config
param(
  [string]$Token,
  [string]$EqDir,
  [switch]$NoZeal,
  [switch]$NoAutostart,
  [switch]$Uninstall,
  [string]$Endpoint = "https://dps.nocturnal-guild.de/otlp/v1/metrics",
  [string]$TracesEndpoint = "https://dps.nocturnal-guild.de/otlp/v1/traces",
  [string]$ZealUrl = "https://github.com/jensholdgaard/NewZeal/releases/download/otlp-preview/Zeal.asi"
)
$ErrorActionPreference = "Stop"
# Windows PowerShell 5.1 renders a progress bar per chunk for Invoke-WebRequest, which dominates the
# runtime of the ~250 MB collector download. (Zigzap.)
$ProgressPreference = "SilentlyContinue"
$Ver = "0.157.0"
$Dir = Join-Path $env:LOCALAPPDATA "eq-otel"
$Exe = Join-Path $Dir "otelcol-contrib.exe"
$Cfg = Join-Path $Dir "config.yaml"
$TaskName = "EQ-OTel-Collector"

function Stop-Collector {
  Stop-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
  Get-Process otelcol-contrib -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
  Start-Sleep -Milliseconds 500  # let the exe release its file lock before anything overwrites it
}

# Locate EverQuest without making the member type a path: the running game knows where it lives,
# and failing that the usual install spots, then a shallow scan, then a folder picker.
function Find-EqDir {
  $proc = Get-Process eqgame -ErrorAction SilentlyContinue | Where-Object { $_.Path } | Select-Object -First 1
  if ($proc) { return (Split-Path $proc.Path) }

  $names = @('EverQuest', 'Project Quarm', 'ProjectQuarm', 'Quarm', 'TAKP', 'EQ')
  $roots = @("$env:SystemDrive\", $env:ProgramFiles, ${env:ProgramFiles(x86)},
             "$env:USERPROFILE\Desktop", "$env:USERPROFILE\Games", "$env:USERPROFILE\Documents",
             $env:LOCALAPPDATA) | Where-Object { $_ }
  foreach ($r in $roots) {
    foreach ($n in $names) {
      $c = Join-Path $r $n
      if (Test-Path (Join-Path $c 'eqgame.exe')) { return $c }
    }
  }

  Write-Host "Looking for eqgame.exe..." -ForegroundColor DarkGray
  foreach ($d in (Get-PSDrive -PSProvider FileSystem | Where-Object { $null -ne $_.Used })) {
    $hit = Get-ChildItem -Path $d.Root -Filter eqgame.exe -File -Recurse -Depth 3 `
             -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($hit) { return $hit.DirectoryName }
  }
  return $null
}

function Select-EqDirDialog {
  try {
    Add-Type -AssemblyName System.Windows.Forms
    $dlg = New-Object System.Windows.Forms.FolderBrowserDialog
    $dlg.Description = "Select your EverQuest folder (the one containing eqgame.exe)"
    if ($dlg.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) { return $dlg.SelectedPath }
  } catch {
    # No desktop session (CI, remote shell): fall through to the typed prompt.
  }
  return $null
}

function Wait-ForPort {
  param([int]$Port = 4318, [int]$TimeoutSec = 25)
  $deadline = (Get-Date).AddSeconds($TimeoutSec)
  while ((Get-Date) -lt $deadline) {
    try {
      $c = New-Object System.Net.Sockets.TcpClient
      $c.Connect('127.0.0.1', $Port)
      $c.Close()
      return $true
    } catch { Start-Sleep -Milliseconds 500 }
  }
  return $false
}

# --- 0. Uninstall -----------------------------------------------------------
if ($Uninstall) {
  Stop-Collector
  Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false -ErrorAction SilentlyContinue
  if (Test-Path $Dir) { Remove-Item -Recurse -Force $Dir }
  Write-Host "Removed the collector, its config (token included) and the logon task." -ForegroundColor Green
  Write-Host "Zeal.asi was left alone — restore a Zeal.asi.bak-* in your EQ folder for stock Zeal."
  return
}

Write-Host "== EverQuest guild telemetry installer ==" -ForegroundColor Cyan

if (-not $Token) { $Token = Read-Host "Paste your guild ingest token" }
if (-not $Token) { throw "A token is required — run /dpstoken in the guild Discord to get one." }

New-Item -ItemType Directory -Force -Path $Dir | Out-Null

# --- 1. Local OTel collector ------------------------------------------------
if (-not (Test-Path $Exe)) {
  $base = "https://github.com/open-telemetry/opentelemetry-collector-releases/releases/download/v$Ver"
  $tgzName = "otelcol-contrib_${Ver}_windows_amd64.tar.gz"
  $tgz = Join-Path $Dir $tgzName

  # Verify against the checksum file OpenTelemetry publishes for the release: catches a corrupted
  # or truncated download, and means a swapped binary would have to match a hash published by the
  # upstream project rather than just sit at the download URL.
  # Downloaded to a file rather than read from .Content: GitHub serves release assets as
  # application/octet-stream, and PowerShell 7 hands those back as a byte[], not a string.
  Write-Host "Downloading OpenTelemetry Collector v$Ver..."
  $sumsFile = Join-Path $Dir "checksums.txt"
  Invoke-WebRequest -UseBasicParsing -OutFile $sumsFile `
      -Uri "$base/opentelemetry-collector-releases_otelcol-contrib_windows_checksums.txt"
  $line = Get-Content $sumsFile | Where-Object { $_ -match ([regex]::Escape($tgzName) + '\s*$') } | Select-Object -First 1
  Remove-Item $sumsFile -Force
  if (-not $line) { throw "No published checksum for $tgzName — refusing to install." }
  $expected = (($line -split '\s+') | Select-Object -First 1).ToUpper()

  Invoke-WebRequest -UseBasicParsing -Uri "$base/$tgzName" -OutFile $tgz
  $actual = (Get-FileHash $tgz -Algorithm SHA256).Hash
  if ($actual -ne $expected) {
    Remove-Item $tgz -Force
    throw "SHA256 mismatch on the collector download (expected $expected, got $actual). Aborted."
  }
  tar -xzf $tgz -C $Dir otelcol-contrib.exe
  Remove-Item $tgz
  Write-Host "Collector verified and unpacked." -ForegroundColor Green
}

# --- 2. Config (token embedded; file lives in your user profile) -------------
Stop-Collector
$yaml = @"
extensions:
  bearertokenauth:
    token: "$Token"
receivers:
  otlp:
    protocols:
      http:
        endpoint: 127.0.0.1:4318
processors:
  batch:
    timeout: 5s
  memory_limiter:
    check_interval: 1s
    limit_mib: 128
exporters:
  otlphttp/metrics:
    metrics_endpoint: $Endpoint
    traces_endpoint: $TracesEndpoint
    auth:
      authenticator: bearertokenauth
  # 'basic' prints one line per batch; switch to 'detailed' to dump full attribute contents when
  # auditing what Zeal actually emits. (Zigzap.)
  debug:
    verbosity: basic
service:
  extensions: [bearertokenauth]
  pipelines:
    # AUDIT MODE: to see everything locally before any of it leaves your machine, set
    # verbosity: detailed above and replace [otlphttp/metrics] with [debug] in the two pipelines
    # below, then run the collector and watch the console.
    metrics:
      receivers: [otlp]
      processors: [memory_limiter, batch]
      exporters: [otlphttp/metrics]
    traces:
      receivers: [otlp]
      processors: [memory_limiter, batch]
      exporters: [otlphttp/metrics]
    # Chat lines stay on your machine: the logs pipeline drops them (never uploaded).
    logs:
      receivers: [otlp]
      processors: [memory_limiter, batch]
      exporters: [debug]
"@
# Written as UTF-8 *without* a BOM: `Set-Content -Encoding UTF8` emits a BOM under Windows
# PowerShell 5.1 — which is what members actually have — and Go's YAML parser chokes on it. PS 7
# writes no BOM, so this never reproduced for us or in CI until CI grew a 5.1 job. (Zigzap.)
[System.IO.File]::WriteAllText($Cfg, $yaml, (New-Object System.Text.UTF8Encoding($false)))

# Catch a broken config here, with the collector's own error message, rather than leaving behind a
# scheduled task that silently fails to start.
$validation = & $Exe validate --config $Cfg 2>&1
if ($LASTEXITCODE -ne 0) { throw "The collector rejected the config:`n$validation" }

# --- 3. Start it ------------------------------------------------------------
# A hidden task that runs at logon is indistinguishable, from the outside, from what malware does —
# a reasonable thing to refuse on someone else's machine. -NoAutostart writes a launcher instead, so
# the collector only ever runs when you double-click it. (Zigzap.)
if ($NoAutostart) {
  $bat = Join-Path $Dir "run-otelcol.bat"
  # %~dp0 = the .bat's own folder, so it works from a double-click or a shortcut; `pause` keeps the
  # window up if the collector exits with an error. ASCII + CRLF is what cmd.exe is happiest with.
  $batLines = (@(
    '@echo off'
    'title EQ OTel Collector'
    '"%~dp0otelcol-contrib.exe" --config "%~dp0config.yaml"'
    'pause'
  ) -join "`r`n") + "`r`n"
  [System.IO.File]::WriteAllText($bat, $batLines, [System.Text.Encoding]::ASCII)
  Write-Host "No autostart configured. Start the collector yourself when you want to play:" -ForegroundColor Green
  Write-Host "  $bat"
} else {

$Action = New-ScheduledTaskAction -Execute $Exe -Argument "--config `"$Cfg`""
$Trigger = New-ScheduledTaskTrigger -AtLogOn -User $env:USERNAME
$Settings = New-ScheduledTaskSettingsSet -Hidden -ExecutionTimeLimit ([TimeSpan]::Zero) -RestartCount 3 -RestartInterval (New-TimeSpan -Minutes 1)
Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false -ErrorAction SilentlyContinue
Register-ScheduledTask -TaskName $TaskName -Action $Action -Trigger $Trigger -Settings $Settings | Out-Null
Start-ScheduledTask -TaskName $TaskName

if (Wait-ForPort -Port 4318) {
  Write-Host "Collector running and listening on 127.0.0.1:4318 (starts automatically at logon)." -ForegroundColor Green
} else {
  throw "The collector did not start listening on 127.0.0.1:4318. Check Task Scheduler -> $TaskName."
}

}  # end of the autostart branch

# --- 4. Optional: install the custom Zeal.asi --------------------------------
if (-not $NoZeal) {
  if (-not $EqDir) {
    $EqDir = Find-EqDir
    if ($EqDir) { Write-Host "Found EverQuest at $EqDir" -ForegroundColor Green }
  }
  if (-not $EqDir) { $EqDir = Select-EqDirDialog }
  if (-not $EqDir) { $EqDir = Read-Host "EverQuest folder to install Zeal.asi into (Enter to skip)" }

  if ($EqDir) {
    if (-not (Test-Path $EqDir)) { throw "Folder not found: $EqDir" }
    if (-not (Test-Path (Join-Path $EqDir 'eqgame.exe'))) {
      throw "$EqDir does not contain eqgame.exe — that is not the EverQuest folder."
    }
    $asi = Join-Path $EqDir "Zeal.asi"
    if (Test-Path $asi) {
      Copy-Item $asi "$asi.bak-$(Get-Date -Format yyyyMMdd-HHmmss)"
      Write-Host "Backed up your existing Zeal.asi."
    }
    Write-Host "Downloading Zeal (otlp-preview release)..."
    $tmpAsi = Join-Path $Dir "Zeal.asi.download"
    Invoke-WebRequest -UseBasicParsing -Uri $ZealUrl -OutFile $tmpAsi
    # Verify if the release publishes a hash next to the binary; skip quietly if it does not.
    $want = $null
    try {
      $shaFile = Join-Path $Dir "zeal.sha256"
      Invoke-WebRequest -UseBasicParsing -Uri "$ZealUrl.sha256" -OutFile $shaFile
      $want = ((Get-Content $shaFile -Raw) -split '\s+')[0]
      Remove-Item $shaFile -Force
    } catch { $want = $null }
    if ($want) {
      $got = (Get-FileHash $tmpAsi -Algorithm SHA256).Hash
      if ($got -ne $want.ToUpper()) {
        Remove-Item $tmpAsi -Force
        throw "SHA256 mismatch on Zeal.asi (expected $want, got $got). Aborted."
      }
      Write-Host "Zeal.asi checksum verified." -ForegroundColor Green
    }
    Move-Item -Force $tmpAsi $asi
    Write-Host "Zeal.asi installed to $EqDir." -ForegroundColor Green
  }
}

Write-Host ""
if ($NoAutostart) { Write-Host "Start run-otelcol.bat before you play, then in game:  /otlp on" -ForegroundColor Cyan }
Write-Host "Done! In game, type:  /otlp on   (persists across sessions)" -ForegroundColor Cyan
Write-Host "Dashboard: https://dps.nocturnal-guild.de (log in with Discord)"
Write-Host "To remove it later: rerun this script with -Uninstall"
