# meshchat_mobile

A new Flutter project.

## Getting Started

This project is a starting point for a Flutter application.

A few resources to get you started if this is your first Flutter project:

- [Learn Flutter](https://docs.flutter.dev/get-started/learn-flutter)
- [Write your first Flutter app](https://docs.flutter.dev/get-started/codelab)
- [Flutter learning resources](https://docs.flutter.dev/reference/learning-resources)

For help getting started with Flutter development, view the
[online documentation](https://docs.flutter.dev/), which offers tutorials,
samples, guidance on mobile development, and a full API reference.

## Regression tests

Run the real WebSocket server sync scenarios from the repository root:

```powershell
python -m unittest discover -s server/tests -v
```

The suite uses a temporary SQLite database and random local port. It covers
multi-device login, direct-message deletion, group and channel membership,
owner permissions, file metadata, reaction deduplication, and sticker sync.

Run the Flutter checks from `mobile/meshchat_mobile`:

```powershell
flutter analyze
flutter test
```
