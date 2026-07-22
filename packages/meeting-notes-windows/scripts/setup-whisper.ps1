<#
.SYNOPSIS
  Fetch a prebuilt whisper.cpp Windows binary into the app's vendor/ folder so it
  ships bundled (ModelDownloader.ResolveWhisperCli finds it next to the app exe).

.DESCRIPTION
  Downloads the latest whisper.cpp Windows x64 release zip from GitHub and extracts
  whisper-cli.exe (plus its DLLs) into src/MeetingNotes.App/vendor/. Re-run to update.

  Whisper models are NOT downloaded here - get those in-app via the "Download" button
  (Settings), or with a .bin from https://huggingface.co/ggerganov/whisper.cpp.

.NOTES
  Run from the package root:  pwsh ./scripts/setup-whisper.ps1
#>
param(
    [string]$Asset = "whisper-bin-x64.zip"  # the CPU x64 binary bundle
)

$ErrorActionPreference = "Stop"
# Windows PowerShell 5.1 defaults to TLS 1.0/1.1; GitHub requires TLS 1.2.
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
$root = Split-Path -Parent $PSScriptRoot
$vendor = Join-Path $root "src/MeetingNotes.App/vendor"
New-Item -ItemType Directory -Force -Path $vendor | Out-Null

Write-Host "Looking up the latest whisper.cpp release..."
$rel = Invoke-RestMethod -Uri "https://api.github.com/repos/ggml-org/whisper.cpp/releases/latest" `
    -Headers @{ "User-Agent" = "meeting-notes" }
$dl = ($rel.assets | Where-Object { $_.name -eq $Asset }).browser_download_url
if (-not $dl) {
    throw "Asset '$Asset' not found in $($rel.tag_name). Available: $($rel.assets.name -join ', ')"
}

$zip = Join-Path $env:TEMP $Asset
Write-Host "Downloading $($rel.tag_name) -> $Asset"
Invoke-WebRequest -Uri $dl -OutFile $zip

$extract = Join-Path $env:TEMP "whisper-extract"
Remove-Item -Recurse -Force $extract -ErrorAction SilentlyContinue
Expand-Archive -Path $zip -DestinationPath $extract

# Copy whisper-cli.exe and the runtime DLLs it needs next to it.
$cli = Get-ChildItem -Recurse -Path $extract -Filter "whisper-cli.exe" | Select-Object -First 1
if (-not $cli) { throw "whisper-cli.exe not found in the release zip." }
Copy-Item $cli.FullName -Destination $vendor -Force
Get-ChildItem -Path $cli.Directory -Filter "*.dll" | Copy-Item -Destination $vendor -Force

Write-Host "Bundled whisper-cli.exe into $vendor"