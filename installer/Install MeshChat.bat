@echo off
setlocal

cd /d "%~dp0"

rem Put your Google Drive file id here.
rem Example link:
rem https://drive.google.com/file/d/FILE_ID/view?usp=sharing
set "GOOGLE_DRIVE_FILE_ID=1UAK6BYOl7WGE8JBCvtn9Arc0W_TNpHqB"

rem Or use a direct URL instead. Leave empty when GOOGLE_DRIVE_FILE_ID is set.
set "RELEASE_URL="

if "%GOOGLE_DRIVE_FILE_ID%"=="PASTE_GOOGLE_DRIVE_FILE_ID_HERE" (
    echo Google Drive file id is not configured.
    echo Open this bat file and set GOOGLE_DRIVE_FILE_ID.
    pause
    exit /b 1
)

if "%GOOGLE_DRIVE_FILE_ID%%RELEASE_URL%"=="" (
    echo Google Drive file id or release URL is empty.
    echo Open this bat file and set GOOGLE_DRIVE_FILE_ID.
    pause
    exit /b 1
)

powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0install_meshchat.ps1" -GoogleDriveFileId "%GOOGLE_DRIVE_FILE_ID%" -ReleaseUrl "%RELEASE_URL%"

if errorlevel 1 (
    echo.
    echo Install failed.
    pause
    exit /b 1
)

echo.
pause
