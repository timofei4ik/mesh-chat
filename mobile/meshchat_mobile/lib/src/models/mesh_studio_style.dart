typedef MeshStudioPreset = ({
  String id,
  String label,
  String collection,
  String background,
  String effect,
  String blink,
  String decoration,
  String messageEffect,
  int accent,
});

typedef MeshStudioCollection = ({
  String id,
  String label,
  String subtitle,
  String? heroAsset,
});

const meshStudioOriginalsCollection = 'mesh_originals';
const meshStudioCampfireCollection = 'campfire_trails';

const _bundledMeshStudioCollections = <MeshStudioCollection>[
  (
    id: meshStudioOriginalsCollection,
    label: 'Mesh Originals',
    subtitle: 'The signature neon collection that started MeshStudio.',
    heroAsset: null,
  ),
  (
    id: meshStudioCampfireCollection,
    label: 'Enchanted Gardens',
    subtitle: 'Five living nocturnal gardens with matching avatar frames.',
    heroAsset:
        'assets/profile_collections/campfire_trails/cloud_camp_banner_static.webp',
  ),
];

final meshStudioCollections = <MeshStudioCollection>[
  ..._bundledMeshStudioCollections,
];

const meshStudioProfileAccents = <int>[
  0xFF42A5F5,
  0xFF3BD6FF,
  0xFFA56BFF,
  0xFF67F3C4,
  0xFFFF6B9C,
  0xFFFFB65C,
];

const _bundledMeshStudioAvatarDecorations = <(String, String)>[
  ('none', 'None'),
  ('stardust', 'Stardust'),
  ('ember', 'Ember'),
  ('sunset_clouds', 'Sunset'),
  ('neon_orbit', 'Orbit'),
  ('frost_bloom', 'Frost'),
  ('camp_clouds', 'Spirit Garden'),
  ('camp_moon', 'Tidal Shrine'),
  ('camp_ember', 'Moonflower'),
  ('camp_stories', 'Sunken Lotus'),
  ('camp_rainlight', 'Rainlight'),
];

const _bundledMeshStudioBackgrounds = <(String, String)>[
  ('nebula', 'Nebula'),
  ('ocean', 'Neon Tide'),
  ('sakura', 'Sakura'),
  ('solar', 'Solar'),
  ('ember', 'Ember'),
  ('sunset', 'Sunset'),
  ('frost', 'Frost'),
  ('orbit', 'Orbit'),
  ('camp_clouds', 'Spirit Garden'),
  ('camp_moon', 'Tidal Shrine'),
  ('camp_ember', 'Moonflower Courtyard'),
  ('camp_stories', 'Sunken Lotus Garden'),
  ('camp_rainlight', 'Rainlight Conservatory'),
];

const _bundledMeshStudioPresets = <MeshStudioPreset>[
  (
    id: 'nebula',
    label: 'Nebula',
    collection: meshStudioOriginalsCollection,
    background: 'nebula',
    effect: 'stars',
    blink: 'star',
    decoration: 'neon_orbit',
    messageEffect: 'orbit',
    accent: 0xFFC46BFF,
  ),
  (
    id: 'tide',
    label: 'Neon Tide',
    collection: meshStudioOriginalsCollection,
    background: 'ocean',
    effect: 'nodes',
    blink: 'dot',
    decoration: 'frost_bloom',
    messageEffect: 'frost',
    accent: 0xFF42E8D1,
  ),
  (
    id: 'sakura',
    label: 'Sakura',
    collection: meshStudioOriginalsCollection,
    background: 'sakura',
    effect: 'stars',
    blink: 'star',
    decoration: 'sunset_clouds',
    messageEffect: 'sunset',
    accent: 0xFFFF79B8,
  ),
  (
    id: 'solar',
    label: 'Solar',
    collection: meshStudioOriginalsCollection,
    background: 'solar',
    effect: 'orbit',
    blink: 'dot',
    decoration: 'ember',
    messageEffect: 'ember',
    accent: 0xFFFFB34D,
  ),
  (
    id: 'stardust',
    label: 'Stardust',
    collection: meshStudioOriginalsCollection,
    background: 'stardust',
    effect: 'stars',
    blink: 'star',
    decoration: 'stardust',
    messageEffect: 'stardust',
    accent: 0xFF75DFFF,
  ),
  (
    id: 'ember',
    label: 'Ember',
    collection: meshStudioOriginalsCollection,
    background: 'ember',
    effect: 'nodes',
    blink: 'dot',
    decoration: 'ember',
    messageEffect: 'ember',
    accent: 0xFFFF7A55,
  ),
  (
    id: 'sunset',
    label: 'Sunset',
    collection: meshStudioOriginalsCollection,
    background: 'sunset',
    effect: 'orbit',
    blink: 'dot',
    decoration: 'sunset_clouds',
    messageEffect: 'sunset',
    accent: 0xFFFF79B0,
  ),
  (
    id: 'frost',
    label: 'Frost',
    collection: meshStudioOriginalsCollection,
    background: 'frost',
    effect: 'stars',
    blink: 'star',
    decoration: 'frost_bloom',
    messageEffect: 'frost',
    accent: 0xFFB9F3FF,
  ),
  (
    id: 'orbit',
    label: 'Orbit',
    collection: meshStudioOriginalsCollection,
    background: 'orbit',
    effect: 'orbit',
    blink: 'dot',
    decoration: 'neon_orbit',
    messageEffect: 'orbit',
    accent: 0xFFA56BFF,
  ),
  (
    id: 'cloud_camp',
    label: 'Spirit Garden',
    collection: meshStudioCampfireCollection,
    background: 'camp_clouds',
    effect: 'stars',
    blink: 'star',
    decoration: 'camp_clouds',
    messageEffect: 'sunset',
    accent: 0xFFFF8FAF,
  ),
  (
    id: 'moon_trail',
    label: 'Tidal Shrine',
    collection: meshStudioCampfireCollection,
    background: 'camp_moon',
    effect: 'orbit',
    blink: 'star',
    decoration: 'camp_moon',
    messageEffect: 'frost',
    accent: 0xFF67DFFF,
  ),
  (
    id: 'ember_night',
    label: 'Moonflower Courtyard',
    collection: meshStudioCampfireCollection,
    background: 'camp_ember',
    effect: 'stars',
    blink: 'star',
    decoration: 'camp_ember',
    messageEffect: 'stardust',
    accent: 0xFFC2D8FF,
  ),
  (
    id: 'story_lanterns',
    label: 'Sunken Lotus Garden',
    collection: meshStudioCampfireCollection,
    background: 'camp_stories',
    effect: 'nodes',
    blink: 'dot',
    decoration: 'camp_stories',
    messageEffect: 'orbit',
    accent: 0xFF9C7BFF,
  ),
  (
    id: 'rainlight',
    label: 'Rainlight Conservatory',
    collection: meshStudioCampfireCollection,
    background: 'camp_rainlight',
    effect: 'nodes',
    blink: 'dot',
    decoration: 'camp_rainlight',
    messageEffect: 'frost',
    accent: 0xFF50D9FF,
  ),
];

final meshStudioAvatarDecorations = <(String, String)>[
  ..._bundledMeshStudioAvatarDecorations,
];
final meshStudioBackgrounds = <(String, String)>[
  ..._bundledMeshStudioBackgrounds,
];
final meshStudioPresets = <MeshStudioPreset>[..._bundledMeshStudioPresets];

final Map<String, String> _remoteBannerAssets = {};
final Map<String, String> _remoteStaticBannerAssets = {};
final Map<String, String> _remoteAnimatedDecorationAssets = {};
final Map<String, String> _remoteStaticDecorationAssets = {};
final Map<String, double> _remoteDecorationScales = {};
void installRemoteMeshStudioCatalog(Map<String, dynamic> root) {
  final rawPacks = root['packs'];
  if (rawPacks is! List) return;

  final collections = <MeshStudioCollection>[];
  final presets = <MeshStudioPreset>[];
  final backgrounds = <(String, String)>[];
  final decorations = <(String, String)>[];
  final bannerAssets = <String, String>{};
  final staticBannerAssets = <String, String>{};
  final animatedDecorationAssets = <String, String>{};
  final staticDecorationAssets = <String, String>{};
  final decorationScales = <String, double>{};
  final styleIds = <String>{};

  for (final rawPack in rawPacks.whereType<Map>()) {
    final pack = rawPack.cast<String, dynamic>();
    final collectionId = _catalogId(pack['id']);
    final label = _catalogText(pack['name']);
    final rawPresets = pack['presets'];
    if (collectionId == null ||
        label == null ||
        rawPresets is! List ||
        rawPresets.isEmpty) {
      continue;
    }

    final packPresets = <MeshStudioPreset>[];
    for (final rawPreset in rawPresets.whereType<Map>()) {
      final item = rawPreset.cast<String, dynamic>();
      final presetId = _catalogId(item['id']);
      final presetLabel = _catalogText(item['name']);
      final styleId = _catalogStyleId(item['styleId']);
      final bannerUrl = _catalogHttpsUrl(item['bannerUrl']);
      final frameUrl = _catalogHttpsUrl(item['frameUrl']);
      if (presetId == null ||
          presetLabel == null ||
          styleId == null ||
          bannerUrl == null ||
          frameUrl == null) {
        continue;
      }

      final effect = _catalogEnum(item['effect'], const {
        'stars',
        'nodes',
        'orbit',
      }, 'stars');
      final blink = _catalogEnum(item['blink'], const {
        'dot',
        'star',
        'moose',
      }, 'star');
      final messageEffect = _catalogEnum(item['messageEffect'], const {
        'stardust',
        'ember',
        'sunset',
        'frost',
        'orbit',
      }, 'stardust');
      final accent = _catalogAccent(item['accent']);

      packPresets.add((
        id: presetId,
        label: presetLabel,
        collection: collectionId,
        background: styleId,
        effect: effect,
        blink: blink,
        decoration: styleId,
        messageEffect: messageEffect,
        accent: accent,
      ));
      backgrounds.add((styleId, presetLabel));
      decorations.add((styleId, presetLabel));
      styleIds.add(styleId);
      bannerAssets[styleId] = bannerUrl;
      staticBannerAssets[styleId] =
          _catalogHttpsUrl(item['previewUrl']) ?? bannerUrl;
      animatedDecorationAssets[styleId] = frameUrl;
      staticDecorationAssets[styleId] =
          _catalogHttpsUrl(item['framePreviewUrl']) ?? frameUrl;
      decorationScales[styleId] =
          (item['avatarScale'] as num?)?.toDouble().clamp(0.5, 0.9) ?? 0.68;
    }
    if (packPresets.isEmpty) continue;

    presets.addAll(packPresets);
    collections.add((
      id: collectionId,
      label: label,
      subtitle: _catalogText(pack['description']) ?? 'Downloaded from MeshHub.',
      heroAsset:
          _catalogHttpsUrl(pack['heroUrl']) ??
          staticBannerAssets[packPresets.first.background],
    ));
  }
  if (collections.isEmpty) return;

  final replacedCollections = collections.map((item) => item.id).toSet();
  meshStudioCollections
    ..removeWhere((item) => replacedCollections.contains(item.id))
    ..addAll(collections);
  meshStudioPresets
    ..removeWhere((item) => replacedCollections.contains(item.collection))
    ..addAll(presets);
  meshStudioBackgrounds
    ..removeWhere((item) => styleIds.contains(item.$1))
    ..addAll(backgrounds);
  meshStudioAvatarDecorations
    ..removeWhere((item) => styleIds.contains(item.$1))
    ..addAll(decorations);
  _remoteBannerAssets
    ..clear()
    ..addAll(bannerAssets);
  _remoteStaticBannerAssets
    ..clear()
    ..addAll(staticBannerAssets);
  _remoteAnimatedDecorationAssets
    ..clear()
    ..addAll(animatedDecorationAssets);
  _remoteStaticDecorationAssets
    ..clear()
    ..addAll(staticDecorationAssets);
  _remoteDecorationScales
    ..clear()
    ..addAll(decorationScales);
}

String? _catalogId(Object? value) {
  final text = value?.toString().trim().toLowerCase() ?? '';
  return RegExp(r'^[a-z][a-z0-9_]{1,47}$').hasMatch(text) ? text : null;
}

String? _catalogStyleId(Object? value) {
  final text = _catalogId(value);
  if (text == null) return null;
  if (text.startsWith('camp_') || text.startsWith('remote_')) return text;
  return null;
}

String? _catalogText(Object? value) {
  final text = value?.toString().trim() ?? '';
  if (text.isEmpty) return null;
  return text.length <= 96 ? text : text.substring(0, 96);
}

String? _catalogHttpsUrl(Object? value) {
  final uri = Uri.tryParse(value?.toString().trim() ?? '');
  return uri != null && uri.scheme == 'https' && uri.host.isNotEmpty
      ? uri.toString()
      : null;
}

String _catalogEnum(Object? value, Set<String> allowed, String fallback) {
  final normalized = value?.toString().trim().toLowerCase();
  return allowed.contains(normalized) ? normalized! : fallback;
}

int _catalogAccent(Object? value) {
  if (value is num) return 0xFF000000 | (value.toInt() & 0x00FFFFFF);
  final text = value?.toString().replaceFirst('#', '').trim() ?? '';
  final parsed = int.tryParse(text, radix: 16);
  return parsed == null ? 0xFF75DFFF : 0xFF000000 | (parsed & 0x00FFFFFF);
}

List<MeshStudioPreset> meshStudioPresetsForCollection(String collectionId) {
  return meshStudioPresets
      .where((preset) => preset.collection == collectionId)
      .toList(growable: false);
}

List<(String, String)> meshStudioBackgroundsForCollection(String collectionId) {
  final allowed = meshStudioPresetsForCollection(
    collectionId,
  ).map((preset) => preset.background).toSet();
  return meshStudioBackgrounds
      .where((option) => allowed.contains(option.$1))
      .toList(growable: false);
}

List<(String, String)> meshStudioDecorationsForCollection(String collectionId) {
  final allowed = meshStudioPresetsForCollection(
    collectionId,
  ).map((preset) => preset.decoration).toSet();
  return meshStudioAvatarDecorations
      .where(
        (option) =>
            allowed.contains(option.$1) ||
            (collectionId == meshStudioOriginalsCollection &&
                option.$1 == 'none'),
      )
      .toList(growable: false);
}

String meshStudioCollectionForStyle({
  required String background,
  required String decoration,
}) {
  for (final preset in meshStudioPresets) {
    if (preset.background == background || preset.decoration == decoration) {
      return preset.collection;
    }
  }
  return meshStudioOriginalsCollection;
}

String? meshStudioBannerAsset(String background) {
  final remote = _remoteBannerAssets[background];
  if (remote != null) return remote;
  return meshStudioBundledBannerAsset(background);
}

String? meshStudioStaticBannerAsset(String background) {
  final remote = _remoteStaticBannerAssets[background];
  if (remote != null) return remote;
  final bundled = meshStudioBundledBannerAsset(background);
  return bundled?.replaceFirst('_banner.webp', '_banner_static.webp');
}

String? meshStudioBundledBannerAsset(String background) {
  return switch (background) {
    'camp_clouds' =>
      'assets/profile_collections/campfire_trails/cloud_camp_banner.webp',
    'camp_moon' =>
      'assets/profile_collections/campfire_trails/moon_trail_banner.webp',
    'camp_ember' =>
      'assets/profile_collections/campfire_trails/ember_night_banner.webp',
    'camp_stories' =>
      'assets/profile_collections/campfire_trails/story_lanterns_banner.webp',
    'camp_rainlight' =>
      'assets/profile_collections/campfire_trails/rainlight_banner.webp',
    _ => null,
  };
}

String? meshStudioDecorationAsset(String decoration, {required bool animated}) {
  final remote = animated
      ? _remoteAnimatedDecorationAssets[decoration]
      : _remoteStaticDecorationAssets[decoration];
  if (remote != null) return remote;
  return meshStudioBundledDecorationAsset(decoration, animated: animated);
}

String? meshStudioBundledDecorationAsset(
  String decoration, {
  required bool animated,
}) {
  final suffix = animated ? 'webp' : 'png';
  return switch (decoration) {
    'camp_clouds' =>
      'assets/profile_collections/campfire_trails/cloud_camp_frame.$suffix',
    'camp_moon' =>
      'assets/profile_collections/campfire_trails/moon_trail_frame.$suffix',
    'camp_ember' =>
      'assets/profile_collections/campfire_trails/ember_night_frame.$suffix',
    'camp_stories' =>
      'assets/profile_collections/campfire_trails/story_lanterns_frame.$suffix',
    'camp_rainlight' =>
      'assets/profile_collections/campfire_trails/rainlight_frame.$suffix',
    _ => null,
  };
}

double meshStudioDecorationAvatarScale(String decoration) {
  final remote = _remoteDecorationScales[decoration];
  if (remote != null) return remote;
  return switch (decoration) {
    'camp_clouds' ||
    'camp_moon' ||
    'camp_ember' ||
    'camp_stories' ||
    'camp_rainlight' => 0.70,
    _ => 0.79,
  };
}

double meshStudioDecorationFrameScale(String decoration) {
  return switch (decoration) {
    'camp_clouds' ||
    'camp_moon' ||
    'camp_ember' ||
    'camp_stories' ||
    'camp_rainlight' => 0.92,
    _ => 1,
  };
}

({double x, double y}) meshStudioDecorationFrameOffset(String decoration) {
  return switch (decoration) {
    'camp_clouds' ||
    'camp_moon' ||
    'camp_ember' ||
    'camp_stories' ||
    'camp_rainlight' => (x: 0, y: 0),
    _ => (x: 0, y: 0),
  };
}

String matchingMeshStudioPreset({
  required String background,
  required String effect,
  required String blink,
  required String decoration,
  required int accent,
}) {
  for (final preset in meshStudioPresets) {
    if (background == preset.background &&
        effect == preset.effect &&
        blink == preset.blink &&
        decoration == preset.decoration &&
        accent == preset.accent) {
      return preset.id;
    }
  }
  return 'custom';
}

String? meshStudioAppearanceEffectForStyle(String styleId) {
  for (final preset in meshStudioPresets) {
    if (preset.background == styleId || preset.decoration == styleId) {
      return preset.messageEffect;
    }
  }
  return null;
}
