# MeshChat 1.0.99+202

Windows and Android release, with iOS source for Codemagic.

- Merge direct histories by account identity and known device aliases, not display name or avatar.
- Preserve readable cached history on integrity-check failure and request resynchronization.
- Buffer call control briefly until server authentication; cancel stale setup and ignore duplicate offers.
- Make local enhanced noise suppression available without MeshPro through an independent preference.
- Include Android system call controls and the preceding iOS Liquid Glass fixes.

Verification: 209 Flutter tests passed, final focused tests passed, analyzer issues corrected. Windows and Android release builds verified locally. iOS compilation and real-device audio testing still require macOS/Codemagic and devices.

Deployment replaces Windows ZIP, Android APK and MeshHub catalog only. No database migration, backend restart or PWA replacement. Update both call participants without clearing app data. Multi-second audio catch-up after a total network outage is not implemented.
