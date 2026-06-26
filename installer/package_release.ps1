param(
    [string]$ProjectDir = (Resolve-Path "$PSScriptRoot\..").Path,
    [string]$OutputDir = "$PSScriptRoot\release"
)

$ErrorActionPreference = "Stop"

$distDir = Join-Path $ProjectDir "dist\app"
$zipPath = Join-Path $OutputDir "MeshChat-latest.zip"
$stageDir = Join-Path $OutputDir "stage"

if (-not (Test-Path (Join-Path $distDir "app.exe"))) {
    throw "Build not found. Run: pyinstaller app.spec --noconfirm"
}

if (Test-Path $stageDir) {
    Remove-Item -LiteralPath $stageDir -Recurse -Force
}

New-Item -ItemType Directory -Path $stageDir -Force | Out-Null
Copy-Item -Path (Join-Path $distDir "*") -Destination $stageDir -Recurse -Force

$starter = Join-Path $ProjectDir "start_messenger.bat"
if (Test-Path $starter) {
    Copy-Item -LiteralPath $starter -Destination (Join-Path $stageDir "start_messenger.bat") -Force
}

$starterNgrok = Join-Path $ProjectDir "start_messenger_ngrok.bat"
if (Test-Path $starterNgrok) {
    Copy-Item -LiteralPath $starterNgrok -Destination (Join-Path $stageDir "start_messenger_ngrok.bat") -Force
}

New-Item -ItemType Directory -Path $OutputDir -Force | Out-Null

if (Test-Path $zipPath) {
    Remove-Item -LiteralPath $zipPath -Force
}

Compress-Archive -Path (Join-Path $stageDir "*") -DestinationPath $zipPath -Force

Write-Host "Created: $zipPath" -ForegroundColor Green
