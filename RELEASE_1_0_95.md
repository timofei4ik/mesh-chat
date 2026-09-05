# MeshChat 1.0.95+198

## Scope

Windows, Android, server and Git for Codemagic. PWA is not rebuilt in this release.
Group audio uses bounded full mesh for at most eight invited devices, not SFU.
All participating clients must be updated. Physical multi-device audio and
network-handover acceptance checks remain outstanding.

## Verification

- Implementation checkpoint: 312 server tests and 148 Flutter tests passed.
- Release staging: `flutter analyze --no-pub` passed with no issues.
- Server preflight: 38 focused tests completed, with two optional integration
  tests skipped because this preflight did not configure a disposable test DSN.
- Production PostgreSQL backup passed `pg_restore --list` verification before
  migration 014. Additive migration applied successfully.
- Both relay workers, both call-signaling workers, media and metrics restarted
  successfully. The system health check passed.
- Public WebSocket smoke tests passed through dedicated call signaling and
  direct Redis PubSub; synthetic accounts were removed afterward.
- `MESH_RELIABLE_DELIVERY_ENABLED` remains off. This release does not enable
  the experimental delivery protocol globally.

## Repeatable Local Build

Use one real, short staging directory on a drive with sufficient free space.
This run uses `E:\mc198`, `E:\meshchat-tmp198` and
`E:\meshchat-release-198`. Do not build Windows from the long repository path.
Do not change dependencies or remove the shared Gradle/Pub caches for a release.

Copy the Flutter app with `robocopy /E`, excluding `build`, `.dart_tool`, `.git`,
`ephemeral`, raw animation `source`, `artifacts` and logs. Copy the existing
Firebase configuration and Android signing configuration when present.

Environment used:

```powershell
$env:PUB_CACHE='E:\meshchat_pub_cache'
$env:GRADLE_USER_HOME='D:\meshchat-build-cache'
$env:TEMP='E:\meshchat-tmp198'
$env:TMP=$env:TEMP
```

Run `D:\flutter\bin\flutter.bat pub get` in staging. Before the first Windows
build, create `build\windows\x64` and copy the already downloaded archive
`D:\meshchat-build-cache\firebase_cpp_sdk_windows_13.9.0.zip` into it, retaining
its filename. The first attempt in this run stalled downloading this SDK;
using the existing archive let the normal build complete without code changes.

```powershell
& D:\flutter\bin\flutter.bat build windows --release --no-pub
& D:\flutter\bin\flutter.bat build apk --release --no-pub --dart-define-from-file=firebase_push.json
```

Keep the contents of `build\windows\x64\runner\Release` together in the ZIP.
Verify the APK certificate against the preceding APK before publishing, and
verify both artifacts report `1.0.95+198`.

## Server Rollout

Server: existing SSH deploy identity, existing `/root/mesh_messenger` checkout.
Backup and upload directory: `/root/meshchat-release-198`.
Only changed server modules and new supporting files were overlaid; deployed
runtime modules matched the Git baseline before replacement. Credentials and
environment files were not replaced. Migration ran before worker restarts.

The prior code is in `server-before.tar.gz`; the verified database backup is
inside `database-backup`. Code rollback can leave additive migration 014 in place.
Never restore the entire database over newer user messages merely to roll back
application code.

Publish Windows and Android packages under `/var/www/meshchat-web/downloads`,
verify SHA-256, and replace `apps.json` last. Preserve the prior download files
under the release directory. Do not replace the PWA archive or static site.
