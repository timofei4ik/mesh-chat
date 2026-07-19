import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'src/app.dart';
import 'src/services/android_push_service.dart';
import 'src/services/firebase_telemetry_service.dart';
import 'src/services/platform_capabilities.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  if (!kIsWeb &&
      (defaultTargetPlatform == TargetPlatform.android ||
          defaultTargetPlatform == TargetPlatform.iOS)) {
    await SystemChrome.setPreferredOrientations([DeviceOrientation.portraitUp]);
  }
  if (!kIsWeb && defaultTargetPlatform == TargetPlatform.android) {
    await initializeAndroidPushBackgroundHandling();
  }
  await FirebaseTelemetryService.initialize();
  if (!kIsWeb &&
      (defaultTargetPlatform == TargetPlatform.windows ||
          defaultTargetPlatform == TargetPlatform.linux ||
          defaultTargetPlatform == TargetPlatform.macOS)) {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  }
  final platformCapabilities = await FirebaseTelemetryService.trace(
    'platform_capabilities',
    MeshPlatformCapabilities.detect,
  );
  runApp(MeshChatApp(platformCapabilities: platformCapabilities));
}
