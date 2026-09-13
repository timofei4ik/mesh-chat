String configureCallOpusSdp(String sdp, {required bool hd}) {
  if (sdp.isEmpty) return sdp;
  final lines = sdp.split('\r\n');
  final opusPayloads = <String>{};
  final rtpmapIndexes = <String, int>{};
  for (var index = 0; index < lines.length; index++) {
    final match = RegExp(
      r'^a=rtpmap:(\d+) opus/48000',
      caseSensitive: false,
    ).firstMatch(lines[index]);
    if (match == null) continue;
    final payload = match.group(1)!;
    opusPayloads.add(payload);
    rtpmapIndexes[payload] = index;
  }
  if (opusPayloads.isEmpty) return sdp;

  for (final payload in opusPayloads) {
    final prefix = 'a=fmtp:$payload ';
    var fmtpIndex = lines.indexWhere((line) => line.startsWith(prefix));
    if (fmtpIndex < 0) {
      fmtpIndex = (rtpmapIndexes[payload] ?? lines.length - 1) + 1;
      lines.insert(fmtpIndex, '${prefix}minptime=10');
    }
    final existing = lines[fmtpIndex]
        .substring(prefix.length)
        .split(';')
        .map((value) => value.trim())
        .where((value) => value.isNotEmpty)
        .toList();
    final keys = {
      for (final value in existing) value.split('=').first.toLowerCase(),
    };
    final additions = <String>[
      if (!keys.contains('minptime')) 'minptime=10',
      if (!keys.contains('useinbandfec')) 'useinbandfec=1',
      if (!keys.contains('usedtx')) 'usedtx=1',
      if (!keys.contains('stereo')) 'stereo=0',
      if (!keys.contains('sprop-stereo')) 'sprop-stereo=0',
      if (!keys.contains('maxaveragebitrate'))
        'maxaveragebitrate=${hd ? 96000 : 40000}',
    ];
    lines[fmtpIndex] = '$prefix${[...existing, ...additions].join(';')}';
  }
  return lines.join('\r\n');
}

Duration callReconnectDelay(int attempt) {
  if (attempt <= 1) return const Duration(seconds: 1);
  if (attempt == 2) return const Duration(seconds: 3);
  if (attempt == 3) return const Duration(seconds: 7);
  return const Duration(seconds: 10);
}

int recommendedCallBitrateBps({
  required double packetLossPercent,
  required int jitterMs,
  required int roundTripTimeMs,
  required bool hd,
}) {
  if (packetLossPercent >= 12 || jitterMs >= 120 || roundTripTimeMs >= 600) {
    return 20000;
  }
  if (packetLossPercent >= 6 || jitterMs >= 70 || roundTripTimeMs >= 350) {
    return 28000;
  }
  if (packetLossPercent >= 2.5 || jitterMs >= 35 || roundTripTimeMs >= 180) {
    return hd ? 48000 : 32000;
  }
  return hd ? 96000 : 40000;
}
