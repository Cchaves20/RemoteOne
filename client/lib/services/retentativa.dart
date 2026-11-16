/// Quando tentar de novo, e quando parar de tentar.
///
/// ## Por que isto não ficou solto na tela
///
/// São quinze linhas, e a tentação de deixá-las dentro do `remote_screen.dart`
/// era grande. Mas é justamente aqui que moram os dois defeitos que ninguém vê
/// acontecer: **tentar para sempre** (que gasta bateria e dados de quem está
/// na rua, para uma conexão que talvez não tenha caminho nenhum) e **gastar o
/// orçamento inteiro de uma vez** (a sessão avisa da falha mais de uma vez, e
/// cada aviso agendaria a sua própria tentativa).
///
/// Fora da tela, isto se testa sem montar widget, sem WebRTC e sem esperar
/// vinte segundos de relógio.
library;

/// O orçamento de tentativas de uma reconexão, com espera crescente.
class Retentativa {
  Retentativa({List<Duration>? esperas}) : esperas = esperas ?? padrao;

  /// Três, e a razão de não serem mais está no `remote_screen.dart`: falha de
  /// ICE tem duas naturezas indistinguíveis de fora — passageira (trocou de
  /// torre) e estrutural (não há caminho a achar). Três cobrem a primeira e
  /// param cedo na segunda.
  ///
  /// Crescente porque a causa passageira costuma passar em segundos; se não
  /// passou em três, esperar oito custa pouco e acerta mais.
  static const padrao = [
    Duration(seconds: 3),
    Duration(seconds: 8),
    Duration(seconds: 20),
  ];

  final List<Duration> esperas;
  int _usadas = 0;

  /// Quantas já foram gastas. Serve para dizer "2 de 3" a quem está olhando.
  int get tentativa => _usadas;

  int get total => esperas.length;

  bool get esgotou => _usadas >= esperas.length;

  /// A espera até a próxima tentativa, ou `null` quando acabaram.
  ///
  /// Consome o orçamento ao devolver: quem chama já está agendando. Um método
  /// que só consultasse deixaria o incremento por conta de quem chama — e é
  /// exatamente esse incremento esquecido que vira laço infinito.
  Duration? proxima() {
    if (esgotou) return null;
    return esperas[_usadas++];
  }

  /// Deu certo: o orçamento volta ao cheio.
  ///
  /// Sem isto, uma sessão de duas horas que oscilasse quatro vezes gastaria as
  /// três tentativas na primeira meia hora e passaria o resto no modo antigo,
  /// mesmo com a rede já boa.
  void sucesso() => _usadas = 0;
}
