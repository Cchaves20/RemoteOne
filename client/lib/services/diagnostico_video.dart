/// Por que a conexão direta não fechou, em termos de gente.
///
/// ## O que esta troca conserta
///
/// A mensagem que aparecia era esta:
///
///     a conexão de vídeo falhou — ICE Failed;
///     celular: 24 host + 3 srflx + 6 relay; computador: 1 host
///
/// Ela é **verdadeira e inútil**. "ICE", "srflx" e "relay" são vocabulário de
/// quem escreveu o protocolo; para quem está segurando o telefone, aquilo diz
/// só uma coisa: alguma coisa quebrou e eu não sei o quê. Pior: a tela continua
/// funcionando, então a pessoa lê um texto de desastre olhando para algo que
/// está funcionando, e conclui que o produto é instável.
///
/// Só que aqueles números **sabem** o que aconteceu. Um computador que ofereceu
/// apenas `host` é um computador que não conseguiu falar com o servidor de
/// conexão — quase sempre firewall ou antivírus na máquina dele. Os dois lados
/// com `relay` e ainda assim sem fechar é a rede no meio bloqueando. São
/// diagnósticos diferentes, com **ações diferentes**, e estavam ali o tempo
/// todo, escritos numa língua que ninguém fala.
///
/// ## Por que fica fora da tela
///
/// É regra pura sobre dois mapas de contagem: não precisa de widget, de WebRTC
/// nem de rede para ser exercitada. Cada caso abaixo vira um teste com os
/// números que o aparelho realmente produziu.
library;

import '../l10n/strings.dart';

/// O que explica a falha, quando dá para explicar.
enum CausaDaFalha {
  /// O computador não ofereceu candidato nenhum.
  ///
  /// Não é rede ruim: é o agente não tendo respondido. Computador desligado no
  /// meio, agente travado, sinalização perdida.
  computadorNaoRespondeu,

  /// O computador só ofereceu endereços da rede local dele.
  ///
  /// Ele não alcançou o servidor de conexão — nem para descobrir o próprio
  /// endereço público, nem para pedir um repasse. Firewall ou antivírus na
  /// máquina é a causa comum, e é acionável: dá para consertar.
  computadorBloqueado,

  /// O mesmo, do lado de cá.
  celularBloqueado,

  /// Os dois lados tinham por onde tentar, inclusive repasse, e mesmo assim
  /// nenhum caminho fechou. Aí quem bloqueia é a rede no meio.
  redeBloqueia,

  /// Havia candidatos dos dois lados, mas nenhum repasse — e sem repasse duas
  /// redes que não se enxergam não têm como se encontrar.
  semRepasse,

  /// Não dá para afirmar nada. Melhor calar do que chutar: um palpite errado
  /// manda a pessoa mexer no firewall dela à toa.
  indefinida,
}

bool _so(Map<String, int> candidatos, String tipo) =>
    candidatos.isNotEmpty &&
    candidatos.keys.every((k) => k == tipo) &&
    (candidatos[tipo] ?? 0) > 0;

bool _tem(Map<String, int> candidatos, String tipo) =>
    (candidatos[tipo] ?? 0) > 0;

/// Lê as contagens de candidatos e devolve a causa provável.
///
/// A ordem das perguntas é do mais específico e mais acionável para o mais
/// vago — quem lê a mensagem precisa receber primeiro aquilo sobre o que pode
/// fazer alguma coisa.
CausaDaFalha diagnosticar({
  required Map<String, int> celular,
  required Map<String, int> computador,
}) {
  // 1. Silêncio do outro lado. Nem chega a ser problema de rede.
  if (computador.isEmpty) return CausaDaFalha.computadorNaoRespondeu;

  // 2. Um lado sem saída para a internet. É o caso com conserto conhecido, e
  //    por isso vem antes: dizer "a rede bloqueia" a quem tem um antivírus
  //    ligado manda a pessoa procurar no lugar errado.
  if (_so(computador, 'host')) return CausaDaFalha.computadorBloqueado;
  if (_so(celular, 'host')) return CausaDaFalha.celularBloqueado;

  // 3. Os dois tinham repasse e ainda assim não fechou: sobra a rede no meio.
  if (_tem(celular, 'relay') && _tem(computador, 'relay')) {
    return CausaDaFalha.redeBloqueia;
  }

  // 4. Ninguém tinha repasse. Duas redes que não se enxergam precisam dele.
  if (!_tem(celular, 'relay') && !_tem(computador, 'relay')) {
    return CausaDaFalha.semRepasse;
  }

  return CausaDaFalha.indefinida;
}

/// A frase que vai para a tela, na língua do app.
///
/// Fica aqui, e não na tela, por dois motivos: o `switch` exaustivo obriga
/// quem acrescentar uma causa nova a escrever o texto dela (o compilador
/// recusa o contrário), e assim a tradução pode ser conferida por teste, sem
/// subir uma tela de WebRTC para ler uma frase.
String textoDaCausa(Strings t, CausaDaFalha causa) => switch (causa) {
      CausaDaFalha.computadorNaoRespondeu => t.videoCausaComputadorMudo,
      CausaDaFalha.computadorBloqueado => t.videoCausaComputadorBloqueado,
      CausaDaFalha.celularBloqueado => t.videoCausaCelularBloqueado,
      CausaDaFalha.redeBloqueia => t.videoCausaRedeBloqueia,
      CausaDaFalha.semRepasse => t.videoCausaSemRepasse,
      CausaDaFalha.indefinida => t.videoCausaIndefinida,
    };
