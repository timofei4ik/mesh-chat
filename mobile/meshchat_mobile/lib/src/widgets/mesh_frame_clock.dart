import 'dart:async';

import 'package:flutter/foundation.dart';

/// A low-frequency animation clock for slow decorative effects.
///
/// Unlike an AnimationController, this does not request a frame on every
/// display refresh. Elapsed time still comes from a Stopwatch, so motion stays
/// stable when timer callbacks are delayed.
class MeshFrameClock extends ChangeNotifier {
  MeshFrameClock({
    required this.duration,
    this.frameInterval = const Duration(milliseconds: 66),
    double value = 0,
  }) : value = value.clamp(0.0, 1.0);

  final Duration duration;
  final Duration frameInterval;

  final Stopwatch _stopwatch = Stopwatch();
  Timer? _timer;
  double _startValue = 0;
  bool _repeating = false;

  double value;

  bool get isAnimating => _timer != null;

  void repeat() {
    _start(repeating: true, from: value >= 1 ? 0 : value);
  }

  void forward({double? from}) {
    _start(repeating: false, from: from ?? value);
  }

  void stop({bool canceled = true}) {
    _timer?.cancel();
    _timer = null;
    _stopwatch.stop();
  }

  void _start({required bool repeating, required double from}) {
    stop(canceled: false);
    _repeating = repeating;
    _startValue = from.clamp(0.0, 1.0);
    value = _startValue;
    _stopwatch
      ..reset()
      ..start();
    _timer = Timer.periodic(frameInterval, (_) => _tick());
    notifyListeners();
  }

  void _tick() {
    final durationMicros = duration.inMicroseconds;
    if (durationMicros <= 0) {
      value = 1;
      stop(canceled: false);
      notifyListeners();
      return;
    }

    final elapsed = _stopwatch.elapsedMicroseconds / durationMicros;
    final rawValue = _startValue + elapsed;
    if (_repeating) {
      value = rawValue % 1;
    } else if (rawValue >= 1) {
      value = 1;
      stop(canceled: false);
    } else {
      value = rawValue;
    }
    notifyListeners();
  }

  @override
  void dispose() {
    stop(canceled: false);
    super.dispose();
  }
}
