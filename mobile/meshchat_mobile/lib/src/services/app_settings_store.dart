import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/app_settings.dart';

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
      compressPhotos: prefs.getBool('compress_photos') ?? true,
      sendFilesOriginal: prefs.getBool('send_files_original') ?? true,
      dataSaver: prefs.getBool('data_saver') ?? false,
      blockedNodeIds: prefs.getStringList('blocked_node_ids') ?? const [],
      deletedGroupIds: prefs.getStringList('deleted_group_ids') ?? const [],
      deletedMessageIds: prefs.getStringList('deleted_message_ids') ?? const [],
    );
  }

  Future<void> save(AppSettings settings) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('app_theme_mode', settings.themeMode.name);
    await prefs.setInt('app_accent_color', settings.accentColor.toARGB32());
    await prefs.setBool('notifications_enabled', settings.notificationsEnabled);
    await prefs.setBool('notification_sound', settings.notificationSound);
    await prefs.setBool(
      'notification_vibration',
      settings.notificationVibration,
    );
    await prefs.setBool('notification_preview', settings.notificationPreview);
    await prefs.setBool('compress_photos', settings.compressPhotos);
    await prefs.setBool('send_files_original', settings.sendFilesOriginal);
    await prefs.setBool('data_saver', settings.dataSaver);
    await prefs.setStringList('blocked_node_ids', settings.blockedNodeIds);
    await prefs.setStringList('deleted_group_ids', settings.deletedGroupIds);
    await prefs.setStringList(
      'deleted_message_ids',
      settings.deletedMessageIds,
    );
  }

  ThemeMode _themeModeFromName(String? value) {
    return ThemeMode.values.firstWhere(
      (mode) => mode.name == value,
      orElse: () => ThemeMode.dark,
    );
  }
}
