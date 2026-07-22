<#
.SYNOPSIS
  Publish AI Meeting Notes (Windows) as a self-contained app and package it.

.DESCRIPTION
  - Bundles whisper-cli.exe into the app (via setup-whisper.ps1, best-effort).
  - dotnet publish, self-contained win-x64 (end users need no .NET install).
  - Produces publish/AI-Meeting-Notes-Windows-<version>.zip.
  - If Inno Setup (ISCC) is on PATH, also builds an installer .exe.

  Output filenames also include a stable, version-less copy
  (AI-Meeting-Notes-Windows.zip / Setup.exe) so a GitHub "latest release"
  download URL never needs editing - mirrors the macOS make-dmg flow.

.NOTES
  Run from the package root:  pwsh ./scripts/build-app.ps1
#>
param(
    [string]$Configuration = "Release",
    [string]$Runtime = "win-x64"
)

$ErrorActionPreference = "Stop"
$root = Split-Path -Parent $PSScriptRoot
Set-Location $root

$version = (Get-Content (Join-Path $root "VERSION")).Trim()
$app = "src/MeetingNotes.App"
$outDir = Join-Path $root "publish/app"
$pubRoot = Join-Path $root "publish"

Write-Host "Building AI Meeting Notes (Windows) $version"

# Bundle whisper-cli.exe so it ships next to the app (optional - don't fail the
# build if the release lookup hiccups; users can still point at their own copy).
try { & (Join-Path $PSScriptRoot "setup-whisper.ps1") } catch {
    Write-Warning "whisper-cli bundling skipped: $_"
}

Remove-Item -Recurse -Force $pubRoot -ErrorAction SilentlyContinue
dotnet publish $app -c $Configuration -r $Runtime --self-contained `
    -p:Version=$version -p:PublishSingleFile=false -o $outDir

$zipVer = Join-Path $pubRoot "AI-Meeting-Notes-Windows-$version.zip"
$zipLatest = Join-Path $pubRoot "AI-Meeting-Notes-Windows.zip"   # stable name for releases/latest
Compress-Archive -Path (Join-Path $outDir "*") -DestinationPath $zipVer -Force
Copy-Item $zipVer $zipLatest -Force
Write-Host "Packaged: $zipVer"

# Optional Inno Setup installer.
$iscc = Get-Command ISCC.exe -ErrorAction SilentlyContinue
if ($iscc) {
    Write-Host "Building installer with Inno Setup..."
    & $iscc.Source "/DMyAppVersion=$version" "/DMyAppDir=$outDir" "/O$pubRoot" (Join-Path $PSScriptRoot "installer.iss")
    $setup = Join-Path $pubRoot "AI-Meeting-Notes-Setup-$version.exe"
    if (Test-Path $setup) { Copy-Item $setup (Join-Path $pubRoot "AI-Meeting-Notes-Setup.exe") -Force }
} else {
    Write-Host "(Inno Setup not found - skipping installer; the zip is the portable build.)"
}