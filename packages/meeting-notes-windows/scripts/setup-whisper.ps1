<#
.SYNOPSIS
  Fetch a prebuilt whisper.cpp Windows binary into the app's vendor/ folder so it
  ships bundled (ModelDownloader.ResolveWhisperCli finds it next to the app exe).

.DESCRIPTION
  Downloads a pinned whisper.cpp Windows x64 build from GitHub and extracts
  whisper-cli.exe (plus its DLLs) into src/MeetingNotes.App/vendor/.

  whisper.cpp's version tags (v1.9.x) ship no binaries any more - the Windows zips
  live on the build-number prerelease tags (bNNNN) cut alongside each version, so
  "releases/latest" can't be used. To update, pick the bNNNN tag published with the
  new vX.Y.Z and change -Tag's default (b5454 = v1.9.5).

  Whisper models are NOT downloaded here - get those in-app via the "Download" button
  (Settings), or with a .bin from https://huggingface.co/ggerganov/whisper.cpp.

.NOTES
  Run from the package root:  pwsh ./scripts/setup-whisper.ps1
#>
param(
    [string]$Tag = "b5454",                 # whisper.cpp v1.9.5 binaries
    [string]$Asset = "whisper-bin-x64.zip"  # the CPU x64 binary bundle
)

$ErrorActionPreference = "Stop"
# Windows PowerShell 5.1 defaults to TLS 1.0/1.1; GitHub requires TLS 1.2.
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
$root = Split-Path -Parent $PSScriptRoot
$vendor = Join-Path $root "src/MeetingNotes.App/vendor"
New-Item -ItemType Directory -Force -Path $vendor | Out-Null

Write-Host "Looking up whisper.cpp release $Tag..."
$rel = Invoke-RestMethod -Uri "https://api.github.com/repos/ggml-org/whisper.cpp/releases/tags/$Tag" `
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