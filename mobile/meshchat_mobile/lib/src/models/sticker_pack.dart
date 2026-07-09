import 'dart:convert';
import 'dart:typed_data';

class StickerItem {
  const StickerItem({
    required this.id,
    required this.name,
    required this.fileName,
    required this.mimeType,
    required this.base64Data,
    this.animated = false,
  });

  final String id;
  final String name;
  final String fileName;
  final String mimeType;
  final String base64Data;
  final bool animated;

  Uint8List get bytes => base64Decode(base64Data);

  StickerItem copyWith({
    String? id,
    String? name,
    String? fileName,
    String? mimeType,
    String? base64Data,
    bool? animated,
  }) {
    return StickerItem(
      id: id ?? this.id,
      name: name ?? this.name,
      fileName: fileName ?? this.fileName,
      mimeType: mimeType ?? this.mimeType,
      base64Data: base64Data ?? this.base64Data,
      animated: animated ?? this.animated,
    );
  }

  factory StickerItem.fromJson(Map<String, dynamic> json) {
    return StickerItem(
      id: json['id']?.toString() ?? '',
      name: json['name']?.toString() ?? 'Sticker',
      fileName: json['file_name']?.toString() ?? 'sticker.webp',
      mimeType: json['mime_type']?.toString() ?? 'image/webp',
      base64Data: json['base64_data']?.toString() ?? '',
      animated: json['animated'] == true,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'name': name,
      'file_name': fileName,
      'mime_type': mimeType,
      'base64_data': base64Data,
      'animated': animated,
    };
  }
}

class StickerPack {
  const StickerPack({
    required this.id,
    required this.name,
    this.stickers = const [],
  });

  final String id;
  final String name;
  final List<StickerItem> stickers;

  StickerPack copyWith({
    String? id,
    String? name,
    List<StickerItem>? stickers,
  }) {
    return StickerPack(
      id: id ?? this.id,
      name: name ?? this.name,
      stickers: stickers ?? this.stickers,
    );
  }

  factory StickerPack.fromJson(Map<String, dynamic> json) {
    return StickerPack(
      id: json['id']?.toString() ?? '',
      name: json['name']?.toString() ?? 'My stickers',
      stickers: (json['stickers'] is List ? json['stickers'] as List : const [])
          .whereType<Map>()
          .map((raw) => StickerItem.fromJson(Map<String, dynamic>.from(raw)))
          .where((item) => item.id.isNotEmpty && item.base64Data.isNotEmpty)
          .toList(),
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'name': name,
      'stickers': stickers.map((item) => item.toJson()).toList(),
    };
  }
}

class StickerLibrary {
  const StickerLibrary({this.packs = const [], this.favoriteIds = const {}});

  final List<StickerPack> packs;
  final Set<String> favoriteIds;

  List<StickerItem> get allStickers => [
    for (final pack in packs) ...pack.stickers,
  ];

  List<StickerItem> get favorites => allStickers
      .where((item) => favoriteIds.contains(item.id))
      .toList(growable: false);

  StickerLibrary copyWith({
    List<StickerPack>? packs,
    Set<String>? favoriteIds,
  }) {
    return StickerLibrary(
      packs: packs ?? this.packs,
      favoriteIds: favoriteIds ?? this.favoriteIds,
    );
  }

  factory StickerLibrary.fromJson(Map<String, dynamic> json) {
    return StickerLibrary(
      packs: (json['packs'] is List ? json['packs'] as List : const [])
          .whereType<Map>()
          .map((raw) => StickerPack.fromJson(Map<String, dynamic>.from(raw)))
          .where((pack) => pack.id.isNotEmpty)
          .toList(),
      favoriteIds:
          (json['favorite_ids'] is List
                  ? json['favorite_ids'] as List
                  : const [])
              .map((value) => value.toString())
              .where((value) => value.isNotEmpty)
              .toSet(),
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'packs': packs.map((pack) => pack.toJson()).toList(),
      'favorite_ids': favoriteIds.toList()..sort(),
    };
  }
}
