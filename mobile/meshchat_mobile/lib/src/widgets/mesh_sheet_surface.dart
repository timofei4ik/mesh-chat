import 'package:flutter/material.dart';

/// A painted surface on every platform, including platforms without UIKit glass.
class MeshSheetSurface extends StatelessWidget {
  const MeshSheetSurface({super.key, required this.child, this.radius = 24});
  final Widget child;
  final double radius;

  @override
  Widget build(BuildContext context) => Material(
    color: const Color(0xFF1B2833),
    shape: RoundedRectangleBorder(
      borderRadius: BorderRadius.circular(radius),
      side: const BorderSide(color: Color(0xFF3A4954)),
    ),
    clipBehavior: Clip.antiAlias,
    child: ListTileTheme(
      data: const ListTileThemeData(
        iconColor: Color(0xFFB8D6E7),
        textColor: Color(0xFFEAF1F7),
        selectedColor: Color(0xFF8DDCFA),
        selectedTileColor: Color(0xFF2A414F),
        contentPadding: EdgeInsets.symmetric(horizontal: 20),
      ),
      child: child,
    ),
  );
}
