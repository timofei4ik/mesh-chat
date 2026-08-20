import 'package:flutter/material.dart';

/// Shared visual shell for secondary settings and system pages.
class MeshSettingsSurface extends StatelessWidget {
  const MeshSettingsSurface({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    final base = Theme.of(context);
    final border = Colors.white.withValues(alpha: 0.11);
    final surface = const Color(0xFF172432).withValues(alpha: 0.88);
    final input = const Color(0xFF0D1B29).withValues(alpha: 0.90);

    return Theme(
      data: base.copyWith(
        scaffoldBackgroundColor: Colors.transparent,
        canvasColor: const Color(0xFF07111E),
        appBarTheme: base.appBarTheme.copyWith(
          backgroundColor: Colors.transparent,
          surfaceTintColor: Colors.transparent,
          shadowColor: Colors.transparent,
          elevation: 0,
          scrolledUnderElevation: 0,
        ),
        cardTheme: CardThemeData(
          color: surface,
          surfaceTintColor: Colors.transparent,
          elevation: 0,
          margin: EdgeInsets.zero,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(18),
            side: BorderSide(color: border),
          ),
        ),
        listTileTheme: base.listTileTheme.copyWith(
          iconColor: const Color(0xFF72D8FF),
          contentPadding: const EdgeInsets.symmetric(
            horizontal: 16,
            vertical: 4,
          ),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(18),
          ),
        ),
        dividerTheme: base.dividerTheme.copyWith(
          color: Colors.white.withValues(alpha: 0.08),
          space: 1,
          thickness: 1,
        ),
        inputDecorationTheme: base.inputDecorationTheme.copyWith(
          filled: true,
          fillColor: input,
          border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(16),
            borderSide: BorderSide(color: border),
          ),
          enabledBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(16),
            borderSide: BorderSide(color: border),
          ),
          focusedBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(16),
            borderSide: const BorderSide(color: Color(0xFF72D8FF)),
          ),
        ),
        filledButtonTheme: FilledButtonThemeData(
          style: FilledButton.styleFrom(
            backgroundColor: const Color(0xFF72D8FF),
            foregroundColor: const Color(0xFF07111E),
            minimumSize: const Size(0, 46),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(16),
            ),
          ),
        ),
        outlinedButtonTheme: OutlinedButtonThemeData(
          style: OutlinedButton.styleFrom(
            side: BorderSide(color: border),
            minimumSize: const Size(0, 46),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(16),
            ),
          ),
        ),
        iconButtonTheme: IconButtonThemeData(
          style: IconButton.styleFrom(
            backgroundColor: Colors.white.withValues(alpha: 0.075),
            foregroundColor: const Color(0xFFDDE9F5),
            shape: const CircleBorder(),
          ),
        ),
        dialogTheme: DialogThemeData(
          backgroundColor: const Color(0xFF172432),
          surfaceTintColor: Colors.transparent,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(20),
            side: BorderSide(color: border),
          ),
        ),
      ),
      child: DecoratedBox(
        decoration: const BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [
              Color(0xFF06101D),
              Color(0xFF071422),
              Color(0xFF111329),
              Color(0xFF07111E),
            ],
            stops: [0, 0.42, 0.72, 1],
          ),
        ),
        child: CustomPaint(
          painter: const _SettingsAmbientPainter(),
          child: child,
        ),
      ),
    );
  }
}

class _SettingsAmbientPainter extends CustomPainter {
  const _SettingsAmbientPainter();

  @override
  void paint(Canvas canvas, Size size) {
    void glow(Offset center, double radius, Color color) {
      final paint = Paint()
        ..shader = RadialGradient(
          colors: [color, color.withValues(alpha: 0)],
        ).createShader(Rect.fromCircle(center: center, radius: radius));
      canvas.drawCircle(center, radius, paint);
    }

    glow(
      Offset(size.width * 0.16, size.height * 0.12),
      320,
      const Color(0x0E40CFFF),
    );
    glow(
      Offset(size.width * 0.90, size.height * 0.28),
      380,
      const Color(0x0D9A6BFF),
    );
    glow(
      Offset(size.width * 0.54, size.height * 0.96),
      400,
      const Color(0x07348DFF),
    );
  }

  @override
  bool shouldRepaint(covariant _SettingsAmbientPainter oldDelegate) => false;
}
