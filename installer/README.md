# MeshChat Installer

This folder contains a small stable installer for MeshChat.

## Release flow

1. Build the app:

```powershell
cd E:\mesh_messenger
pyinstaller app.spec --noconfirm
```

2. Package the release:

```powershell
cd E:\mesh_messenger\installer
.\Package Release.bat
```

3. Upload this file to Google Drive:

```text
E:\mesh_messenger\installer\release\MeshChat-latest.zip
```

4. In Google Drive, enable access by link and copy the file id.

For a link like this:

```text
https://drive.google.com/file/d/FILE_ID/view?usp=sharing
```

the file id is:

```text
FILE_ID
```

5. Put that id into:

```text
Install MeshChat.bat
```

Change this line:

```bat
set "GOOGLE_DRIVE_FILE_ID=PASTE_GOOGLE_DRIVE_FILE_ID_HERE"
```

## User install flow

The user runs:

```text
Install MeshChat.bat
```

The installer downloads the latest zip, installs it into:

```text
%LOCALAPPDATA%\MeshChat
```

and creates Desktop / Start Menu shortcuts.
