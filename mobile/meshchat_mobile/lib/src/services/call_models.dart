enum CallConnectionPhase {
  newConnection,
  connecting,
  connected,
  disconnected,
  failed,
  closed,
}

class CallQualitySnapshot {
  const CallQualitySnapshot({
    this.roundTripTimeMs = 0,
    this.jitterMs = 0,
    this.packetLossPercent = 0,
    this.route = 'unknown',
  });

  final int roundTripTimeMs;
  final int jitterMs;
  final double packetLossPercent;
  final String route;

  int get qualityLevel {
    if (route == 'unknown') return 0;
    if (packetLossPercent >= 8 || roundTripTimeMs >= 450 || jitterMs >= 90) {
      return 1;
    }
    if (packetLossPercent >= 3 || roundTripTimeMs >= 220 || jitterMs >= 45) {
      return 2;
    }
    return 3;
  }
}
