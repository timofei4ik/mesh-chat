import 'package:flutter/material.dart';

ThemeData richEditorTheme(ThemeData base) {
  const surface = Color(0xFF1C2327);
  const border = Color(0xFF39454B);
  const text = Color(0xFFE8EFF0);
  return base.copyWith(
    scaffoldBackgroundColor: const Color(0xFF121719),
    colorScheme: const ColorScheme.dark(
      primary: Color(0xFF8BD8F1),
      onPrimary: Color(0xFF10252C),
      secondary: Color(0xFFA4DCC2),
      surface: surface,
      onSurface: text,
      onSurfaceVariant: Color(0xFFB0BDC2),
      outline: border,
    ),
    appBarTheme: const AppBarTheme(
      backgroundColor: Color(0xFF181F22),
      foregroundColor: text,
      elevation: 0,
      scrolledUnderElevation: 0,
      titleTextStyle: TextStyle(
        fontSize: 17,
        fontWeight: FontWeight.w600,
        color: text,
      ),
    ),
    popupMenuTheme: PopupMenuThemeData(
      color: surface,
      surfaceTintColor: Colors.transparent,
      elevation: 12,
      shadowColor: Colors.black54,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(8),
        side: const BorderSide(color: border),
      ),
      textStyle: const TextStyle(fontSize: 14, color: text),
    ),
    dialogTheme: DialogThemeData(
      backgroundColor: surface,
      surfaceTintColor: Colors.transparent,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(8),
        side: const BorderSide(color: border),
      ),
    ),
    bottomSheetTheme: const BottomSheetThemeData(
      backgroundColor: surface,
      surfaceTintColor: Colors.transparent,
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: const Color(0xFF141B1E),
      contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(8),
        borderSide: const BorderSide(color: border),
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(8),
        borderSide: const BorderSide(color: border),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(8),
        borderSide: const BorderSide(color: Color(0xFF8BD8F1)),
      ),
    ),
    iconButtonTheme: IconButtonThemeData(
      style: IconButton.styleFrom(
        foregroundColor: const Color(0xFFD1DEE2),
        minimumSize: const Size(40, 40),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
      ),
    ),
    dividerTheme: const DividerThemeData(
      color: Color(0xFF303A3F),
      thickness: 1,
    ),
    textSelectionTheme: const TextSelectionThemeData(
      cursorColor: Color(0xFF8BD8F1),
      selectionColor: Color(0x554FAAAB),
      selectionHandleColor: Color(0xFF8BD8F1),
    ),
  );
}
