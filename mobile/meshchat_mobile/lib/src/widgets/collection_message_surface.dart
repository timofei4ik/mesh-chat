import 'package:flutter/material.dart';

import '../models/profile.dart';

typedef CollectionBubbleSkin = ({String asset, Color color, bool rightEdge});

// Eligibility belongs to the sender, never to the person viewing the message.
CollectionBubbleSkin? collectionBubbleSkin(Profile? sender) {
  if (sender?.meshProBadge != true) return null;
  final selected = sender!.effectiveMessageBubbleStyle;
  final style = selected == 'auto'
      ? sender.effectiveProfileBackground
      : selected;
  final (name, color, right) = switch (style) {
    'nebula' => ('nebula', 0xFF181B35, true),
    'ocean' => ('ocean', 0xFF102833, true),
    'sakura' => ('sakura', 0xFF291C34, true),
    'solar' => ('solar', 0xFF2B2030, true),
    'stardust' => ('stardust', 0xFF151C34, true),
    'ember' => ('ember', 0xFF281E2E, true),
    'sunset' => ('sunset', 0xFF2B2340, true),
    'frost' => ('frost', 0xFF182D3B, true),
    'orbit' => ('orbit', 0xFF241C39, true),
    'camp_clouds' => ('spirit-garden', 0xFF131B34, true),
    'camp_moon' => ('tidal-shrine', 0xFF0B2236, false),
    'camp_ember' => ('moonflower-courtyard', 0xFF191F40, false),
    'camp_stories' => ('sunken-lotus-garden', 0xFF082737, false),
    'camp_rainlight' => ('rainlight-conservatory', 0xFF101E39, false),
    'remote_skybound_camp' => ('skybound-camp', 0xFF102740, false),
    'remote_moonlit_path' => ('moonlit-path', 0xFF201D45, false),
    'remote_ember_vale' => ('ember-vale', 0xFF141F32, false),
    'remote_lantern_stories' => ('lantern-stories', 0xFF261D38, true),
    _ => ('', 0, false),
  };
  return name.isEmpty
      ? null
      : (
          asset: 'assets/message_bubbles/$name.png',
          color: Color(color),
          rightEdge: right,
        );
}

/// Artwork occupies fixed-height edge bands. No part of a generated scene is
/// stretched vertically: the middle is always the plain surface color.
class CollectionMessageSurface extends StatelessWidget {
  const CollectionMessageSurface({
    super.key,
    required this.skin,
    required this.decoration,
    required this.padding,
    required this.constraints,
    required this.child,
    this.mine = false,
  });

  final CollectionBubbleSkin skin;
  final BoxDecoration decoration;
  final EdgeInsetsGeometry padding;
  final BoxConstraints constraints;
  final Widget child;
  final bool mine;

  @override
  Widget build(BuildContext context) {
    final inset = padding.resolve(Directionality.of(context));
    final shape = CollectionBubbleBorder(
      mine: mine,
      side:
          decoration.border?.top ??
          const BorderSide(color: Color(0xFF445064), width: 0.7),
    );
    return Container(
      constraints: constraints,
      decoration: ShapeDecoration(
        shape: shape,
        color: skin.color,
        shadows: decoration.boxShadow,
      ),
      child: ClipPath(
        clipper: ShapeBorderClipper(shape: shape),
        child: Stack(
          children: [
            Positioned.fill(
              child: IgnorePointer(
                child: ExcludeSemantics(
                  child: LayoutBuilder(
                    builder: (context, constraints) {
                      final bandHeight = (constraints.maxHeight / 2).clamp(
                        0.0,
                        22.5,
                      );
                      return Stack(
                        children: [
                          for (final top in [true, false])
                            Positioned(
                              right: 0,
                              top: top ? 0 : null,
                              bottom: top ? null : 0,
                              width: 150,
                              height: bandHeight,
                              child: _CollectionArtworkBand(
                                asset: skin.asset,
                                top: top,
                              ),
                            ),
                        ],
                      );
                    },
                  ),
                ),
              ),
            ),
            Padding(
              padding: EdgeInsets.fromLTRB(
                inset.left + (mine ? 0 : 6),
                inset.top,
                inset.right + 30 + (mine ? 6 : 0),
                inset.bottom,
              ),
              child: DefaultTextStyle.merge(
                style: const TextStyle(color: Color(0xFFF3F5FA)),
                child: child,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _CollectionArtworkBand extends StatelessWidget {
  const _CollectionArtworkBand({required this.asset, required this.top});
  final String asset;
  final bool top;

  @override
  Widget build(BuildContext context) => ShaderMask(
    blendMode: BlendMode.dstIn,
    shaderCallback: (rect) => LinearGradient(
      begin: top ? Alignment.topCenter : Alignment.bottomCenter,
      end: top ? Alignment.bottomCenter : Alignment.topCenter,
      colors: const [Colors.white, Colors.white, Colors.transparent],
      stops: const [0, 0.55, 1],
    ).createShader(rect),
    child: ShaderMask(
      blendMode: BlendMode.dstIn,
      shaderCallback: (rect) => const LinearGradient(
        colors: [Colors.transparent, Colors.white],
        stops: [0, 0.65],
      ).createShader(rect),
      child: ClipRect(
        child: OverflowBox(
          alignment: top ? Alignment.topRight : Alignment.bottomRight,
          minWidth: 150,
          maxWidth: 150,
          minHeight: 45,
          maxHeight: 45,
          child: Image.asset(
            asset,
            scale: 4,
            width: 150,
            height: 45,
            fit: BoxFit.fill,
            filterQuality: FilterQuality.medium,
            errorBuilder: (_, _, _) => const SizedBox.shrink(),
          ),
        ),
      ),
    ),
  );
}

class CollectionBubbleBorder extends ShapeBorder {
  const CollectionBubbleBorder({
    this.mine = false,
    this.side = BorderSide.none,
  });
  final bool mine;
  final BorderSide side;

  @override
  EdgeInsetsGeometry get dimensions => EdgeInsets.all(side.width);

  @override
  Path getOuterPath(Rect rect, {TextDirection? textDirection}) {
    final w = rect.width;
    final h = rect.height;
    final r = (h / 3).clamp(0.0, 12.0);
    const tail = 6.0;
    var path = Path()
      ..moveTo(tail + r, 0)
      ..lineTo(w - r, 0)
      ..quadraticBezierTo(w, 0, w, r)
      ..lineTo(w, h - r)
      ..quadraticBezierTo(w, h, w - r, h)
      ..lineTo(tail + r, h)
      ..quadraticBezierTo(tail + 3, h, tail + 2, h - 3)
      ..quadraticBezierTo(2, h, 0, h)
      ..quadraticBezierTo(tail, h - 7, tail, h - 15)
      ..lineTo(tail, r)
      ..quadraticBezierTo(tail, 0, tail + r, 0)
      ..close();
    if (mine) {
      path = path.transform(
        (Matrix4.diagonal3Values(-1, 1, 1)..setTranslationRaw(w, 0, 0)).storage,
      );
    }
    return path.shift(rect.topLeft);
  }

  @override
  Path getInnerPath(Rect rect, {TextDirection? textDirection}) =>
      getOuterPath(rect.deflate(side.width), textDirection: textDirection);

  @override
  ShapeBorder scale(double t) =>
      CollectionBubbleBorder(mine: mine, side: side.scale(t));

  @override
  void paint(Canvas canvas, Rect rect, {TextDirection? textDirection}) {
    if (side.style == BorderStyle.none) return;
    canvas.drawPath(getOuterPath(rect.deflate(side.width / 2)), side.toPaint());
  }
}
