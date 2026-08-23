import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:url_launcher/url_launcher.dart';

import '../services/app_update_service.dart';
import 'mesh_liquid_glass.dart';

class AppUpdateBanner extends StatefulWidget {
  const AppUpdateBanner({super.key});

  @override
  State<AppUpdateBanner> createState() => _AppUpdateBannerState();
}

class _AppUpdateBannerState extends State<AppUpdateBanner>
    with WidgetsBindingObserver {
  static const _windowChannel = MethodChannel('meshchat/window');
  final service = AppUpdateService();
  MeshChatUpdateInfo? update;
  DateTime? lastCheck;
  bool checking = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    unawaited(_check());
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state != AppLifecycleState.resumed) return;
    final checked = lastCheck;
    if (checked == null || DateTime.now().difference(checked).inHours >= 4) {
      unawaited(_check());
    }
  }

  Future<void> _check() async {
    if (checking) return;
    checking = true;
    try {
      final result = await service.check();
      if (mounted) setState(() => update = result);
    } catch (_) {
      // Update checks must never interfere with signing in or messaging.
    } finally {
      checking = false;
      lastCheck = DateTime.now();
    }
  }

  Future<void> _openMeshHub() async {
    if (!kIsWeb && defaultTargetPlatform == TargetPlatform.windows) {
      try {
        final opened = await _windowChannel.invokeMethod<bool>('openMeshHub');
        if (opened == true) return;
      } catch (_) {
        // Fall through to the direct MeshHub download.
      }
      await launchUrl(
        Uri.parse('https://meshchat-losa.ru/downloads/MeshHub-Windows.zip'),
        mode: LaunchMode.externalApplication,
      );
      return;
    }

    final deepLink = Uri.parse('meshhub://app/meshchat');
    try {
      if (await launchUrl(deepLink, mode: LaunchMode.externalApplication)) {
        return;
      }
    } catch (_) {
      // MeshHub may not be installed yet; use its installer below.
    }

    final fallback = switch (defaultTargetPlatform) {
      TargetPlatform.android => Uri.parse(
        'https://meshchat-losa.ru/downloads/MeshHub-Android.apk',
      ),
      TargetPlatform.windows => Uri.parse(
        'https://meshchat-losa.ru/downloads/MeshHub-Windows.zip',
      ),
      _ => Uri.parse('https://meshchat-losa.ru/downloads/apps.json'),
    };
    await launchUrl(fallback, mode: LaunchMode.externalApplication);
  }

  @override
  Widget build(BuildContext context) {
    final value = update;
    if (value == null) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 6, 12, 2),
      child: MeshLiquidGlass(
        accent: const Color(0xFF42D9FF),
        radius: 16,
        prominent: true,
        forceFlutterSurface: true,
        fallbackBuilder: (context, child) => DecoratedBox(
          decoration: BoxDecoration(
            color: const Color(0xFF1B2A39),
            borderRadius: BorderRadius.circular(16),
            border: Border.all(color: const Color(0x5542D9FF)),
          ),
          child: child,
        ),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(12, 8, 8, 8),
          child: Row(
            children: [
              const Icon(Icons.system_update_rounded, color: Color(0xFF5BE3FF)),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Text(
                      'MeshChat update available',
                      style: TextStyle(fontWeight: FontWeight.w700),
                    ),
                    Text(
                      value.version.isEmpty
                          ? 'Open MeshHub to update the app'
                          : 'Version ${value.version} is ready in MeshHub',
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                  ],
                ),
              ),
              TextButton.icon(
                onPressed: _openMeshHub,
                icon: const Icon(Icons.open_in_new_rounded, size: 18),
                label: const Text('Update'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
