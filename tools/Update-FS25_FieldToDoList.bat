@echo off
setlocal EnableExtensions

:: =============================================================================
:: FS25_FieldToDoList — buddy updater (Windows, single file)
:: Compares mods\FS25_FieldToDoList.zip with the latest GitHub release and
:: replaces it when remote is newer. No local .bak — GitHub keeps release history.
::
:: Double-click this file only (no extra .ps1 needed). Windows 10/11 + internet.
:: =============================================================================

:: --- edit if your mods folder is elsewhere ---------------------------------
set "MODS_DIR=%USERPROFILE%\Documents\My Games\FarmingSimulator2025\mods"
:: ---------------------------------------------------------------------------

set "REPO=knoellix/FS25_ToDo"
set "ZIP_NAME=FS25_FieldToDoList.zip"

echo.
echo  FS25_FieldToDoList updater
echo  Mods folder: %MODS_DIR%
echo.

if not exist "%MODS_DIR%\" (
  echo ERROR: Mods folder not found.
  echo Edit MODS_DIR at the top of this .bat if needed.
  goto :end
)

where powershell >nul 2>&1
if errorlevel 1 (
  echo ERROR: PowerShell is required.
  goto :end
)

:: Extract PowerShell payload after the :::PS1 marker into a temp file and run it.
powershell -NoProfile -ExecutionPolicy Bypass -Command ^
  "$bat = $env:FTDL_BAT; if ([string]::IsNullOrWhiteSpace($bat)) { $bat = '%~f0' };" ^
  "$lines = Get-Content -LiteralPath $bat -ErrorAction Stop;" ^
  "$start = -1; for ($i = 0; $i -lt $lines.Count; $i++) { if ($lines[$i] -eq ':::PS1') { $start = $i + 1; break } };" ^
  "if ($start -lt 0) { Write-Host 'ERROR: Missing :::PS1 payload in .bat'; exit 1 };" ^
  "$script = ($lines[$start..($lines.Count - 1)] -join [Environment]::NewLine);" ^
  "$tmp = Join-Path $env:TEMP ('FS25_FieldToDoList_update_' + [guid]::NewGuid().ToString('N') + '.ps1');" ^
  "Set-Content -LiteralPath $tmp -Value $script -Encoding UTF8;" ^
  "try {" ^
  "  & $tmp -ModsDir $env:MODS_DIR -Repo $env:REPO -ZipName $env:ZIP_NAME;" ^
  "  exit $LASTEXITCODE" ^
  "} finally {" ^
  "  Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue" ^
  "}"

set "EC=%ERRORLEVEL%"

:end
echo.
pause
exit /b %EC%

:::PS1
#requires -Version 5.0
param(
    [Parameter(Mandatory = $true)][string]$ModsDir,
    [Parameter(Mandatory = $true)][string]$Repo,
    [Parameter(Mandatory = $true)][string]$ZipName
)

$ErrorActionPreference = "Stop"

function Get-VersionFromZip {
    param([string]$ZipPath)
    if (-not (Test-Path -LiteralPath $ZipPath)) {
        return $null
    }
    Add-Type -AssemblyName System.IO.Compression.FileSystem | Out-Null
    $zip = [System.IO.Compression.ZipFile]::OpenRead($ZipPath)
    try {
        $entry = $zip.Entries | Where-Object {
            ($_.FullName -replace '\\', '/') -eq 'modDesc.xml' -or $_.Name -eq 'modDesc.xml'
        } | Select-Object -First 1
        if ($null -eq $entry) {
            return $null
        }
        $stream = $entry.Open()
        try {
            $reader = New-Object System.IO.StreamReader($stream)
            $xmlText = $reader.ReadToEnd()
            $reader.Close()
        }
        finally {
            $stream.Dispose()
        }
        if ($xmlText -match '<version>\s*([^<]+?)\s*</version>') {
            return $Matches[1].Trim()
        }
        return $null
    }
    finally {
        $zip.Dispose()
    }
}

function ConvertTo-VersionParts {
    param([string]$Version)
    $clean = ($Version -replace '^[vV]', '').Trim()
    $parts = @($clean.Split('.') | ForEach-Object {
        if ($_ -match '^\d+$') { [int]$_ } else { 0 }
    })
    while ($parts.Count -lt 4) { $parts += 0 }
    return ,$parts[0..3]
}

function Compare-ModVersion {
    param([string]$Left, [string]$Right)
    $a = ConvertTo-VersionParts $Left
    $b = ConvertTo-VersionParts $Right
    for ($i = 0; $i -lt 4; $i++) {
        if ($a[$i] -lt $b[$i]) { return -1 }
        if ($a[$i] -gt $b[$i]) { return 1 }
    }
    return 0
}

$localZip = Join-Path $ModsDir $ZipName
$apiUrl = "https://api.github.com/repos/$Repo/releases/latest"

Write-Host "Checking GitHub: $Repo/releases/latest ..."

try {
    $headers = @{
        "User-Agent" = "FS25-FieldToDoList-Updater"
        "Accept"     = "application/vnd.github+json"
    }
    $release = Invoke-RestMethod -Uri $apiUrl -Headers $headers -TimeoutSec 60
}
catch {
    Write-Host "ERROR: Could not reach GitHub releases API."
    Write-Host $_.Exception.Message
    exit 1
}

$remoteTag = [string]$release.tag_name
$remoteVersion = ($remoteTag -replace '^[vV]', '').Trim()
$asset = $release.assets | Where-Object { $_.name -eq $ZipName } | Select-Object -First 1
if ($null -eq $asset -or [string]::IsNullOrWhiteSpace($asset.browser_download_url)) {
    Write-Host "ERROR: Release asset '$ZipName' not found on latest release ($remoteTag)."
    exit 1
}
$downloadUrl = [string]$asset.browser_download_url

$localVersion = Get-VersionFromZip -ZipPath $localZip
if ($null -eq $localVersion) {
    Write-Host "Local:  (not installed)"
}
else {
    Write-Host "Local:  $localVersion"
}
Write-Host "Remote: $remoteVersion  ($remoteTag)"

if ($null -ne $localVersion) {
    $cmp = Compare-ModVersion -Left $localVersion -Right $remoteVersion
    if ($cmp -ge 0) {
        Write-Host ""
        Write-Host "Already up to date. Nothing to do."
        exit 0
    }
    Write-Host ""
    Write-Host "Update available: $localVersion -> $remoteVersion"
}
else {
    Write-Host ""
    Write-Host "Installing $ZipName ($remoteVersion) ..."
}

$tempDir = Join-Path $env:TEMP ("FS25_FieldToDoList_update_" + [guid]::NewGuid().ToString("N"))
New-Item -ItemType Directory -Path $tempDir | Out-Null
$tempZip = Join-Path $tempDir $ZipName

try {
    Write-Host "Downloading ..."
    Invoke-WebRequest -Uri $downloadUrl -OutFile $tempZip -Headers @{ "User-Agent" = "FS25-FieldToDoList-Updater" } -TimeoutSec 120

    $downloadedVersion = Get-VersionFromZip -ZipPath $tempZip
    if ($null -eq $downloadedVersion) {
        throw "Downloaded zip has no readable modDesc.xml version."
    }

    if (-not (Test-Path -LiteralPath $ModsDir)) {
        throw "Mods folder missing: $ModsDir"
    }

    Copy-Item -LiteralPath $tempZip -Destination $localZip -Force
    Write-Host ""
    Write-Host "Done. Installed version $downloadedVersion"
    Write-Host "Path: $localZip"
    Write-Host "Restart Farming Simulator 25 fully if it was running."
    exit 0
}
catch {
    Write-Host "ERROR: Update failed."
    Write-Host $_.Exception.Message
    exit 1
}
finally {
    if (Test-Path -LiteralPath $tempDir) {
        Remove-Item -LiteralPath $tempDir -Recurse -Force -ErrorAction SilentlyContinue
    }
}
