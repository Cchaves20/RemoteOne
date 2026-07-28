import 'package:flutter/material.dart';

/// Tema "Aurora": escuro/techy com gradiente violeta → azul → ciano.
/// Usa apenas APIs estáveis (sem withOpacity/CardTheme) para não quebrar o
/// `flutter analyze` em versões recentes do Flutter.

const Color auroraViolet = Color(0xFF7C4DFF);
const Color auroraBlue = Color(0xFF4364F7);
const Color auroraCyan = Color(0xFF22D3EE);
const Color _seed = auroraViolet;
const Color _darkBg = Color(0xFF0E1022);

/// Gradiente da marca, usado em cabeçalhos, botões e destaques.
const LinearGradient auroraGradient = LinearGradient(
  begin: Alignment.topLeft,
  end: Alignment.bottomRight,
  colors: [auroraViolet, auroraBlue, auroraCyan],
);

/// Vidro escuro translúcido: o material das barras que flutuam sobre a tela do
/// computador (a dock de aplicativos e a barra de perfis). Fica aqui, e não em
/// cada tela, porque as duas precisam parecer a mesma coisa — se uma mudar de
/// tom, a outra passa a parecer um elemento estranho ao app.
BoxDecoration glassPill() => BoxDecoration(
      color: const Color(0xE61A1D33),
      borderRadius: BorderRadius.circular(22),
      border: Border.all(color: Colors.white.withAlpha(30)),
      boxShadow: [
        BoxShadow(
          color: Colors.black.withAlpha(120),
          blurRadius: 18,
          offset: const Offset(0, 6),
        ),
      ],
    );

ThemeData buildTheme(Brightness brightness) {
  final isDark = brightness == Brightness.dark;
  final scheme = ColorScheme.fromSeed(seedColor: _seed, brightness: brightness);
  final base = ThemeData(colorScheme: scheme, useMaterial3: true);

  return base.copyWith(
    scaffoldBackgroundColor: isDark ? _darkBg : scheme.surface,
    textTheme: base.textTheme.copyWith(
      headlineSmall: base.textTheme.headlineSmall?.copyWith(
        fontWeight: FontWeight.w700,
        letterSpacing: -0.5,
      ),
      titleLarge: base.textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w700),
      titleMedium: base.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w600),
      labelLarge: base.textTheme.labelLarge?.copyWith(fontWeight: FontWeight.w600),
    ),
    appBarTheme: AppBarTheme(
      backgroundColor: isDark ? _darkBg : scheme.surface,
      surfaceTintColor: Colors.transparent,
      elevation: 0,
      scrolledUnderElevation: 0,
      centerTitle: false,
      titleTextStyle: base.textTheme.titleLarge?.copyWith(
        fontWeight: FontWeight.w700,
        color: scheme.onSurface,
      ),
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        minimumSize: const Size(0, 52),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(14),
        ),
        textStyle: const TextStyle(fontWeight: FontWeight.w600, fontSize: 16),
      ),
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: isDark ? Colors.white.withAlpha(12) : scheme.surfaceContainerHighest,
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(14),
        borderSide: BorderSide.none,
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(14),
        borderSide: BorderSide.none,
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(14),
        borderSide: BorderSide(color: scheme.primary, width: 2),
      ),
    ),
    snackBarTheme: SnackBarThemeData(
      behavior: SnackBarBehavior.floating,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
      ),
    ),
    dividerTheme: DividerThemeData(
      color: scheme.outlineVariant.withAlpha(isDark ? 60 : 120),
      space: 24,
    ),
  );
}
