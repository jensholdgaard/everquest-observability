# EverQuest guild telemetry — Windows client installer.
# Installs the local OTel collector (forwards Zeal's metrics to the guild server with your token),
# registers it to start at logon, and (optionally) installs the custom Zeal.asi into your EQ folder.
#
# Usage (PowerShell):
#   .\install.ps1                          # interactive (prompts for token and EQ folder)
#   .\install.ps1 -Token abc123 -EqDir "C:\TAKP"   # non-interactive
param(
  [string]$Token,
  [string]$EqDir,
  [string]$Endpoint = "https://dps.nocturnal-guild.de/otlp/v1/metrics",
  [string]$TracesEndpoint = "https://dps.nocturnal-guild.de/otlp/v1/traces"
)
$ErrorActionPreference = "Stop"
$Ver = "0.157.0"
$Dir = Join-Path $env:LOCALAPPDATA "eq-otel"

Write-Host "== EverQuest guild telemetry installer ==" -ForegroundColor Cyan

if (-not $Token) { $Token = Read-Host "Paste your guild ingest token" }
if (-not $Token) { throw "A token is required (ask Jens / the guild Discord)." }

New-Item -ItemType Directory -Force -Path $Dir | Out-Null

# --- 1. Local OTel collector -------------------------------------------------
$Exe = Join-Path $Dir "otelcol-contrib.exe"
if (-not (Test-Path $Exe)) {
  Write-Host "Downloading OpenTelemetry Collector v$Ver..."
  $tgz = Join-Path $Dir "otelcol.tar.gz"
  Invoke-WebRequest -Uri "https://github.com/open-telemetry/opentelemetry-collector-releases/releases/download/v$Ver/otelcol-contrib_${Ver}_windows_amd64.tar.gz" -OutFile $tgz
  tar -xzf $tgz -C $Dir otelcol-contrib.exe
  Remove-Item $tgz
}

# --- 2. Config (token embedded; file lives in your user profile) -------------
$Cfg = Join-Path $Dir "config.yaml"
@"
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
  debug:
    verbosity: basic
service:
  extensions: [bearertokenauth]
  pipelines:
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
"@ | Set-Content -Path $Cfg -Encoding UTF8

# --- 3. Run at logon (hidden), and start now ---------------------------------
$TaskName = "EQ-OTel-Collector"
$Action = New-ScheduledTaskAction -Execute $Exe -Argument "--config `"$Cfg`""
$Trigger = New-ScheduledTaskTrigger -AtLogOn -User $env:USERNAME
$Settings = New-ScheduledTaskSettingsSet -Hidden -ExecutionTimeLimit ([TimeSpan]::Zero) -RestartCount 3 -RestartInterval (New-TimeSpan -Minutes 1)
Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false -ErrorAction SilentlyContinue
Register-ScheduledTask -TaskName $TaskName -Action $Action -Trigger $Trigger -Settings $Settings | Out-Null
Start-ScheduledTask -TaskName $TaskName
Write-Host "Collector installed and running (starts automatically at logon)." -ForegroundColor Green

# --- 4. Optional: install the custom Zeal.asi --------------------------------
if (-not $EqDir) { $EqDir = Read-Host "EverQuest folder to install Zeal.asi into (Enter to skip)" }
if ($EqDir) {
  if (-not (Test-Path $EqDir)) { throw "Folder not found: $EqDir" }
  $asi = Join-Path $EqDir "Zeal.asi"
  if (Test-Path $asi) {
    Copy-Item $asi "$asi.bak-$(Get-Date -Format yyyyMMdd-HHmmss)"
    Write-Host "Backed up existing Zeal.asi."
  }
  Write-Host "Downloading Zeal (otlp-preview release)..."
  Invoke-WebRequest -Uri "https://github.com/jensholdgaard/NewZeal/releases/download/otlp-preview/Zeal.asi" -OutFile $asi
  Write-Host "Zeal.asi installed to $EqDir." -ForegroundColor Green
}

Write-Host ""
Write-Host "Done! In game, type:  /otlp on   (persists across sessions)" -ForegroundColor Cyan
Write-Host "Dashboard: https://dps.nocturnal-guild.de (log in with Discord)"
