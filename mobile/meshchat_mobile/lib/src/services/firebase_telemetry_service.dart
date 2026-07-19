import 'dart:async';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_crashlytics/firebase_crashlytics.dart';
import 'package:firebase_performance/firebase_performance.dart';
import 'package:flutter/foundation.dart';

const _apiKey = String.fromEnvironment('MESH_FIREBASE_API_KEY');
const _androidAppId = String.fromEnvironment('MESH_FIREBASE_APP_ID');
const _iosAppId = String.fromEnvironment('MESH_FIREBASE_IOS_APP_ID');
const _senderId = String.fromEnvironment('MESH_FIREBASE_MESSAGING_SENDER_ID');
const _projectId = String.fromEnvironment('MESH_FIREBASE_PROJECT_ID');
const _storageBucket = String.fromEnvironment('MESH_FIREBASE_STORAGE_BUCKET');
const _iosBundleId = String.fromEnvironment(
  'MESH_FIREBASE_IOS_BUNDLE_ID',
  defaultValue: 'com.meshchat.mobile',
);

class FirebaseTelemetryService {
  FirebaseTelemetryService._();

  static bool _ready = false;
  static bool get isReady => _ready;

  static bool get _isSupported {
    if (kIsWeb) return false;
    return defaultTargetPlatform == TargetPlatform.android ||
        defaultTargetPlatform == TargetPlatform.iOS;
  }

  static Future<void> initialize() async {
    if (!_isSupported) return;

    try {
      if (Firebase.apps.isEmpty) {
        if (_hasRuntimeConfiguration) {
          await Firebase.initializeApp(options: _runtimeOptions);
        } else {
          await Firebase.initializeApp();
        }
      }
      await FirebaseCrashlytics.instance.setCrashlyticsCollectionEnabled(
        kReleaseMode,
      );
      await FirebasePerformance.instance.setPerformanceCollectionEnabled(
        kReleaseMode,
      );
      _ready = true;
      _installErrorHandlers();
    } catch (error, stackTrace) {
      debugPrint('Firebase telemetry is unavailable: $error');
      debugPrintStack(stackTrace: stackTrace);
    }
  }

  static Future<T> trace<T>(String name, Future<T> Function() operation) async {
    if (!_ready) return operation();
    final trace = FirebasePerformance.instance.newTrace(name);
    await trace.start();
    try {
      return await operation();
    } catch (error, stackTrace) {
      await recordError(error, stackTrace, reason: 'trace:$name');
      rethrow;
    } finally {
      await trace.stop();
    }
  }

  static Future<void> recordError(
    Object error,
    StackTrace stackTrace, {
    String? reason,
    bool fatal = false,
  }) async {
    if (!_ready) return;
    await FirebaseCrashlytics.instance.recordError(
      error,
      stackTrace,
      reason: reason,
      fatal: fatal,
    );
  }

  static void _installErrorHandlers() {
    final previousFlutterHandler = FlutterError.onError;
    FlutterError.onError = (details) {
      previousFlutterHandler?.call(details);
      unawaited(FirebaseCrashlytics.instance.recordFlutterFatalError(details));
    };

    final previousPlatformHandler = PlatformDispatcher.instance.onError;
    PlatformDispatcher.instance.onError = (error, stackTrace) {
      unawaited(
        FirebaseCrashlytics.instance.recordError(
          error,
          stackTrace,
          fatal: true,
        ),
      );
      return previousPlatformHandler?.call(error, stackTrace) ?? true;
    };
  }

  static bool get _hasRuntimeConfiguration {
    final appId = defaultTargetPlatform == TargetPlatform.iOS
        ? _iosAppId
        : _androidAppId;
    return _apiKey.isNotEmpty &&
        appId.isNotEmpty &&
        _senderId.isNotEmpty &&
        _projectId.isNotEmpty;
  }

  static FirebaseOptions get _runtimeOptions => FirebaseOptions(
    apiKey: _apiKey,
    appId: defaultTargetPlatform == TargetPlatform.iOS
        ? _iosAppId
        : _androidAppId,
    messagingSenderId: _senderId,
    projectId: _projectId,
    storageBucket: _storageBucket.isEmpty ? null : _storageBucket,
    iosBundleId: defaultTargetPlatform == TargetPlatform.iOS
        ? _iosBundleId
        : null,
  );
}
