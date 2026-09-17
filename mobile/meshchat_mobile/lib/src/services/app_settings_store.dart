import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/app_settings.dart';
import '../models/business_settings.dart';

class AppSettingsStore {
  Future<AppSettings> load() async {
    final prefs = await SharedPreferences.getInstance();
    return AppSettings(
      themeMode: _themeModeFromName(prefs.getString('app_theme_mode')),
      accentColor: Color(prefs.getInt('app_accent_color') ?? 0xFF42A5F5),
      notificationsEnabled: prefs.getBool('notifications_enabled') ?? true,
      notificationSound: prefs.getBool('notification_sound') ?? true,
      notificationVibration: prefs.getBool('notification_vibration') ?? true,
      notificationPreview: prefs.getBool('notification_preview') ?? true,
      windowsCloseToTray: prefs.getBool('windows_close_to_tray') ?? true,
      windowsLaunchAtStartup:
          prefs.getBool('windows_launch_at_startup') ?? false,
      compressPhotos: prefs.getBool('compress_photos') ?? true,
      sendFilesOriginal: prefs.getBool('send_files_original') ?? true,
      dataSaver: prefs.getBool('data_saver') ?? false,
      lowEndDeviceMode: prefs.getBool('low_end_device_mode') ?? false,
      reducedAnimations: prefs.getBool('reduced_animations') ?? false,
      messageEffectsEnabled: prefs.getBool('message_effects_enabled') ?? true,
      showOnline: prefs.getBool('privacy_show_online') ?? true,
      showAvatar: prefs.getBool('privacy_show_avatar') ?? true,
      showAbout: prefs.getBool('privacy_show_about') ?? true,
      allowCalls: prefs.getBool('privacy_allow_calls') ?? true,
      allowGroupInvites: prefs.getBool('privacy_allow_group_invites') ?? true,
      directMessagePrivacy: DirectMessagePrivacy.values.firstWhere(
        (value) => value.name == prefs.getString('privacy_direct_messages'),
        orElse: () => DirectMessagePrivacy.everyone,
      ),
      quickReactions:
          prefs.getStringList('meshpro_quick_reactions') ??
          const ['\u2764\uFE0F', '\u{1F44C}', '\u{1FACE}', '\u{1F44D}'],
      meshProHdAudio: prefs.getBool('meshpro_hd_audio') ?? true,
      callNoiseSuppression:
          prefs.getBool('call_noise_suppression') ??
          prefs.getBool('meshpro_enhanced_noise_suppression') ??
          true,
      meshProEnhancedNoiseSuppression:
          prefs.getBool('meshpro_enhanced_noise_suppression') ?? true,
      businessSettings: BusinessSettings.fromJson(
        _decodeJson(prefs.getString('meshpro_business_settings')),
      ),
      blockedNodeIds: prefs.getStringList('blocked_node_ids') ?? const [],
      deletedGroupIds: prefs.getStringList('deleted_group_ids') ?? const [],
      deletedMessageIds: prefs.getStringList('deleted_message_ids') ?? const [],
    );
  }

  Future<void> _pendingWrite = Future<void>.value();

  Future<void> _enqueue(Map<String, Object> values) {
    final result = _pendingWrite.then((_) => _writeChanged(values));
    // A failed write must not prevent later settings from being saved.
    _pendingWrite = result.then<void>(
      (_) {},
      onError: (Object _, StackTrace _) {},
    );
    return result;
  }

  Future<void> _writeChanged(Map<String, Object> values) async {
    final prefs = await SharedPreferences.getInstance();
    for (final entry in values.entries) {
      final value = entry.value;
      if (value is List<String>
          ? listEquals(prefs.getStringList(entry.key), value)
          : prefs.get(entry.key) == value) {
        continue;
      }
      final saved = switch (value) {
        bool v => await prefs.setBool(entry.key, v),
        int v => await prefs.setInt(entry.key, v),
        String v => await prefs.setString(entry.key, v),
        List<String> v => await prefs.setStringList(entry.key, v),
        _ => throw StateError('Unsupported setting: ${entry.key}'),
      };
      if (!saved) throw StateError('Could not save setting: ${entry.key}');
    }
  }

  Future<void> save(AppSettings settings) => _enqueue({
    'app_theme_mode': settings.themeMode.name,
    'app_accent_color': settings.accentColor.toARGB32(),
    'notifications_enabled': settings.notificationsEnabled,
    'notification_sound': settings.notificationSound,
    'notification_vibration': settings.notificationVibration,
    'notification_preview': settings.notificationPreview,
    'windows_close_to_tray': settings.windowsCloseToTray,
    'windows_launch_at_startup': settings.windowsLaunchAtStartup,
    'compress_photos': settings.compressPhotos,
    'send_files_original': settings.sendFilesOriginal,
    'data_saver': settings.dataSaver,
    'low_end_device_mode': settings.lowEndDeviceMode,
    'reduced_animations': settings.reducedAnimations,
    'message_effects_enabled': settings.messageEffectsEnabled,
    'privacy_show_online': settings.showOnline,
    'privacy_show_avatar': settings.showAvatar,
    'privacy_show_about': settings.showAbout,
    'privacy_allow_calls': settings.allowCalls,
    'privacy_allow_group_invites': settings.allowGroupInvites,
    'privacy_direct_messages': settings.directMessagePrivacy.name,
    'meshpro_quick_reactions': List<String>.of(settings.quickReactions),
    'meshpro_hd_audio': settings.meshProHdAudio,
    'call_noise_suppression': settings.callNoiseSuppression,
    'meshpro_enhanced_noise_suppression':
        settings.meshProEnhancedNoiseSuppression,
    'meshpro_business_settings': jsonEncode(settings.businessSettings.toJson()),
    'blocked_node_ids': List<String>.of(settings.blockedNodeIds),
    'deleted_group_ids': List<String>.of(settings.deletedGroupIds),
    'deleted_message_ids': List<String>.of(settings.deletedMessageIds),
  });

  Future<void> saveDeletedMessageIds(List<String> messageIds) =>
      _enqueue({'deleted_message_ids': List<String>.of(messageIds)});

  ThemeMode _themeModeFromName(String? value) {
    return ThemeMode.values.firstWhere(
      (mode) => mode.name == value,
      orElse: () => ThemeMode.dark,
    );
  }

  Object? _decodeJson(String? value) {
    if (value == null || value.isEmpty) return null;
    try {
      return jsonDecode(value);
    } on FormatException {
      return null;
    }
  }
}
