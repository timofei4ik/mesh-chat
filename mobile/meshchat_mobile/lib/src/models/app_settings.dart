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
    this.reducedAnimations = false,
    this.messageEffectsEnabled = true,
    this.showOnline = true,
    this.showAvatar = true,
    this.showAbout = true,
    this.allowCalls = true,
    this.allowGroupInvites = true,
    this.quickReactions = const [
      '\u2764\uFE0F',
      '\u{1F44C}',
      '\u{1FACE}',
      '\u{1F44D}',
    ],
    this.meshProHdAudio = true,
    this.meshProEnhancedNoiseSuppression = true,
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
  final bool reducedAnimations;
  final bool messageEffectsEnabled;
  final bool showOnline;
  final bool showAvatar;
  final bool showAbout;
  final bool allowCalls;
  final bool allowGroupInvites;
  final List<String> quickReactions;
  final bool meshProHdAudio;
  final bool meshProEnhancedNoiseSuppression;
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
    bool? reducedAnimations,
    bool? messageEffectsEnabled,
    bool? showOnline,
    bool? showAvatar,
    bool? showAbout,
    bool? allowCalls,
    bool? allowGroupInvites,
    List<String>? quickReactions,
    bool? meshProHdAudio,
    bool? meshProEnhancedNoiseSuppression,
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
      reducedAnimations: reducedAnimations ?? this.reducedAnimations,
      messageEffectsEnabled:
          messageEffectsEnabled ?? this.messageEffectsEnabled,
      showOnline: showOnline ?? this.showOnline,
      showAvatar: showAvatar ?? this.showAvatar,
      showAbout: showAbout ?? this.showAbout,
      allowCalls: allowCalls ?? this.allowCalls,
      allowGroupInvites: allowGroupInvites ?? this.allowGroupInvites,
      quickReactions: quickReactions ?? this.quickReactions,
      meshProHdAudio: meshProHdAudio ?? this.meshProHdAudio,
      meshProEnhancedNoiseSuppression:
          meshProEnhancedNoiseSuppression ??
          this.meshProEnhancedNoiseSuppression,
      blockedNodeIds: blockedNodeIds ?? this.blockedNodeIds,
      deletedGroupIds: deletedGroupIds ?? this.deletedGroupIds,
      deletedMessageIds: deletedMessageIds ?? this.deletedMessageIds,
    );
  }
}
