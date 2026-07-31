import 'package:flutter/widgets.dart';

class MeshPerformanceScope extends InheritedWidget {
  const MeshPerformanceScope({
    super.key,
    required this.lowEndDeviceMode,
    required super.child,
  });

  final bool lowEndDeviceMode;

  static bool lowEndDeviceModeOf(BuildContext context) {
    return context
            .dependOnInheritedWidgetOfExactType<MeshPerformanceScope>()
            ?.lowEndDeviceMode ??
        false;
  }

  @override
  bool updateShouldNotify(MeshPerformanceScope oldWidget) {
    return oldWidget.lowEndDeviceMode != lowEndDeviceMode;
  }
}
