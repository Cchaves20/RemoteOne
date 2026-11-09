import 'package:flutter/material.dart';

/// A identidade do Deskside: "o monitor aceso na sala escura".
///
/// A luz vem dos monitores. O resto da interface é calmo, para ela aparecer:
/// superfícies azuladas e neutras, sem o lilás que o `ColorScheme.fromSeed`
/// espalhava por todo cartão, campo e fundo. Cada cor tem um papel só:
///
/// - **marca** (violeta): o logo e o degradê;
/// - **ação** (azul): botões principais e o que está em foco;
/// - **ao vivo** (ciano, verde-azulado no claro): o que está conectado, ligado
///   ou funcionando agora — e os links;
/// - **LED** (verde): só o "online" de um computador.
///
/// As cores ficam numa `ThemeExtension` (`context.cores`) para os dois temas
/// terem os mesmos nomes. A tela remota é sempre escura, nos dois temas: ela
/// usa `temaDaCabine`.

const Color auroraViolet = Color(0xFF7C4DFF);
const Color auroraBlue = Color(0xFF4364F7);
const Color auroraCyan = Color(0xFF22D3EE);

/// Degradê da marca: a luz do monitor. No logo, nas telas acesas e nos
/// brilhos.
const LinearGradient auroraGradient = LinearGradient(
  begin: Alignment.topLeft,
  end: Alignment.bottomRight,
  colors: [auroraViolet, auroraBlue, auroraCyan],
);

/// Degradê dos botões principais. Sem o ciano do fim: texto branco sobre
/// ciano não tem contraste.
const LinearGradient degradeDeAcao = LinearGradient(
  begin: Alignment.topLeft,
  end: Alignment.bottomRight,
  colors: [auroraViolet, auroraBlue],
);

/// A "borda de baixo" que dá relevo aos botões e às teclas.
const Color sombraDoBotao = Color(0xFF2B2A8C);

/// Títulos e números. As duas fontes vão dentro do app (nada é baixado de
/// servidor nenhum); a licença delas entra na tela de licenças.
const String fonteDosTitulos = 'SpaceGrotesk';
const String fonteDosNumeros = 'JetBrainsMono';

/// As cores de um tema. Os dois temas têm os mesmos nomes; quem desenha pede
/// pelo papel (`cores.aoVivo`), nunca pelo valor.
@immutable
class CoresDeskside extends ThemeExtension<CoresDeskside> {
  const CoresDeskside({
    required this.fundo,
    required this.superficie,
    required this.superficieAlta,
    required this.linha,
    required this.texto,
    required this.texto2,
    required this.texto3,
    required this.marca,
    required this.acao,
    required this.aoVivo,
    required this.aoVivoFundo,
    required this.led,
    required this.perigo,
    required this.monitorApagado,
    required this.bordaApagada,
    required this.pe,
    required this.tecla,
    required this.teclaEspecial,
    required this.teclaTexto,
    required this.teclaTextoEspecial,
    required this.teclaSombra,
    required this.teclaApertada,
    required this.brilhoDoTopo,
  });

  final Color fundo;
  final Color superficie;
  final Color superficieAlta;
  final Color linha;
  final Color texto;
  final Color texto2;
  final Color texto3;
  final Color marca;
  final Color acao;
  final Color aoVivo;
  final Color aoVivoFundo;
  final Color led;
  final Color perigo;
  final Color monitorApagado;
  final Color bordaApagada;
  final Color pe;
  final Color tecla;
  final Color teclaEspecial;
  final Color teclaTexto;
  final Color teclaTextoEspecial;
  final Color teclaSombra;
  final Color teclaApertada;
  final Color brilhoDoTopo;

  static const escuro = CoresDeskside(
    fundo: Color(0xFF0B0D1A),
    superficie: Color(0xFF141830),
    superficieAlta: Color(0xFF1D2142),
    linha: Color(0x14FFFFFF),
    texto: Color(0xFFEEF0FF),
    texto2: Color(0xFFA3A9C9),
    texto3: Color(0xFF8F96BD),
    marca: auroraViolet,
    acao: auroraBlue,
    aoVivo: auroraCyan,
    aoVivoFundo: Color(0x1F22D3EE),
    led: Color(0xFF34D399),
    perigo: Color(0xFFFDA4AF),
    monitorApagado: Color(0xFF0B0E20),
    bordaApagada: Color(0xFF2E3458),
    pe: Color(0xFF1A1F3D),
    tecla: Color(0xFF1D2142),
    teclaEspecial: Color(0xFF141832),
    teclaTexto: Color(0xFFF2F3FF),
    teclaTextoEspecial: Color(0xFFA9B0D6),
    teclaSombra: Color(0xFF080A16),
    teclaApertada: Color(0xFF2A3166),
    brilhoDoTopo: Color(0x597C4DFF),
  );

  static const claro = CoresDeskside(
    fundo: Color(0xFFF4F5FB),
    superficie: Color(0xFFFFFFFF),
    superficieAlta: Color(0xFFE6E8F2),
    linha: Color(0x1F0E1022),
    texto: Color(0xFF0E1022),
    texto2: Color(0xFF4A5070),
    texto3: Color(0xFF5E6486),
    marca: auroraViolet,
    acao: auroraBlue,
    // O ciano some sobre o branco: no claro, "ao vivo" é um verde-azulado
    // escuro, o mesmo do site.
    aoVivo: Color(0xFF0A7C77),
    aoVivoFundo: Color(0x1A0A7C77),
    led: Color(0xFF059669),
    perigo: Color(0xFFBE123C),
    monitorApagado: Color(0xFFE3E5EF),
    bordaApagada: Color(0xFFC5C9DA),
    pe: Color(0xFFD3D6E4),
    tecla: Color(0xFFFFFFFF),
    teclaEspecial: Color(0xFFE6E8F2),
    teclaTexto: Color(0xFF0E1022),
    teclaTextoEspecial: Color(0xFF4A5070),
    teclaSombra: Color(0xFFC3C7D8),
    teclaApertada: Color(0xFFDDE2FF),
    brilhoDoTopo: Color(0x247C4DFF),
  );

  @override
  CoresDeskside copyWith() => this;

  @override
  CoresDeskside lerp(ThemeExtension<CoresDeskside>? other, double t) {
    if (other is! CoresDeskside) return this;
    Color m(Color a, Color b) => Color.lerp(a, b, t)!;
    return CoresDeskside(
      fundo: m(fundo, other.fundo),
      superficie: m(superficie, other.superficie),
      superficieAlta: m(superficieAlta, other.superficieAlta),
      linha: m(linha, other.linha),
      texto: m(texto, other.texto),
      texto2: m(texto2, other.texto2),
      texto3: m(texto3, other.texto3),
      marca: m(marca, other.marca),
      acao: m(acao, other.acao),
      aoVivo: m(aoVivo, other.aoVivo),
      aoVivoFundo: m(aoVivoFundo, other.aoVivoFundo),
      led: m(led, other.led),
      perigo: m(perigo, other.perigo),
      monitorApagado: m(monitorApagado, other.monitorApagado),
      bordaApagada: m(bordaApagada, other.bordaApagada),
      pe: m(pe, other.pe),
      tecla: m(tecla, other.tecla),
      teclaEspecial: m(teclaEspecial, other.teclaEspecial),
      teclaTexto: m(teclaTexto, other.teclaTexto),
      teclaTextoEspecial: m(teclaTextoEspecial, other.teclaTextoEspecial),
      teclaSombra: m(teclaSombra, other.teclaSombra),
      teclaApertada: m(teclaApertada, other.teclaApertada),
      brilhoDoTopo: m(brilhoDoTopo, other.brilhoDoTopo),
    );
  }
}

extension CoresDoTema on BuildContext {
  /// As cores do tema em uso. Sem a extensão (um teste com `ThemeData()`
  /// cru), as do escuro: melhor desenhar com a paleta errada que quebrar.
  CoresDeskside get cores =>
      Theme.of(this).extension<CoresDeskside>() ?? CoresDeskside.escuro;

  /// Estilo de número: ms, fps, tamanhos, horários, códigos.
  TextStyle get numeros => const TextStyle(
        fontFamily: fonteDosNumeros,
        fontFeatures: [FontFeature.tabularFigures()],
      );
}

/// Vidro escuro translúcido: o material das barras que flutuam sobre a tela do
/// computador (a dock de aplicativos e a barra de perfis). Fica aqui, e não em
/// cada tela, porque as duas precisam parecer a mesma coisa — se uma mudar de
/// tom, a outra passa a parecer um elemento estranho ao app.
BoxDecoration glassPill() => BoxDecoration(
      color: const Color(0xEB171B34),
      borderRadius: BorderRadius.circular(22),
      border: Border.all(color: Colors.white.withAlpha(26)),
      boxShadow: [
        BoxShadow(
          color: Colors.black.withAlpha(115),
          blurRadius: 24,
          offset: const Offset(0, 8),
        ),
      ],
    );

ColorScheme _esquema(Brightness brilho, CoresDeskside c) {
  final escuro = brilho == Brightness.dark;
  return ColorScheme(
    brightness: brilho,
    primary: c.acao,
    onPrimary: Colors.white,
    primaryContainer: escuro ? const Color(0xFF1E2550) : const Color(0xFFE0E7FF),
    onPrimaryContainer: escuro ? const Color(0xFFC7D2FE) : const Color(0xFF1E2A78),
    secondary: c.aoVivo,
    onSecondary: escuro ? const Color(0xFF05222A) : Colors.white,
    secondaryContainer: escuro ? const Color(0xFF0E3340) : const Color(0xFFCCF1EE),
    onSecondaryContainer: escuro ? const Color(0xFFA5F3FC) : const Color(0xFF064E4A),
    tertiary: c.marca,
    onTertiary: Colors.white,
    error: c.perigo,
    onError: escuro ? const Color(0xFF3B0712) : Colors.white,
    errorContainer: escuro ? const Color(0xFF3B1220) : const Color(0xFFFFE4E6),
    onErrorContainer: escuro ? const Color(0xFFFECDD3) : const Color(0xFF881337),
    surface: c.fundo,
    onSurface: c.texto,
    onSurfaceVariant: c.texto2,
    surfaceContainerLowest: escuro ? const Color(0xFF080A14) : Colors.white,
    surfaceContainerLow: escuro ? const Color(0xFF101329) : const Color(0xFFFAFBFE),
    surfaceContainer: escuro ? const Color(0xFF121530) : Colors.white,
    surfaceContainerHigh: escuro ? const Color(0xFF171B38) : const Color(0xFFEEF0F7),
    surfaceContainerHighest: c.superficie,
    outline: c.texto3,
    outlineVariant: escuro ? const Color(0xFF262B4D) : const Color(0xFFD5D8E5),
    shadow: Colors.black,
    scrim: Colors.black,
    inverseSurface: escuro ? const Color(0xFFEEF0FF) : const Color(0xFF141830),
    onInverseSurface: escuro ? const Color(0xFF141830) : const Color(0xFFEEF0FF),
    inversePrimary: escuro ? const Color(0xFF1E2A78) : const Color(0xFFC7D2FE),
    surfaceTint: Colors.transparent,
  );
}

/// O texto sem o espaçamento entre letras do Material. Pensado para o
/// Android, ele deixava "W i n d o w s" com cara de app portado no iPhone.
TextTheme _textos(TextTheme base, Color cor) {
  TextStyle? sem(TextStyle? s) => s?.copyWith(letterSpacing: 0, color: cor);
  TextStyle? titulo(TextStyle? s, FontWeight peso) => s?.copyWith(
        fontFamily: fonteDosTitulos,
        fontWeight: peso,
        letterSpacing: -0.3,
        color: cor,
      );
  return base.copyWith(
    displayLarge: titulo(base.displayLarge, FontWeight.w700),
    displayMedium: titulo(base.displayMedium, FontWeight.w700),
    displaySmall: titulo(base.displaySmall, FontWeight.w700),
    headlineLarge: titulo(base.headlineLarge, FontWeight.w700),
    headlineMedium: titulo(base.headlineMedium, FontWeight.w600),
    headlineSmall: titulo(base.headlineSmall, FontWeight.w600),
    titleLarge: titulo(base.titleLarge, FontWeight.w600),
    titleMedium: sem(base.titleMedium)?.copyWith(fontWeight: FontWeight.w600),
    titleSmall: sem(base.titleSmall)?.copyWith(fontWeight: FontWeight.w600),
    bodyLarge: sem(base.bodyLarge),
    bodyMedium: sem(base.bodyMedium),
    bodySmall: sem(base.bodySmall),
    labelLarge: sem(base.labelLarge)?.copyWith(fontWeight: FontWeight.w600),
    labelMedium: sem(base.labelMedium),
    labelSmall: sem(base.labelSmall),
  );
}

ThemeData buildTheme(Brightness brightness) {
  final escuro = brightness == Brightness.dark;
  final c = escuro ? CoresDeskside.escuro : CoresDeskside.claro;
  final scheme = _esquema(brightness, c);
  final base = ThemeData(
    colorScheme: scheme,
    useMaterial3: true,
    brightness: brightness,
  );
  final raio14 = BorderRadius.circular(14);
  final textos = _textos(base.textTheme, c.texto);
  // Os botões partem do `labelLarge` do tema, e não de um estilo solto: um
  // `TextStyle` sem família cai na fonte padrão da plataforma por outro
  // caminho, e o peso e o espaçamento daqui se perderiam.
  final rotulo = textos.labelLarge ?? const TextStyle();

  return base.copyWith(
    extensions: [c],
    scaffoldBackgroundColor: c.fundo,
    canvasColor: c.fundo,
    textTheme: textos,
    appBarTheme: AppBarTheme(
      backgroundColor: c.fundo,
      foregroundColor: c.texto,
      surfaceTintColor: Colors.transparent,
      elevation: 0,
      scrolledUnderElevation: 0,
      centerTitle: false,
      titleTextStyle: TextStyle(
        fontFamily: fonteDosTitulos,
        fontWeight: FontWeight.w600,
        fontSize: 22,
        color: c.texto,
      ),
    ),
    cardTheme: CardThemeData(
      color: c.superficie,
      elevation: 0,
      margin: const EdgeInsets.symmetric(vertical: 6),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(18),
        side: BorderSide(color: c.linha),
      ),
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        backgroundColor: c.acao,
        foregroundColor: Colors.white,
        disabledBackgroundColor: c.superficieAlta,
        disabledForegroundColor: c.texto3,
        minimumSize: const Size(0, 52),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        textStyle: rotulo.copyWith(fontWeight: FontWeight.w600, fontSize: 16),
      ),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(
        foregroundColor: c.texto,
        side: BorderSide(color: c.linha.withAlpha(60)),
        minimumSize: const Size(0, 48),
        shape: RoundedRectangleBorder(borderRadius: raio14),
      ),
    ),
    textButtonTheme: TextButtonThemeData(
      style: TextButton.styleFrom(
        foregroundColor: c.aoVivo,
        textStyle: rotulo.copyWith(fontWeight: FontWeight.w600, fontSize: 15),
      ),
    ),
    floatingActionButtonTheme: FloatingActionButtonThemeData(
      backgroundColor: c.acao,
      foregroundColor: Colors.white,
      elevation: 0,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(28)),
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: c.superficie,
      hintStyle: TextStyle(color: c.texto3),
      labelStyle: TextStyle(color: c.texto2),
      floatingLabelStyle: TextStyle(color: c.texto2),
      prefixIconColor: c.texto2,
      suffixIconColor: c.texto2,
      contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 16),
      border: OutlineInputBorder(
        borderRadius: raio14,
        borderSide: BorderSide(color: c.linha),
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: raio14,
        borderSide: BorderSide(color: c.linha),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: raio14,
        borderSide: BorderSide(color: c.acao, width: 1.5),
      ),
      errorBorder: OutlineInputBorder(
        borderRadius: raio14,
        borderSide: BorderSide(color: c.perigo),
      ),
      focusedErrorBorder: OutlineInputBorder(
        borderRadius: raio14,
        borderSide: BorderSide(color: c.perigo, width: 1.5),
      ),
    ),
    switchTheme: SwitchThemeData(
      thumbColor: WidgetStateProperty.resolveWith((s) =>
          s.contains(WidgetState.selected) ? Colors.white : c.texto3),
      trackColor: WidgetStateProperty.resolveWith((s) =>
          s.contains(WidgetState.selected) ? c.acao : c.superficieAlta),
      trackOutlineColor: WidgetStateProperty.all(Colors.transparent),
    ),
    checkboxTheme: CheckboxThemeData(
      fillColor: WidgetStateProperty.resolveWith((s) =>
          s.contains(WidgetState.selected) ? c.acao : Colors.transparent),
      side: BorderSide(color: c.texto3, width: 1.6),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(5)),
    ),
    listTileTheme: ListTileThemeData(
      iconColor: c.texto2,
      textColor: c.texto,
      subtitleTextStyle: textos.bodyMedium?.copyWith(color: c.texto3, fontSize: 13),
    ),
    snackBarTheme: SnackBarThemeData(
      behavior: SnackBarBehavior.floating,
      backgroundColor: escuro ? const Color(0xFF242A52) : const Color(0xFF141830),
      contentTextStyle: textos.bodyMedium?.copyWith(color: const Color(0xFFEEF0FF)),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
    ),
    dividerTheme: DividerThemeData(color: c.linha, space: 24),
    bottomSheetTheme: BottomSheetThemeData(
      backgroundColor: c.superficie,
      surfaceTintColor: Colors.transparent,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      showDragHandle: true,
      dragHandleColor: c.texto3,
    ),
    dialogTheme: DialogThemeData(
      backgroundColor: c.superficie,
      surfaceTintColor: Colors.transparent,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(22)),
    ),
    chipTheme: ChipThemeData(
      backgroundColor: c.superficie,
      selectedColor: c.aoVivoFundo,
      side: BorderSide(color: c.linha),
      labelStyle: textos.labelLarge?.copyWith(color: c.texto),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
    ),
    segmentedButtonTheme: SegmentedButtonThemeData(
      style: ButtonStyle(
        backgroundColor: WidgetStateProperty.resolveWith((s) =>
            s.contains(WidgetState.selected) ? c.aoVivoFundo : c.superficie),
        foregroundColor: WidgetStateProperty.resolveWith((s) =>
            s.contains(WidgetState.selected) ? c.aoVivo : c.texto2),
        side: WidgetStateProperty.all(BorderSide(color: c.linha)),
      ),
    ),
    progressIndicatorTheme: ProgressIndicatorThemeData(color: c.aoVivo),
    popupMenuTheme: PopupMenuThemeData(
      color: c.superficie,
      surfaceTintColor: Colors.transparent,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
    ),
  );
}

/// O tema da tela remota: sempre o escuro, qualquer que seja o do app. Ela é
/// uma cabine em volta da imagem do computador, e uma moldura clara em volta
/// de uma tela escura cansa a vista e muda de cor conforme o tema.
final ThemeData temaDaCabine = buildTheme(Brightness.dark);
