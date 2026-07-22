import 'package:flutter/material.dart';

import 'controllers/app_controller.dart';
import 'pages/chats_page.dart';
import 'pages/email_binding_page.dart';
import 'pages/login_page.dart';
import 'services/platform_capabilities.dart';
import 'widgets/mesh_liquid_glass.dart';

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

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(_lifecycleObserver);
    controller = AppController()..restoreSession();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(_lifecycleObserver);
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
      child: ListenableBuilder(
        listenable: controller,
        builder: (context, _) {
          final settings = controller.appSettings;
          return MaterialApp(
            debugShowCheckedModeBanner: false,
            title: 'MeshChat',
            themeMode: settings.themeMode,
            theme: _theme(settings.accentColor, Brightness.light),
            darkTheme: _theme(settings.accentColor, Brightness.dark),
            home: Builder(
              builder: (context) {
                if (!controller.initialized) {
                  return const Scaffold(
                    body: Center(child: CircularProgressIndicator()),
                  );
                }
                if (!controller.hasSession) {
                  return LoginPage(controller: controller);
                }
                if (controller.emailBindingRequired) {
                  return EmailBindingPage(controller: controller);
                }
                return ChatsPage(controller: controller);
              },
            ),
          );
        },
      ),
    );
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
