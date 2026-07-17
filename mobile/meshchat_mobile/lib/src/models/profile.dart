class Profile {
  static const String defaultBackground = 'mesh';
  static const String defaultEffect = 'nodes';
  static const String defaultBlinkShape = 'auto';
  static const String defaultAvatarDecoration = 'none';
  static const int defaultAccent = 0xFF42A5F5;

  const Profile({
    required this.nodeId,
    required this.displayName,
    this.accountLogin = '',
    this.nodeAliases = const [],
    this.publicUsername = '',
    this.about = '',
    this.avatarData = '',
    this.publicKey = '',
    this.online = false,
    this.meshProBadge,
    this.profileBackground,
    this.profileEffect,
    this.profileBlinkShape,
    this.avatarDecoration,
    this.profileGlow,
    this.profileAccent,
    this.emojiStatus = '',
  });

  final String nodeId;
  final String displayName;
  final String accountLogin;
  final List<String> nodeAliases;
  final String publicUsername;
  final String about;
  final String avatarData;
  final String publicKey;
  final bool online;
  final bool? meshProBadge;
  final String? profileBackground;
  final String? profileEffect;
  final String? profileBlinkShape;
  final String? avatarDecoration;
  final bool? profileGlow;
  final int? profileAccent;
  final String emojiStatus;

  String get effectiveProfileBackground {
    return normalizeBackground(profileBackground);
  }

  static String normalizeBackground(String? value) {
    return switch (value?.trim().toLowerCase()) {
      'aurora' => 'aurora',
      'starlight' => 'starlight',
      'stardust' => 'stardust',
      'ember' => 'ember',
      'sunset' => 'sunset',
      'frost' => 'frost',
      'orbit' => 'orbit',
      _ => defaultBackground,
    };
  }

  String get effectiveProfileBanner {
    final background = effectiveProfileBackground;
    if ({
      'stardust',
      'ember',
      'sunset',
      'frost',
      'orbit',
    }.contains(background)) {
      return background;
    }
    return switch (effectiveAvatarDecoration) {
      'stardust' => 'stardust',
      'ember' => 'ember',
      'sunset_clouds' => 'sunset',
      'frost_bloom' => 'frost',
      'neon_orbit' => 'orbit',
      _ => background,
    };
  }

  static String legacyCompatibleBackground(String? value) {
    return switch (value?.trim().toLowerCase()) {
      'stardust' || 'orbit' => 'starlight',
      'sunset' || 'frost' => 'aurora',
      'ember' => 'mesh',
      'aurora' => 'aurora',
      'starlight' => 'starlight',
      _ => defaultBackground,
    };
  }

  String get effectiveProfileEffect {
    return normalizeEffect(profileEffect);
  }

  static String normalizeEffect(String? value) {
    return switch (value?.trim().toLowerCase()) {
      'stars' || 'star' || 'sparkle' || 'sparkles' => 'stars',
      'orbit' || 'orbits' => 'orbit',
      _ => defaultEffect,
    };
  }

  String get effectiveProfileBlinkShape {
    return normalizeBlinkShape(
      profileBlinkShape,
      fallback: effectiveProfileEffect == 'stars' ? 'star' : 'dot',
    );
  }

  static String normalizeBlinkShape(String? value, {String fallback = 'dot'}) {
    return switch (value?.trim().toLowerCase()) {
      'dot' || 'point' || 'circle' => 'dot',
      'star' || 'stars' || 'sparkle' || 'sparkles' => 'star',
      'moose' || 'elk' => 'moose',
      'auto' => 'auto',
      _ => fallback,
    };
  }

  String get effectiveAvatarDecoration {
    return normalizeAvatarDecoration(avatarDecoration);
  }

  static String normalizeAvatarDecoration(String? value) {
    return switch (value?.trim().toLowerCase()) {
      'stardust' || 'stars' => 'stardust',
      'ember' || 'ember_flame' || 'flame' || 'fire' => 'ember',
      'sunset' || 'sunset_clouds' || 'clouds' => 'sunset_clouds',
      'orbit' || 'neon_orbit' => 'neon_orbit',
      'frost' || 'frost_bloom' => 'frost_bloom',
      _ => defaultAvatarDecoration,
    };
  }

  String get effectiveAppearancePreset {
    return switch (effectiveAvatarDecoration) {
      'stardust' => 'stardust',
      'ember' => 'ember',
      'sunset_clouds' => 'sunset',
      'frost_bloom' => 'frost',
      'neon_orbit' => 'orbit',
      _ => 'custom',
    };
  }

  String get effectiveNameEffect => effectiveAppearancePreset;

  String get effectiveMessageEffect {
    if (meshProBadge != true) return 'none';
    return switch (effectiveAppearancePreset) {
      'stardust' => 'stardust',
      'ember' => 'ember',
      'sunset' => 'sunset',
      'frost' => 'frost',
      'orbit' => 'orbit',
      _ => 'none',
    };
  }

  bool get effectiveProfileGlow => profileGlow == true;

  int get effectiveProfileAccent => profileAccent ?? defaultAccent;

  Profile copyWith({
    String? nodeId,
    String? displayName,
    String? accountLogin,
    List<String>? nodeAliases,
    String? publicUsername,
    String? about,
    String? avatarData,
    String? publicKey,
    bool? online,
    bool? meshProBadge,
    String? profileBackground,
    String? profileEffect,
    String? profileBlinkShape,
    String? avatarDecoration,
    bool? profileGlow,
    int? profileAccent,
    String? emojiStatus,
  }) {
    return Profile(
      nodeId: nodeId ?? this.nodeId,
      displayName: displayName ?? this.displayName,
      accountLogin: accountLogin ?? this.accountLogin,
      nodeAliases: nodeAliases ?? this.nodeAliases,
      publicUsername: publicUsername ?? this.publicUsername,
      about: about ?? this.about,
      avatarData: avatarData ?? this.avatarData,
      publicKey: publicKey ?? this.publicKey,
      online: online ?? this.online,
      meshProBadge: meshProBadge ?? this.meshProBadge,
      profileBackground: profileBackground ?? this.profileBackground,
      profileEffect: profileEffect ?? this.profileEffect,
      profileBlinkShape: profileBlinkShape ?? this.profileBlinkShape,
      avatarDecoration: avatarDecoration ?? this.avatarDecoration,
      profileGlow: profileGlow ?? this.profileGlow,
      profileAccent: profileAccent ?? this.profileAccent,
      emojiStatus: emojiStatus ?? this.emojiStatus,
    );
  }

  factory Profile.fromJson(Map<String, dynamic> json) {
    return Profile(
      nodeId: json['node_id']?.toString() ?? '',
      displayName:
          json['display_name']?.toString() ??
          json['username']?.toString() ??
          'Пользователь',
      accountLogin:
          json['account_login']?.toString() ?? json['login']?.toString() ?? '',
      nodeAliases: json['node_aliases'] is List
          ? (json['node_aliases'] as List)
                .map((value) => value.toString())
                .where((value) => value.isNotEmpty)
                .toSet()
                .toList()
          : const <String>[],
      publicUsername: json['public_username']?.toString() ?? '',
      about: json['about']?.toString() ?? '',
      avatarData: json['avatar_data']?.toString() ?? '',
      publicKey: json['encryption_public_key']?.toString() ?? '',
      online: json['online'] == true,
      meshProBadge: json.containsKey('meshpro_badge')
          ? json['meshpro_badge'] == true
          : null,
      profileBackground: json.containsKey('profile_background')
          ? json['profile_background']?.toString()
          : null,
      profileEffect: json.containsKey('profile_effect')
          ? json['profile_effect']?.toString()
          : null,
      profileBlinkShape: json.containsKey('profile_blink_shape')
          ? json['profile_blink_shape']?.toString()
          : null,
      avatarDecoration: json.containsKey('avatar_decoration')
          ? json['avatar_decoration']?.toString()
          : null,
      profileGlow: json.containsKey('profile_glow')
          ? json['profile_glow'] == true || json['profile_glow'] == 1
          : null,
      profileAccent: json.containsKey('profile_accent')
          ? int.tryParse(json['profile_accent']?.toString() ?? '')
          : null,
      emojiStatus: json['emoji_status']?.toString() ?? '',
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'node_id': nodeId,
      'display_name': displayName,
      'account_login': accountLogin,
      'node_aliases': nodeAliases,
      'public_username': publicUsername,
      'about': about,
      'avatar_data': avatarData,
      'encryption_public_key': publicKey,
      'online': online,
      if (meshProBadge != null) 'meshpro_badge': meshProBadge,
      if (profileBackground != null) 'profile_background': profileBackground,
      if (profileEffect != null) 'profile_effect': profileEffect,
      if (profileBlinkShape != null) 'profile_blink_shape': profileBlinkShape,
      if (avatarDecoration != null) 'avatar_decoration': avatarDecoration,
      if (profileGlow != null) 'profile_glow': profileGlow,
      if (profileAccent != null) 'profile_accent': profileAccent,
      if (emojiStatus.isNotEmpty) 'emoji_status': emojiStatus,
    };
  }
}
