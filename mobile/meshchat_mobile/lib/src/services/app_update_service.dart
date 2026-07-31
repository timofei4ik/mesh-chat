import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:package_info_plus/package_info_plus.dart';

class MeshChatUpdateInfo {
  const MeshChatUpdateInfo({required this.version, required this.build});

  final String version;
  final int build;
}

class AppUpdateService {
  static const catalogUrl = 'https://meshchat-losa.ru/downloads/apps.json';

  Future<MeshChatUpdateInfo?> check() async {
    final package = await PackageInfo.fromPlatform();
    final uri = Uri.parse(catalogUrl);
    final bundle = NetworkAssetBundle(uri.resolve('./'));
    final body = await bundle
        .loadString(uri.pathSegments.last)
        .timeout(const Duration(seconds: 8));
    return updateFromCatalog(
      body,
      currentVersion: package.version,
      currentBuild: int.tryParse(package.buildNumber) ?? 0,
    );
  }

  static MeshChatUpdateInfo? updateFromCatalog(
    String body, {
    required String currentVersion,
    required int currentBuild,
  }) {
    final root = jsonDecode(body);
    if (root is! Map || root['apps'] is! List) return null;
    for (final raw in root['apps'] as List) {
      if (raw is! Map || raw['id'] != 'meshchat') continue;
      final version = raw['version']?.toString().trim() ?? '';
      final build = int.tryParse(raw['build']?.toString() ?? '') ?? 0;
      if (build > currentBuild ||
          (build == 0 && compareVersions(version, currentVersion) > 0)) {
        return MeshChatUpdateInfo(version: version, build: build);
      }
      return null;
    }
    return null;
  }

  static int compareVersions(String left, String right) {
    final a = _versionParts(left);
    final b = _versionParts(right);
    final length = a.length > b.length ? a.length : b.length;
    for (var index = 0; index < length; index++) {
      final av = index < a.length ? a[index] : 0;
      final bv = index < b.length ? b[index] : 0;
      if (av != bv) return av.compareTo(bv);
    }
    return 0;
  }

  static List<int> _versionParts(String value) {
    return value
        .split(RegExp(r'[^0-9]+'))
        .where((part) => part.isNotEmpty)
        .map((part) => int.tryParse(part) ?? 0)
        .toList(growable: false);
  }
}
