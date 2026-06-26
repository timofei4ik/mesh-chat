param(
    [string]$ReleaseUrl = "",
    [string]$GoogleDriveFileId = "",
    [string]$InstallDir = "$env:LOCALAPPDATA\MeshChat"
)

$ErrorActionPreference = "Stop"

# Defaults used when the script is launched directly without Install MeshChat.bat.
$DefaultGoogleDriveFileId = "1UAK6BYOl7WGE8JBCvtn9Arc0W_TNpHqB"
$DefaultReleaseUrl = ""

if (-not $GoogleDriveFileId -and $DefaultGoogleDriveFileId) {
    $GoogleDriveFileId = $DefaultGoogleDriveFileId
}

if (-not $ReleaseUrl -and $DefaultReleaseUrl) {
    $ReleaseUrl = $DefaultReleaseUrl
}

function Write-Step($Text) {
    Write-Host ""
    Write-Host "== $Text" -ForegroundColor Cyan
}

function Get-GoogleDriveFileIdFromUrl($Url) {
    if ($Url -match "/file/d/([^/]+)") {
        return $Matches[1]
    }

    if ($Url -match "[?&]id=([^&]+)") {
        return $Matches[1]
    }

    return ""
}

function Download-GoogleDriveFile($FileId, $OutFile) {
    $session = New-Object Microsoft.PowerShell.Commands.WebRequestSession
    $url = "https://drive.google.com/uc?export=download&id=$FileId"
    $first = Invoke-WebRequest -Uri $url -WebSession $session -UseBasicParsing

    $downloadUrl = $url

    if ($first.Content -match 'confirm=([0-9A-Za-z_]+)') {
        $confirm = $Matches[1]
        $downloadUrl = "https://drive.google.com/uc?export=download&confirm=$confirm&id=$FileId"
    }

    if ($first.Content -match 'href="([^"]*uc\?export=download[^"]*)"') {
        $downloadUrl = $Matches[1] -replace "&amp;", "&"

        if ($downloadUrl -notmatch "^https?://") {
            $downloadUrl = "https://drive.google.com$downloadUrl"
        }
    }

    Invoke-WebRequest -Uri $downloadUrl -OutFile $OutFile -WebSession $session -UseBasicParsing
}

function Test-ZipFile($Path) {
    if (-not (Test-Path $Path)) {
        return $false
    }

    $bytes = [System.IO.File]::ReadAllBytes($Path)

    if ($bytes.Length -lt 4) {
        return $false
    }

    return (
        $bytes[0] -eq 0x50 -and
        $bytes[1] -eq 0x4B -and
        (
            ($bytes[2] -eq 0x03 -and $bytes[3] -eq 0x04) -or
            ($bytes[2] -eq 0x05 -and $bytes[3] -eq 0x06) -or
            ($bytes[2] -eq 0x07 -and $bytes[3] -eq 0x08)
        )
    )
}

function Download-Release($OutFile) {
    if ($GoogleDriveFileId) {
        Download-GoogleDriveFile $GoogleDriveFileId $OutFile
        return
    }

    if ($ReleaseUrl) {
        $fileId = Get-GoogleDriveFileIdFromUrl $ReleaseUrl

        if ($fileId) {
            Download-GoogleDriveFile $fileId $OutFile
            return
        }

        Invoke-WebRequest -Uri $ReleaseUrl -OutFile $OutFile -UseBasicParsing
        return
    }

    throw "Set ReleaseUrl or GoogleDriveFileId at the top of install_meshchat.bat / install_meshchat.ps1."
}

Write-Step "Downloading MeshChat"
$tempDir = Join-Path $env:TEMP ("MeshChatInstall_" + [guid]::NewGuid().ToString("N"))
$zipPath = Join-Path $tempDir "meshchat.zip"
$extractDir = Join-Path $tempDir "extract"
New-Item -ItemType Directory -Path $tempDir | Out-Null
New-Item -ItemType Directory -Path $extractDir | Out-Null

$localZip = Join-Path $PSScriptRoot "MeshChat-latest.zip"
$releaseZip = Join-Path (Join-Path $PSScriptRoot "release") "MeshChat-latest.zip"

if (Test-Path $localZip) {
    Write-Host "Using local release zip: $localZip"
    Copy-Item -LiteralPath $localZip -Destination $zipPath -Force
} elseif (Test-Path $releaseZip) {
    Write-Host "Using local release zip: $releaseZip"
    Copy-Item -LiteralPath $releaseZip -Destination $zipPath -Force
} else {
    Download-Release $zipPath
}

if ((Get-Item $zipPath).Length -lt 1024) {
    throw "Downloaded file is too small. Check the Google Drive sharing settings or direct link."
}

if (-not (Test-ZipFile $zipPath)) {
    $preview = Get-Content -LiteralPath $zipPath -TotalCount 5 -ErrorAction SilentlyContinue
    Write-Host ""
    Write-Host "Downloaded file is not a zip archive." -ForegroundColor Red
    Write-Host "Most likely Google Drive returned an HTML page instead of MeshChat-latest.zip."
    Write-Host "Check that the Drive file is shared with 'Anyone with the link' and that the id points to MeshChat-latest.zip."
    if ($preview) {
        Write-Host ""
        Write-Host "Downloaded file preview:"
        Write-Host $preview
    }
    throw "Downloaded file is not a zip archive."
}

Write-Step "Stopping old MeshChat"
Get-Process app -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue

Write-Step "Installing to $InstallDir"
if (Test-Path $InstallDir) {
    Remove-Item -LiteralPath $InstallDir -Recurse -Force
}

Expand-Archive -LiteralPath $zipPath -DestinationPath $extractDir -Force

$appExe = Get-ChildItem -Path $extractDir -Recurse -Filter "app.exe" | Select-Object -First 1

if (-not $appExe) {
    throw "app.exe was not found inside the downloaded zip."
}

$sourceDir = $appExe.Directory.FullName
New-Item -ItemType Directory -Path $InstallDir | Out-Null
Copy-Item -Path (Join-Path $sourceDir "*") -Destination $InstallDir -Recurse -Force

Write-Step "Creating shortcuts"
$shell = New-Object -ComObject WScript.Shell
$desktopShortcut = Join-Path ([Environment]::GetFolderPath("Desktop")) "MeshChat.lnk"
$shortcut = $shell.CreateShortcut($desktopShortcut)
$shortcut.TargetPath = Join-Path $InstallDir "app.exe"
$shortcut.WorkingDirectory = $InstallDir
$shortcut.IconLocation = Join-Path $InstallDir "app.exe"
$shortcut.Save()

$startMenuDir = Join-Path $env:APPDATA "Microsoft\Windows\Start Menu\Programs\MeshChat"
New-Item -ItemType Directory -Path $startMenuDir -Force | Out-Null
$startMenuShortcut = Join-Path $startMenuDir "MeshChat.lnk"
$shortcut = $shell.CreateShortcut($startMenuShortcut)
$shortcut.TargetPath = Join-Path $InstallDir "app.exe"
$shortcut.WorkingDirectory = $InstallDir
$shortcut.IconLocation = Join-Path $InstallDir "app.exe"
$shortcut.Save()

Write-Step "Done"
Write-Host "MeshChat installed successfully." -ForegroundColor Green
Write-Host "Path: $InstallDir"

Remove-Item -LiteralPath $tempDir -Recurse -Force -ErrorAction SilentlyContinue
