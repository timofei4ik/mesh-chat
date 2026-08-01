import 'package:flutter/material.dart';

import 'controllers/app_controller.dart';
import 'models/app_settings.dart';
import 'pages/chats_page.dart';
import 'pages/email_binding_page.dart';
import 'pages/login_page.dart';
import 'services/platform_capabilities.dart';
import 'widgets/mesh_liquid_glass.dart';
import 'widgets/mesh_performance_scope.dart';

class MeshChatApp extends StatefulWidget {
  const MeshChatApp({
    super.key,
    this.platformCapabilities = MeshPlatformCapabilities.standard,
  });

  final MeshPlatformCapabilities platformCapabilities;

  @override
  State<MeshChatApp> createState() => _MeshChatAppState();
}

class _MeshChatAppState extends State<MeshChatApp> {
  late final AppController controller;
  late final ValueNotifier<_AppVisualSettings> visualSettings;
  late final ValueNotifier<_RootStage> rootStage;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(_lifecycleObserver);
    controller = AppController();
    visualSettings = ValueNotifier(_visualSettingsOf(controller.appSettings));
    rootStage = ValueNotifier(_rootStageOf(controller));
    controller.addListener(_syncRootState);
    controller.restoreSession();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(_lifecycleObserver);
    controller.removeListener(_syncRootState);
    visualSettings.dispose();
    rootStage.dispose();
    controller.dispose();
    super.dispose();
  }

  late final _MeshChatLifecycleObserver _lifecycleObserver =
      _MeshChatLifecycleObserver(
        onResumed: () => controller.handleAppResumed(),
        onPaused: () => controller.handleAppPaused(),
      );

  @override
  Widget build(BuildContext context) {
    return MeshPlatformScope(
      capabilities: widget.platformCapabilities,
      child: ValueListenableBuilder<_AppVisualSettings>(
        valueListenable: visualSettings,
        builder: (context, settings, _) {
          return MeshPerformanceScope(
            lowEndDeviceMode: settings.lowEndDeviceMode,
            child: MaterialApp(
              debugShowCheckedModeBanner: false,
              title: 'MeshChat',
              themeMode: settings.themeMode,
              theme: _theme(settings.accentColor, Brightness.light),
              darkTheme: _theme(settings.accentColor, Brightness.dark),
              home: ValueListenableBuilder<_RootStage>(
                valueListenable: rootStage,
                builder: (context, stage, _) => switch (stage) {
                  _RootStage.loading => const Scaffold(
                    body: Center(child: CircularProgressIndicator()),
                  ),
                  _RootStage.login => LoginPage(controller: controller),
                  _RootStage.bindEmail => EmailBindingPage(
                    controller: controller,
                  ),
                  _RootStage.chats => ChatsPage(controller: controller),
                },
              ),
            ),
          );
        },
      ),
    );
  }

  void _syncRootState() {
    final nextVisual = _visualSettingsOf(controller.appSettings);
    if (visualSettings.value != nextVisual) visualSettings.value = nextVisual;
    final nextStage = _rootStageOf(controller);
    if (rootStage.value != nextStage) rootStage.value = nextStage;
  }

  _AppVisualSettings _visualSettingsOf(AppSettings settings) => (
    themeMode: settings.themeMode,
    accentColor: settings.accentColor,
    lowEndDeviceMode: settings.lowEndDeviceMode,
  );

  _RootStage _rootStageOf(AppController value) {
    if (!value.initialized) return _RootStage.loading;
    if (!value.hasSession) return _RootStage.login;
    if (value.emailBindingRequired) return _RootStage.bindEmail;
    return _RootStage.chats;
  }

  ThemeData _theme(Color accent, Brightness brightness) {
    final dark = brightness == Brightness.dark;
    return ThemeData(
      brightness: brightness,
      colorScheme: ColorScheme.fromSeed(
        seedColor: accent,
        brightness: brightness,
      ),
      scaffoldBackgroundColor: dark ? const Color(0xFF17191D) : null,
      appBarTheme: AppBarTheme(
        backgroundColor: dark ? const Color(0xFF20242B) : null,
        elevation: 0,
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: dark ? const Color(0xFF252930) : const Color(0xFFF1F3F6),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(8),
          borderSide: BorderSide.none,
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(8),
          borderSide: BorderSide(color: accent),
        ),
      ),
      cardTheme: CardThemeData(
        color: dark ? const Color(0xFF252930) : null,
        margin: EdgeInsets.zero,
        shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.all(Radius.circular(8)),
        ),
      ),
    );
  }
}

typedef _AppVisualSettings = ({
  ThemeMode themeMode,
  Color accentColor,
  bool lowEndDeviceMode,
});

enum _RootStage { loading, login, bindEmail, chats }

class _MeshChatLifecycleObserver extends WidgetsBindingObserver {
  _MeshChatLifecycleObserver({required this.onResumed, required this.onPaused});

  final Future<void> Function() onResumed;
  final Future<void> Function() onPaused;

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      onResumed();
    } else if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.hidden ||
        state == AppLifecycleState.detached) {
      onPaused();
    }
  }
}
