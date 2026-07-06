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
    this.likedByNodeIds = const [],
    this.viewedByNodeIds = const [],
    this.visibility = StoryVisibility.everyone,
    this.allowedNodeIds = const [],
    this.excludedNodeIds = const [],
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
  final List<String> likedByNodeIds;
  final List<String> viewedByNodeIds;
  final StoryVisibility visibility;
  final List<String> allowedNodeIds;
  final List<String> excludedNodeIds;

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
      'liked_by_node_ids': likedByNodeIds,
      'viewed_by_node_ids': viewedByNodeIds,
      'visibility': visibility.name,
      'allowed_node_ids': allowedNodeIds,
      'excluded_node_ids': excludedNodeIds,
    };
  }

  factory StoryItem.fromJson(Map<String, dynamic> json) {
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
      likedByNodeIds: _stringList(json['liked_by_node_ids']),
      viewedByNodeIds: _stringList(json['viewed_by_node_ids']),
      visibility: StoryVisibility.values.firstWhere(
        (value) => value.name == json['visibility']?.toString(),
        orElse: () => StoryVisibility.everyone,
      ),
      allowedNodeIds: _stringList(json['allowed_node_ids']),
      excludedNodeIds: _stringList(json['excluded_node_ids']),
    );
  }

  StoryItem copyWith({
    String? text,
    String? imageData,
    String? videoData,
    String? videoMime,
    StoryMediaType? mediaType,
    List<String>? likedByNodeIds,
    List<String>? viewedByNodeIds,
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
      likedByNodeIds: likedByNodeIds ?? this.likedByNodeIds,
      viewedByNodeIds: viewedByNodeIds ?? this.viewedByNodeIds,
      visibility: visibility,
      allowedNodeIds: allowedNodeIds,
      excludedNodeIds: excludedNodeIds,
    );
  }

  static List<String> _stringList(dynamic value) {
    if (value is! List) return const [];
    return value.map((item) => item.toString()).toList();
  }
}
