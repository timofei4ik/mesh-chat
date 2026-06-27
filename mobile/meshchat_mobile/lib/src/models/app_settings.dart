import 'package:flutter/material.dart';

class AppSettings {
  const AppSettings({
    this.themeMode = ThemeMode.dark,
    this.accentColor = const Color(0xFF42A5F5),
    this.notificationsEnabled = true,
    this.notificationSound = true,
    this.notificationVibration = true,
    this.notificationPreview = true,
    this.compressPhotos = true,
    this.sendFilesOriginal = true,
    this.dataSaver = false,
    this.blockedNodeIds = const [],
    this.deletedGroupIds = const [],
    this.deletedMessageIds = const [],
  });

  final ThemeMode themeMode;
  final Color accentColor;
  final bool notificationsEnabled;
  final bool notificationSound;
  final bool notificationVibration;
  final bool notificationPreview;
  final bool compressPhotos;
  final bool sendFilesOriginal;
  final bool dataSaver;
  final List<String> blockedNodeIds;
  final List<String> deletedGroupIds;
  final List<String> deletedMessageIds;

  AppSettings copyWith({
    ThemeMode? themeMode,
    Color? accentColor,
    bool? notificationsEnabled,
    bool? notificationSound,
    bool? notificationVibration,
    bool? notificationPreview,
    bool? compressPhotos,
    bool? sendFilesOriginal,
    bool? dataSaver,
    List<String>? blockedNodeIds,
    List<String>? deletedGroupIds,
    List<String>? deletedMessageIds,
  }) {
    return AppSettings(
      themeMode: themeMode ?? this.themeMode,
      accentColor: accentColor ?? this.accentColor,
      notificationsEnabled: notificationsEnabled ?? this.notificationsEnabled,
      notificationSound: notificationSound ?? this.notificationSound,
      notificationVibration:
          notificationVibration ?? this.notificationVibration,
      notificationPreview: notificationPreview ?? this.notificationPreview,
      compressPhotos: compressPhotos ?? this.compressPhotos,
      sendFilesOriginal: sendFilesOriginal ?? this.sendFilesOriginal,
      dataSaver: dataSaver ?? this.dataSaver,
      blockedNodeIds: blockedNodeIds ?? this.blockedNodeIds,
      deletedGroupIds: deletedGroupIds ?? this.deletedGroupIds,
      deletedMessageIds: deletedMessageIds ?? this.deletedMessageIds,
    );
  }
}
