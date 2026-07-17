enum StoryVisibility { everyone, chats, selected, excluded }

enum StoryMediaType { none, image, video }

class StoryItem {
  const StoryItem({
    required this.id,
    required this.ownerNode,
    required this.ownerName,
    required this.createdAt,
    this.ownerAvatarData = '',
    this.text = '',
    this.imageData = '',
    this.videoData = '',
    this.videoMime = 'video/mp4',
    this.mediaType = StoryMediaType.none,
    this.reactions = const {},
    this.likedByNodeIds = const [],
    this.viewedByNodeIds = const [],
    this.visibility = StoryVisibility.everyone,
    this.allowedNodeIds = const [],
    this.excludedNodeIds = const [],
    this.hd = false,
    this.videoDurationSeconds = 0,
  });

  final String id;
  final String ownerNode;
  final String ownerName;
  final String ownerAvatarData;
  final DateTime createdAt;
  final String text;
  final String imageData;
  final String videoData;
  final String videoMime;
  final StoryMediaType mediaType;
  final Map<String, List<String>> reactions;
  final List<String> likedByNodeIds;
  final List<String> viewedByNodeIds;
  final StoryVisibility visibility;
  final List<String> allowedNodeIds;
  final List<String> excludedNodeIds;
  final bool hd;
  final int videoDurationSeconds;

  int get reactionCount => reactions.values.fold<int>(
    0,
    (total, reactors) => total + reactors.length,
  );

  String reactionFor(String nodeId) {
    for (final entry in reactions.entries) {
      if (entry.value.contains(nodeId)) return entry.key;
    }
    return '';
  }

  bool get expired =>
      DateTime.now().toUtc().difference(createdAt.toUtc()) >=
      const Duration(hours: 24);

  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'owner_node': ownerNode,
      'owner_name': ownerName,
      'owner_avatar_data': ownerAvatarData,
      'created_at': createdAt.toUtc().toIso8601String(),
      'text': text,
      'image_data': imageData,
      'video_data': videoData,
      'video_mime': videoMime,
      'media_type': mediaType.name,
      'reactions': reactions,
      'liked_by_node_ids': likedByNodeIds,
      'viewed_by_node_ids': viewedByNodeIds,
      'visibility': visibility.name,
      'allowed_node_ids': allowedNodeIds,
      'excluded_node_ids': excludedNodeIds,
      'hd': hd,
      'video_duration_seconds': videoDurationSeconds,
    };
  }

  factory StoryItem.fromJson(Map<String, dynamic> json) {
    final reactions = _reactions(json['reactions'], json['liked_by_node_ids']);
    return StoryItem(
      id: json['id']?.toString() ?? '',
      ownerNode: json['owner_node']?.toString() ?? '',
      ownerName: json['owner_name']?.toString() ?? 'Story',
      ownerAvatarData: json['owner_avatar_data']?.toString() ?? '',
      createdAt:
          DateTime.tryParse(json['created_at']?.toString() ?? '') ??
          DateTime.now(),
      text: json['text']?.toString() ?? '',
      imageData: json['image_data']?.toString() ?? '',
      videoData: json['video_data']?.toString() ?? '',
      videoMime: json['video_mime']?.toString() ?? 'video/mp4',
      mediaType: StoryMediaType.values.firstWhere(
        (value) => value.name == json['media_type']?.toString(),
        orElse: () {
          if ((json['video_data']?.toString() ?? '').isNotEmpty) {
            return StoryMediaType.video;
          }
          if ((json['image_data']?.toString() ?? '').isNotEmpty) {
            return StoryMediaType.image;
          }
          return StoryMediaType.none;
        },
      ),
      reactions: reactions,
      likedByNodeIds: reactions['heart'] ?? const <String>[],
      viewedByNodeIds: _stringList(json['viewed_by_node_ids']),
      visibility: StoryVisibility.values.firstWhere(
        (value) => value.name == json['visibility']?.toString(),
        orElse: () => StoryVisibility.everyone,
      ),
      allowedNodeIds: _stringList(json['allowed_node_ids']),
      excludedNodeIds: _stringList(json['excluded_node_ids']),
      hd: json['hd'] == true,
      videoDurationSeconds:
          int.tryParse(json['video_duration_seconds']?.toString() ?? '') ?? 0,
    );
  }

  StoryItem copyWith({
    String? text,
    String? imageData,
    String? videoData,
    String? videoMime,
    StoryMediaType? mediaType,
    Map<String, List<String>>? reactions,
    List<String>? likedByNodeIds,
    List<String>? viewedByNodeIds,
    bool? hd,
    int? videoDurationSeconds,
  }) {
    return StoryItem(
      id: id,
      ownerNode: ownerNode,
      ownerName: ownerName,
      ownerAvatarData: ownerAvatarData,
      createdAt: createdAt,
      text: text ?? this.text,
      imageData: imageData ?? this.imageData,
      videoData: videoData ?? this.videoData,
      videoMime: videoMime ?? this.videoMime,
      mediaType: mediaType ?? this.mediaType,
      reactions: reactions ?? this.reactions,
      likedByNodeIds: likedByNodeIds ?? this.likedByNodeIds,
      viewedByNodeIds: viewedByNodeIds ?? this.viewedByNodeIds,
      visibility: visibility,
      allowedNodeIds: allowedNodeIds,
      excludedNodeIds: excludedNodeIds,
      hd: hd ?? this.hd,
      videoDurationSeconds: videoDurationSeconds ?? this.videoDurationSeconds,
    );
  }

  static List<String> _stringList(dynamic value) {
    if (value is! List) return const [];
    return value.map((item) => item.toString()).toList();
  }

  static Map<String, List<String>> _reactions(
    dynamic value,
    dynamic legacyLikes,
  ) {
    final result = <String, List<String>>{};
    if (value is Map) {
      for (final entry in value.entries) {
        final reactors = _stringList(entry.value).toSet().toList();
        if (reactors.isNotEmpty) result[entry.key.toString()] = reactors;
      }
    }
    final hearts = <String>{
      ...?result['heart'],
      ..._stringList(legacyLikes),
    }.toList();
    if (hearts.isNotEmpty) result['heart'] = hearts;
    return result;
  }
}
