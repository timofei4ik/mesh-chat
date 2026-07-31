import 'package:flutter/material.dart';

bool isRemoteMeshStudioAsset(String source) {
  final uri = Uri.tryParse(source);
  return uri != null && (uri.scheme == 'https' || uri.scheme == 'http');
}

class MeshStudioImage extends StatelessWidget {
  const MeshStudioImage({
    super.key,
    required this.source,
    this.fallbackAsset,
    this.fit = BoxFit.contain,
    this.alignment = Alignment.center,
    this.filterQuality = FilterQuality.medium,
  });

  final String source;
  final String? fallbackAsset;
  final BoxFit fit;
  final AlignmentGeometry alignment;
  final FilterQuality filterQuality;

  @override
  Widget build(BuildContext context) {
    if (!isRemoteMeshStudioAsset(source)) {
      return Image.asset(
        source,
        fit: fit,
        alignment: alignment,
        filterQuality: filterQuality,
        gaplessPlayback: true,
      );
    }
    return Image.network(
      source,
      fit: fit,
      alignment: alignment,
      filterQuality: filterQuality,
      gaplessPlayback: true,
      errorBuilder: (_, _, _) {
        final fallback = fallbackAsset;
        if (fallback == null || fallback.isEmpty) {
          return const SizedBox.shrink();
        }
        return Image.asset(
          fallback,
          fit: fit,
          alignment: alignment,
          filterQuality: filterQuality,
          gaplessPlayback: true,
        );
      },
    );
  }
}
