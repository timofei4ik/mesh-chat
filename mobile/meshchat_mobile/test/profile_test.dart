import 'package:flutter_test/flutter_test.dart';
import 'package:meshchat_mobile/src/models/profile.dart';

void main() {
  test('legacy blink shape names normalize before upload', () {
    expect(Profile.normalizeBlinkShape('sparkles'), 'star');
    expect(Profile.normalizeBlinkShape('circle'), 'dot');
    expect(Profile.normalizeBlinkShape('elk'), 'moose');
    expect(Profile.normalizeBlinkShape('unexpected'), 'dot');
    expect(Profile.normalizeBackground('unexpected'), 'mesh');
    expect(Profile.normalizeEffect('sparkles'), 'stars');
    expect(Profile.normalizeAvatarDecoration('ember_flame'), 'ember');
    expect(Profile.normalizeAvatarDecoration('unexpected'), 'none');
  });

  test('parses and caches a server-confirmed MeshPro badge', () {
    final profile = Profile.fromJson({
      'node_id': 'node-a',
      'display_name': 'Subscriber',
      'meshpro_badge': true,
    });

    expect(profile.meshProBadge, isTrue);
    expect(profile.toJson()['meshpro_badge'], isTrue);
  });

  test('missing badge field preserves backward compatibility', () {
    final legacy = Profile.fromJson({
      'node_id': 'node-a',
      'display_name': 'Legacy user',
    });
    final cached = const Profile(
      nodeId: 'node-a',
      displayName: 'Cached user',
      meshProBadge: true,
    );

    expect(legacy.meshProBadge, isNull);
    expect(legacy.toJson().containsKey('meshpro_badge'), isFalse);
    expect(
      legacy.copyWith(meshProBadge: cached.meshProBadge).meshProBadge,
      isTrue,
    );
  });

  test('server can explicitly remove an expired badge', () {
    final profile = Profile.fromJson({
      'node_id': 'node-a',
      'display_name': 'Former subscriber',
      'meshpro_badge': false,
    });

    expect(profile.meshProBadge, isFalse);
    expect(profile.toJson()['meshpro_badge'], isFalse);
  });

  test('round-trips server-confirmed MeshPro profile styling', () {
    final profile = Profile.fromJson({
      'node_id': 'node-a',
      'display_name': 'Styled user',
      'profile_background': 'starlight',
      'profile_effect': 'stars',
      'profile_blink_shape': 'moose',
      'avatar_decoration': 'sunset_clouds',
      'profile_glow': true,
      'profile_accent': 0xFFA56BFF,
      'emoji_status': '✨',
    });

    expect(profile.effectiveProfileBackground, 'starlight');
    expect(profile.effectiveProfileEffect, 'stars');
    expect(profile.effectiveProfileBlinkShape, 'moose');
    expect(profile.effectiveAvatarDecoration, 'sunset_clouds');
    expect(profile.effectiveProfileGlow, isTrue);
    expect(profile.effectiveProfileAccent, 0xFFA56BFF);
    expect(profile.toJson()['profile_background'], 'starlight');
    expect(profile.toJson()['profile_effect'], 'stars');
    expect(profile.toJson()['profile_blink_shape'], 'moose');
    expect(profile.toJson()['avatar_decoration'], 'sunset_clouds');
    expect(profile.toJson()['profile_glow'], isTrue);
    expect(profile.toJson()['profile_accent'], 0xFFA56BFF);
    expect(profile.emojiStatus, '✨');
    expect(profile.toJson()['emoji_status'], '✨');
  });

  test('legacy or invalid profile styling falls back safely', () {
    final legacy = Profile.fromJson({
      'node_id': 'node-a',
      'display_name': 'Legacy user',
    });
    final invalid = Profile.fromJson({
      'node_id': 'node-b',
      'display_name': 'Invalid style',
      'profile_background': 'unknown',
      'profile_effect': 'fireworks',
      'avatar_decoration': 'copied_discord_asset',
    });

    expect(legacy.effectiveProfileBackground, Profile.defaultBackground);
    expect(legacy.effectiveProfileEffect, Profile.defaultEffect);
    expect(legacy.effectiveProfileBlinkShape, 'dot');
    expect(legacy.effectiveAvatarDecoration, Profile.defaultAvatarDecoration);
    expect(legacy.effectiveProfileGlow, isFalse);
    expect(legacy.effectiveProfileAccent, Profile.defaultAccent);
    expect(invalid.effectiveProfileBackground, Profile.defaultBackground);
    expect(invalid.effectiveProfileEffect, Profile.defaultEffect);
    expect(invalid.effectiveProfileBlinkShape, 'dot');
    expect(invalid.effectiveAvatarDecoration, Profile.defaultAvatarDecoration);
  });

  test('legacy star profiles preserve their original sparkle shape', () {
    final profile = Profile.fromJson({
      'node_id': 'node-c',
      'display_name': 'Legacy stars',
      'profile_effect': 'stars',
    });

    expect(profile.effectiveProfileBlinkShape, 'star');
  });

  test('linked MeshPro appearance derives name and message effects', () {
    const profile = Profile(
      nodeId: 'node-premium',
      displayName: 'Premium user',
      meshProBadge: true,
      profileBackground: 'sunset',
      avatarDecoration: 'sunset_clouds',
    );

    expect(profile.effectiveProfileBackground, 'sunset');
    expect(profile.effectiveAppearancePreset, 'sunset');
    expect(profile.effectiveNameEffect, 'sunset');
    expect(profile.effectiveMessageEffect, 'sunset');
    expect(
      profile.copyWith(meshProBadge: false).effectiveMessageEffect,
      'none',
    );
  });

  test('linked presets survive a legacy server background fallback', () {
    const profile = Profile(
      nodeId: 'node-legacy-server',
      displayName: 'Premium user',
      meshProBadge: true,
      profileBackground: 'mesh',
      avatarDecoration: 'ember',
    );

    expect(Profile.legacyCompatibleBackground('ember'), 'mesh');
    expect(Profile.legacyCompatibleBackground('frost'), 'aurora');
    expect(profile.effectiveProfileBackground, 'mesh');
    expect(profile.effectiveProfileBanner, 'ember');
    expect(profile.effectiveAppearancePreset, 'ember');
  });
}
