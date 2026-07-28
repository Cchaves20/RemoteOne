import '../l10n/strings.dart';

/// Sugestões de palavra para o teclado remoto.
///
/// **Nunca corrige sozinho.** A palavra só muda se a pessoa tocar numa
/// sugestão. Num teclado que digita direto no computador, uma correção
/// automática errada é pior que o erro que ela tentava consertar: os usos mais
/// comuns são terminal, caminho de arquivo e senha, onde "quase certo" é
/// simplesmente errado.
///
/// Duas fontes, nesta ordem de confiança:
///
/// 1. **O que você já digitou.** É a fonte que sabe os seus nomes próprios, os
///    seus comandos e o seu jargão — coisas que dicionário nenhum traz.
/// 2. **Uma lista curta de palavras comuns** do idioma, para o primeiro dia
///    valer alguma coisa.
class WordSuggester {
  WordSuggester({Iterable<String> seed = const [], Map<String, int>? learned}) {
    for (final palavra in seed) {
      final limpa = palavra.trim();
      // Em minúsculas porque é assim que o índice é consultado; a maiúscula de
      // quem digita é reposta na saída.
      if (limpa.length >= _minLength) _register(limpa.toLowerCase(), 0);
    }
    learned?.forEach((palavra, vezes) {
      _learned[palavra] = vezes;
      _register(palavra, vezes + 1);
    });
  }

  /// Cria o sugeridor com as palavras comuns do idioma da interface.
  factory WordSuggester.forLanguage(
    AppLanguage language, {
    Map<String, int>? learned,
  }) {
    return WordSuggester(seed: _seedFor(language), learned: learned);
  }

  static const _minLength = 3;

  /// Quantas sugestões cabem na barra sem virar sopa de letrinhas.
  static const maxSuggestions = 3;

  /// Todas as candidatas e o peso de cada uma, num índice **montado uma vez**.
  ///
  /// Era aqui a lentidão da primeira versão: ela remontava este mapa a cada
  /// tecla digitada. Com milhares de palavras, isso é trabalho suficiente para
  /// se sentir no dedo.
  final Map<String, int> _index = {};

  /// Forma sem acento de cada candidata, calculada uma vez. Recalcular a cada
  /// tecla significava construir milhares de strings por letra.
  final Map<String, String> _folded = {};

  /// Palavras que a pessoa digitou, e quantas vezes. A contagem é o que faz a
  /// palavra usada ontem aparecer antes da usada uma vez no mês passado.
  final Map<String, int> _learned = {};

  void _register(String palavra, int peso) {
    _index[palavra] = peso;
    _folded[palavra] = _fold(palavra);
  }

  Map<String, int> get learned => Map.unmodifiable(_learned);

  /// Registra uma palavra concluída (espaço, enter, pontuação).
  ///
  /// Guarda em minúsculas: "Caio" e "caio" são a mesma palavra para efeito de
  /// sugestão, e a maiúscula é reposta na hora de mostrar.
  void learn(String word) {
    final limpa = word.trim().toLowerCase();
    if (limpa.length < _minLength || !_isWord(limpa)) return;
    final vezes = (_learned[limpa] ?? 0) + 1;
    _learned[limpa] = vezes;
    _register(limpa, (_index[limpa] ?? 0) + 1);
    // Teto para o histórico não crescer sem fim na memória do celular; sai a
    // palavra menos usada, que é a que menos falta faz.
    if (_learned.length > 2000) {
      final menos = _learned.entries.reduce((a, b) => a.value <= b.value ? a : b);
      _learned.remove(menos.key);
      _index.remove(menos.key);
      _folded.remove(menos.key);
    }
  }

  /// Sugestões para o que está sendo digitado, da melhor para a pior.
  ///
  /// Vazio quando não há o que sugerir — a barra some em vez de mostrar
  /// palpites ruins.
  List<String> suggest(String typed) {
    final base = typed.trim();
    if (base.length < 2 || !_isWord(base.toLowerCase())) return const [];
    final minusculo = base.toLowerCase();
    final alvo = _fold(minusculo);

    // Primeira passada: só `startsWith`, que é barato. Completar o que está
    // sendo escrito é a sugestão mais óbvia e a que menos arrisca — a pessoa vê
    // o começo do que digitou.
    final pontuadas = <_Scored>[];
    _index.forEach((palavra, peso) {
      if (palavra == minusculo) return; // já é o que foi digitado
      if (_folded[palavra]!.startsWith(alvo)) {
        pontuadas.add(_Scored(palavra, 0, peso, palavra.length - base.length));
      }
    });

    // Com três completações, nenhum candidato por semelhança poderia passar à
    // frente (todos têm distância maior que zero). Então a parte cara — a
    // distância de edição — nem chega a rodar no caso comum.
    if (pontuadas.length < maxSuggestions) {
      final limite = alvo.length <= 4 ? 1 : 2;
      _index.forEach((palavra, peso) {
        if (palavra == minusculo) return;
        final dobrada = _folded[palavra]!;
        if (dobrada.startsWith(alvo)) return; // já entrou na primeira passada
        // Só vale procurar erro de digitação em palavras de tamanho parecido.
        if ((dobrada.length - alvo.length).abs() > limite) return;
        final distancia = _distance(dobrada, alvo, limite);
        if (distancia <= limite) {
          pontuadas.add(_Scored(palavra, distancia, peso, 0));
        }
      });
    }

    pontuadas.sort();
    return pontuadas
        .take(maxSuggestions)
        .map((s) => _matchCase(base, s.word))
        .toList();
  }

  /// Só letras (com acento) contam como palavra. Número, símbolo e caminho de
  /// arquivo não têm o que ser sugerido.
  static bool _isWord(String s) =>
      s.isNotEmpty && RegExp(r"^[a-zà-öø-ÿ']+$").hasMatch(s);

  /// Tira os acentos para comparar: quem digita "voce" quer ver "você".
  static String _fold(String s) {
    const de = 'áàâãäéèêëíìîïóòôõöúùûüçñ';
    const para = 'aaaaaeeeeiiiiooooouuuucn';
    final buffer = StringBuffer();
    for (final c in s.toLowerCase().split('')) {
      final i = de.indexOf(c);
      buffer.write(i >= 0 ? para[i] : c);
    }
    return buffer.toString();
  }

  /// Repõe a caixa de quem digitou: "Caio" digitado vira "Caio" sugerido.
  static String _matchCase(String typed, String suggestion) {
    if (typed.isEmpty) return suggestion;
    final primeira = typed[0];
    if (primeira == primeira.toUpperCase() &&
        primeira != primeira.toLowerCase()) {
      return suggestion[0].toUpperCase() + suggestion.substring(1);
    }
    return suggestion;
  }

  /// Distância de edição, com desistência antecipada.
  ///
  /// Devolve `limit + 1` assim que passa do limite: não interessa o quanto
  /// duas palavras são diferentes depois que já são diferentes demais.
  static int _distance(String a, String b, int limit) {
    if ((a.length - b.length).abs() > limit) return limit + 1;
    var anterior = List<int>.generate(b.length + 1, (i) => i);
    for (var i = 1; i <= a.length; i++) {
      final atual = List<int>.filled(b.length + 1, 0);
      atual[0] = i;
      var melhor = atual[0];
      for (var j = 1; j <= b.length; j++) {
        final custo = a[i - 1] == b[j - 1] ? 0 : 1;
        atual[j] = [
          atual[j - 1] + 1,
          anterior[j] + 1,
          anterior[j - 1] + custo,
        ].reduce((x, y) => x < y ? x : y);
        if (atual[j] < melhor) melhor = atual[j];
      }
      if (melhor > limit) return limit + 1;
      anterior = atual;
    }
    return anterior[b.length];
  }

  /// Palavras comuns por idioma, curtas de propósito: servem para o primeiro
  /// dia, até o histórico de quem usa tomar conta.
  ///
  /// Chinês não entra: o teclado remoto é latino, e a escrita chinesa não se
  /// resolve com lista de palavras — mostrar uma barra vazia é mais honesto que
  /// sugerir bobagem.
  static Iterable<String> _seedFor(AppLanguage language) {
    final texto = switch (language) {
      AppLanguage.ptBr => _ptBr,
      AppLanguage.es => _es,
      AppLanguage.fr => _fr,
      AppLanguage.zh => '',
      _ => _en,
    };
    return texto.split(' ').where((p) => p.isNotEmpty);
  }

  static const _ptBr =
      'para com uma que não mais como mas dos das pelo pela até quando onde '
      'porque então também já muito bem tudo nada isso este esta esse essa '
      'aqui ali agora depois antes sempre nunca ainda talvez obrigado por '
      'favor você vocês nós eles elas meu minha seu sua nosso nossa qual '
      'quem quanto arquivo pasta tela computador celular senha usuário '
      'nome data hora hoje ontem amanhã semana mês ano trabalho casa '
      'projeto reunião mensagem email link vídeo música foto documento '
      'cópia colar abrir fechar salvar enviar receber baixar buscar '
      'entrar sair fazer ficar poder querer saber ver dizer estar ter '
      'bom boa melhor pior grande pequeno novo velho certo errado '
      'sim não talvez claro tchau';

  static const _en =
      'the and for that with this from have not but you your they them '
      'here there now then before after always never still maybe please '
      'thanks file folder screen computer phone password user name date '
      'time today tomorrow yesterday week month year work home project '
      'meeting message email link video music photo document copy paste '
      'open close save send receive download search login logout make '
      'take know think want need see say get good better best small '
      'large new old right wrong yes okay bye';

  static const _es =
      'para con una que más como pero los las por ella ellos hasta cuando '
      'donde porque entonces también muy bien todo nada esto esta este '
      'aquí ahora después antes siempre nunca todavía quizás gracias por '
      'favor usted ustedes nosotros mi tu su nuestro cual quien cuanto '
      'archivo carpeta pantalla computadora teléfono contraseña usuario '
      'nombre fecha hora hoy ayer mañana semana mes año trabajo casa '
      'proyecto reunión mensaje correo enlace video música foto documento '
      'copiar pegar abrir cerrar guardar enviar recibir descargar buscar '
      'entrar salir hacer poder querer saber ver decir estar tener bueno '
      'mejor peor grande pequeño nuevo viejo cierto sí adiós';

  static const _fr =
      'pour avec une que plus comme mais les des par elle ils jusqu quand '
      'parce alors aussi très bien tout rien cette cet ici maintenant '
      'après avant toujours jamais encore peut-être merci vous nous mon '
      'votre notre quel qui combien fichier dossier écran ordinateur '
      'téléphone passe utilisateur nom date heure aujourd hier demain '
      'semaine mois année travail maison projet réunion message courriel '
      'lien vidéo musique photo document copier coller ouvrir fermer '
      'enregistrer envoyer recevoir télécharger chercher entrer sortir '
      'faire pouvoir vouloir savoir voir dire être avoir bon meilleur '
      'grand petit nouveau vieux vrai oui non salut';
}

/// Uma candidata pontuada. A ordem é: erro menor primeiro, depois a mais usada,
/// depois a que menos acrescenta ao que já foi digitado.
class _Scored implements Comparable<_Scored> {
  const _Scored(this.word, this.distance, this.frequency, this.extra);

  final String word;
  final int distance;
  final int frequency;
  final int extra;

  @override
  int compareTo(_Scored other) {
    if (distance != other.distance) return distance.compareTo(other.distance);
    if (frequency != other.frequency) return other.frequency.compareTo(frequency);
    if (extra != other.extra) return extra.compareTo(other.extra);
    return word.compareTo(other.word);
  }
}
