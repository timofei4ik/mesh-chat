import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/mesh_studio_style.dart';

class MeshStudioCatalogService {
  static const catalogUrl =
      'https://meshchat-losa.ru/downloads/profile-packs/catalog.json';
  static const _cacheKey = 'meshstudio.remote_catalog.v1';
  static Future<void>? _refreshing;

  static Future<void> loadCached() async {
    final preferences = await SharedPreferences.getInstance();
    final cached = preferences.getString(_cacheKey);
    if (cached == null || cached.isEmpty) return;
    _install(cached);
  }

  static Future<void> refresh() {
    return _refreshing ??= _refresh().whenComplete(() => _refreshing = null);
  }

  static Future<void> _refresh() async {
    final uri = Uri.parse(catalogUrl);
    final bundle = NetworkAssetBundle(uri.resolve('./'));
    final body = await bundle
        .loadString(uri.pathSegments.last)
        .timeout(const Duration(seconds: 8));
    _install(body);
    final preferences = await SharedPreferences.getInstance();
    await preferences.setString(_cacheKey, body);
  }

  static void _install(String body) {
    final root = jsonDecode(body);
    if (root is! Map) throw const FormatException('Invalid profile catalog');
    installRemoteMeshStudioCatalog(root.cast<String, dynamic>());
  }
}
