/// Os atalhos que aparecem ao segurar o ícone do Deskside.
///
/// Até quatro automações, tocou e roda. É o atalho mais curto que existe para
/// o recurso: sem abrir a lista, sem escolher nada — e, no iPhone e no
/// Android, sem configurar coisa nenhuma no sistema.
///
/// ## Quais automações
///
/// As escolhidas na tela de widgets (Configurações › Widgets), na ordem dos
/// toques. Sem escolha, as quatro primeiras da lista da conta. Quem decide é
/// `AppState.automacoesDoIcone`.
///
/// ## Como o toque chega à automação
///
/// O sistema avisa o app com o `type` do atalho (`automacao:<id>`). O app
/// guarda o pedido em `AppState.atalhoPendente`, e quem o executa é a tela de
/// computadores, porque é ela que tem onde mostrar a pergunta "em qual
/// computador?" e o resultado. Guardar em vez de executar na hora resolve os
/// dois casos difíceis: o app abrindo do zero (a sessão ainda nem voltou) e o
/// app com bloqueio ligado (a automação espera o desbloqueio).
library;

import 'package:quick_actions/quick_actions.dart';

import '../models/automation.dart';

/// Quantos atalhos o ícone mostra. Os dois sistemas mostram quatro com folga;
/// mais que isso o iPhone corta sem avisar.
const maxAtalhosDoIcone = 4;

const _prefixoAutomacao = 'automacao:';

/// Os itens do menu do ícone para estas automações.
List<ShortcutItem> itensDoIcone(List<Automation> automacoes) => [
      for (final a in automacoes
          .where((a) => a.id.isNotEmpty)
          .take(maxAtalhosDoIcone))
        ShortcutItem(type: '$_prefixoAutomacao${a.id}', localizedTitle: a.name),
    ];

/// A automação que um atalho pede, ou `null` se não for de automação.
String? automacaoDoAtalho(String tipo) {
  if (!tipo.startsWith(_prefixoAutomacao)) return null;
  final id = tipo.substring(_prefixoAutomacao.length);
  return id.isEmpty ? null : id;
}

/// Fala com o sistema. Separado das funções acima para elas serem testáveis
/// sem plugin nenhum.
class AtalhosDoIcone {
  AtalhosDoIcone([QuickActions? sistema]) : _sistema = sistema ?? const QuickActions();

  final QuickActions _sistema;

  /// O que foi publicado por último, para não reescrever o menu do sistema a
  /// cada `notifyListeners` do app — e são muitos.
  String? _publicado;

  Future<void> iniciar(void Function(String tipo) aoTocar) =>
      _sistema.initialize(aoTocar);

  /// Publica os atalhos destas automações, se mudaram desde a última vez.
  /// Lista vazia (saiu da conta) limpa o menu.
  Future<void> sincronizar(List<Automation> automacoes) async {
    final itens = itensDoIcone(automacoes);
    final assinatura =
        itens.map((i) => '${i.type}\u0000${i.localizedTitle}').join('\u0001');
    if (assinatura == _publicado) return;
    _publicado = assinatura;
    try {
      if (itens.isEmpty) {
        await _sistema.clearShortcutItems();
      } else {
        await _sistema.setShortcutItems(itens);
      }
    } catch (_) {
      // Atalho do ícone é conveniência: falhar aqui não pode derrubar nada.
      _publicado = null;
    }
  }
}
