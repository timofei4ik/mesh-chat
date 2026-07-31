import 'package:flutter_test/flutter_test.dart';
import 'package:meshchat_mobile/src/models/mesh_studio_style.dart';
import 'package:meshchat_mobile/src/models/profile.dart';

void main() {
  test('MeshStudio presets map to valid synchronized profile values', () {
    final ids = <String>{};

    for (final preset in meshStudioPresets) {
      expect(ids.add(preset.id), isTrue, reason: 'Preset IDs must be unique');
      final profile = Profile(
        nodeId: 'studio-user',
        displayName: 'Studio user',
        meshProBadge: true,
        profileBackground: preset.background,
        profileEffect: preset.effect,
        profileBlinkShape: preset.blink,
        avatarDecoration: preset.decoration,
        profileGlow: true,
        profileAccent: preset.accent,
      );

      expect(profile.effectiveProfileBanner, preset.background);
      expect(profile.effectiveProfileEffect, preset.effect);
      expect(profile.effectiveProfileBlinkShape, preset.blink);
      expect(profile.effectiveAvatarDecoration, preset.decoration);
      expect(profile.effectiveMessageEffect, preset.messageEffect);
      expect(
        matchingMeshStudioPreset(
          background: profile.effectiveProfileBanner,
          effect: profile.effectiveProfileEffect,
          blink: profile.effectiveProfileBlinkShape,
          decoration: profile.effectiveAvatarDecoration,
          accent: profile.effectiveProfileAccent,
        ),
        preset.id,
      );
    }
  });

  test('independent changes are reported as a custom style', () {
    expect(
      matchingMeshStudioPreset(
        background: 'mesh',
        effect: 'orbit',
        blink: 'moose',
        decoration: 'none',
        accent: Profile.defaultAccent,
      ),
      'custom',
    );
  });

  test('every MeshStudio collection has isolated presets and controls', () {
    final presetIds = <String>{};
    for (final collection in meshStudioCollections) {
      final presets = meshStudioPresetsForCollection(collection.id);
      expect(presets, isNotEmpty, reason: '${collection.label} is empty');
      expect(
        meshStudioBackgroundsForCollection(collection.id),
        isNotEmpty,
        reason: '${collection.label} has no backgrounds',
      );
      expect(
        meshStudioDecorationsForCollection(collection.id),
        isNotEmpty,
        reason: '${collection.label} has no avatar decorations',
      );
      for (final preset in presets) {
        expect(preset.collection, collection.id);
        expect(
          presetIds.add(preset.id),
          isTrue,
          reason: 'Preset ${preset.id} appears in multiple collections',
        );
      }
    }
  });

  test('Enchanted Gardens presets resolve to generated raster assets', () {
    final presets = meshStudioPresetsForCollection(
      meshStudioCampfireCollection,
    );
    for (final preset in presets) {
      expect(meshStudioBannerAsset(preset.background), isNotNull);
      expect(
        meshStudioDecorationAsset(preset.decoration, animated: false),
        endsWith('.png'),
      );
      expect(
        meshStudioDecorationAsset(preset.decoration, animated: true),
        endsWith('.webp'),
      );
    }
    expect(presets, hasLength(5));
  });
}
