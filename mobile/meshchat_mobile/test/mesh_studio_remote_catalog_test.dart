import 'package:flutter_test/flutter_test.dart';
import 'package:meshchat_mobile/src/models/mesh_studio_style.dart';
import 'package:meshchat_mobile/src/models/profile.dart';

void main() {
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
