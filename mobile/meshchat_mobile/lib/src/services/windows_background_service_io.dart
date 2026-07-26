import 'dart:io';

import 'package:flutter/services.dart';

class WindowsBackgroundService {
  static const _channel = MethodChannel('meshchat/window');

  Future<void> setCloseToTray(bool enabled) async {
    if (!Platform.isWindows) return;
    await _channel.invokeMethod<void>('setCloseToTray', enabled);
  }

  Future<bool> setLaunchAtStartup(bool enabled) async {
    if (!Platform.isWindows) return false;
    return await _channel.invokeMethod<bool>('setLaunchAtStartup', enabled) ??
        false;
  }
}
