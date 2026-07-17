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
      expect(profile.effectiveMessageEffect, preset.id);
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
}
