import 'package:flutter_test/flutter_test.dart';
import 'package:meshchat_mobile/src/models/mesh_studio_style.dart';
import 'package:meshchat_mobile/src/models/profile.dart';

void main() {
  test('Moonlit Trails uses matching frame geometry after catalog refresh', () {
    const matches = {
      'remote_ember_vale': 'camp_clouds',
      'remote_moonlit_path': 'camp_moon',
      'remote_skybound_camp': 'camp_ember',
      'remote_lantern_stories': 'camp_stories',
    };
    addTearDown(() => installRemoteMeshStudioCatalog({'packs': []}));
    installRemoteMeshStudioCatalog({
      'packs': [
        {
          'id': 'moonlit_trails',
          'name': 'Moonlit Trails',
          'presets': [
            for (final id in matches.keys)
              {
                'id': id,
                'name': id,
                'styleId': id,
                'avatarScale': 0.68,
                'bannerUrl': 'https://example.com/$id-banner.webp',
                'previewUrl': 'https://example.com/$id-preview.webp',
                'frameUrl': 'https://example.com/$id-frame.webp',
                'framePreviewUrl': 'https://example.com/$id-frame.png',
              },
          ],
        },
      ],
    });
    for (final entry in matches.entries) {
      expect(
        meshStudioDecorationAsset(entry.key, animated: true),
        'https://example.com/${entry.key}-frame.webp',
      );
      expect(
        meshStudioDecorationAvatarScale(entry.key),
        meshStudioDecorationAvatarScale(entry.value),
      );
      expect(
        meshStudioDecorationFrameScale(entry.key),
        meshStudioDecorationFrameScale(entry.value),
      );
    }
  });
  test('catalog cannot replace calibrated bundled frame geometry', () {
    final before = meshStudioDecorationAvatarScale('camp_clouds');
    installRemoteMeshStudioCatalog({
      'packs': [
        {
          'id': 'campfire_trails',
          'name': 'Enchanted Gardens',
          'presets': [
            {
              'id': 'cloud_camp',
              'name': 'Spirit Garden',
              'styleId': 'camp_clouds',
              'avatarScale': 0.68,
              'bannerUrl': 'https://example.com/banner.webp',
              'previewUrl': 'https://example.com/preview.webp',
              'frameUrl': 'https://example.com/frame.webp',
              'framePreviewUrl': 'https://example.com/frame.png',
            },
          ],
        },
      ],
    });
    expect(
      meshStudioDecorationAsset('camp_clouds', animated: true),
      'https://example.com/frame.webp',
    );
    expect(meshStudioDecorationAvatarScale('camp_clouds'), before);
    installRemoteMeshStudioCatalog({'packs': []});
  });
  test('remote profile packs extend MeshStudio without bundled assets', () {
    installRemoteMeshStudioCatalog({
      'packs': [
        {
          'id': 'remote_test_collection',
          'name': 'Remote Test',
          'description': 'Loaded from a server catalog.',
          'heroUrl': 'https://example.com/preview.webp',
          'presets': [
            {
              'id': 'remote_test_preset',
              'name': 'Crystal Garden',
              'styleId': 'remote_crystal_garden',
              'effect': 'orbit',
              'blink': 'star',
              'messageEffect': 'frost',
              'accent': '#66CCFF',
              'avatarScale': 0.7,
              'bannerUrl': 'https://example.com/banner.webp',
              'previewUrl': 'https://example.com/preview.webp',
              'frameUrl': 'https://example.com/frame.webp',
              'framePreviewUrl': 'https://example.com/frame.png',
            },
          ],
        },
      ],
    });

    final presets = meshStudioPresetsForCollection('remote_test_collection');
    expect(presets, hasLength(1));
    expect(presets.single.background, 'remote_crystal_garden');
    expect(
      meshStudioBannerAsset('remote_crystal_garden'),
      'https://example.com/banner.webp',
    );
    expect(
      meshStudioDecorationAsset('remote_crystal_garden', animated: true),
      'https://example.com/frame.webp',
    );
    expect(
      Profile.normalizeBackground('remote_crystal_garden'),
      'remote_crystal_garden',
    );
    expect(
      Profile.normalizeAvatarDecoration('remote_crystal_garden'),
      'remote_crystal_garden',
    );
    expect(Profile.normalizeBackground('remote_../invalid'), 'mesh');
  });
}
