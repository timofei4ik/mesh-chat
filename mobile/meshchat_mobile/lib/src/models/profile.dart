class Profile {
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
    };
  }
}
