import 'package:flutter/material.dart';

import '../l10n/strings.dart';
import '../models/automation.dart';
import '../models/widget_config.dart';
import '../services/app_state.dart';
import '../services/atalhos_do_icone.dart';
import '../theme.dart';
import '../widgets/identidade.dart';

/// Configurações › Widgets: o widget da tela inicial e os atalhos do ícone.
///
/// A escolha vai para o servidor (`/api/v1/widget`), porque é de lá que o
/// widget lê — ele é um programa à parte do app. A prévia no topo é desenhada
/// aqui, com a escolha ainda não salva, para a pessoa ver o resultado antes.
class WidgetsScreen extends StatefulWidget {
  const WidgetsScreen({super.key, required this.state});

  final AppState state;

  @override
  State<WidgetsScreen> createState() => _WidgetsScreenState();
}

/// O ícone de cada tipo de botão. O mesmo desenho do widget nativo.
IconData iconeDoBotao(TipoDeBotao tipo) => switch (tipo) {
      TipoDeBotao.apresentacao => Icons.co_present_outlined,
      TipoDeBotao.tocarPausar => Icons.play_arrow_rounded,
      TipoDeBotao.automacao => Icons.bolt,
      TipoDeBotao.suspender => Icons.bedtime_outlined,
      TipoDeBotao.volumeMais => Icons.volume_up,
      TipoDeBotao.volumeMenos => Icons.volume_down,
      TipoDeBotao.silenciar => Icons.volume_off,
    };

/// O texto de cada botão, curto: cabe embaixo do ícone no widget.
String rotuloDoBotao(Strings t, BotaoDoWidget botao, List<Automation> automacoes) =>
    switch (botao.tipo) {
      TipoDeBotao.apresentacao => t.presentationMode,
      TipoDeBotao.tocarPausar => t.botaoTocarPausar,
      TipoDeBotao.suspender => t.suspend,
      TipoDeBotao.volumeMais => t.botaoVolumeMais,
      TipoDeBotao.volumeMenos => t.botaoVolumeMenos,
      TipoDeBotao.silenciar => t.botaoSilenciar,
      TipoDeBotao.automacao => automacoes
              .where((a) => a.id == botao.automacaoId)
              .map((a) => a.name)
              .firstOrNull ??
          botao.automacaoNome ??
          '',
    };

class _WidgetsScreenState extends State<WidgetsScreen> {
  String? _computador;

  /// As três posições. `null` = posição vazia.
  final List<BotaoDoWidget?> _botoes = [null, null, null];
  final List<String> _atalhos = [];
  bool _carregando = true;
  bool _salvando = false;

  AppState get _state => widget.state;

  @override
  void initState() {
    super.initState();
    _carregar();
  }

  Future<void> _carregar() async {
    await Future.wait([_state.carregarWidget(), _state.loadAutomations()]);
    if (!mounted) return;
    final atual = _state.widget ?? const ConfigDoWidget();
    setState(() {
      _computador = atual.deviceId;
      for (var i = 0; i < _botoes.length; i++) {
        _botoes[i] = i < atual.botoes.length ? atual.botoes[i] : null;
      }
      _atalhos
        ..clear()
        ..addAll(atual.atalhos);
      _carregando = false;
    });
  }

  Future<void> _salvar() async {
    final messenger = ScaffoldMessenger.of(context);
    final t = _state.t;
    setState(() => _salvando = true);
    try {
      await _state.salvarWidget(ConfigDoWidget(
        deviceId: _computador,
        botoes: [for (final b in _botoes) if (b != null) b],
        atalhos: List.of(_atalhos),
      ));
      messenger.showSnackBar(SnackBar(content: Text(t.widgetsSalvo)));
    } catch (e) {
      messenger.showSnackBar(SnackBar(content: Text(e.toString())));
    } finally {
      if (mounted) setState(() => _salvando = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = _state.t;
    return Scaffold(
      appBar: AppBar(
        title: Text(t.widgetsTitulo),
        actions: [
          TextButton(
            onPressed: (_carregando || _salvando) ? null : _salvar,
            child: Text(t.save),
          ),
        ],
      ),
      body: _carregando
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 32),
              children: [
                _previa(context, t),
                const SizedBox(height: 8),
                Text(
                  t.widgetsComoAdicionar,
                  style: Theme.of(context).textTheme.bodySmall,
                ),
                const SizedBox(height: 24),
                ..._secaoDoWidget(context, t),
                const SizedBox(height: 28),
                ..._secaoDosAtalhos(context, t),
              ],
            ),
    );
  }

  /// O widget como vai ficar, desenhado com a escolha ainda não salva: o
  /// monitor aceso ou apagado e as teclas em relevo, como o widget de verdade.
  Widget _previa(BuildContext context, Strings t) {
    final theme = Theme.of(context);
    final c = context.cores;
    final computador =
        _state.devices.where((d) => d.deviceId == _computador).firstOrNull ??
            _state.devices.firstOrNull;
    final online = computador?.online ?? false;
    final botoes = [for (final b in _botoes) if (b != null) b];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(t.widgetsPrevia, style: theme.textTheme.labelLarge),
        const SizedBox(height: 8),
        Container(
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            color: c.superficie,
            borderRadius: BorderRadius.circular(24),
            border: Border.all(color: c.linha),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  MonitorDeskside(ligado: online, largura: 40, comPe: false),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      computador?.name ?? t.widgetsSemComputador,
                      style: theme.textTheme.titleSmall,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  Text(online ? t.online : t.offline,
                      style: TextStyle(fontSize: 12, color: online ? c.led : c.texto3)),
                ],
              ),
              const SizedBox(height: 14),
              Row(
                children: [
                  for (final b in botoes)
                    Expanded(
                      child: Container(
                        height: 74,
                        margin: const EdgeInsets.symmetric(horizontal: 4),
                        padding: const EdgeInsets.symmetric(horizontal: 4),
                        decoration: BoxDecoration(
                          color: c.tecla,
                          borderRadius: BorderRadius.circular(16),
                          border: Border(bottom: BorderSide(color: c.teclaSombra, width: 3)),
                        ),
                        child: Column(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            Icon(iconeDoBotao(b.tipo), color: c.aoVivo, size: 22),
                            const SizedBox(height: 6),
                            Text(
                              rotuloDoBotao(t, b, _state.automations),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(fontSize: 11, color: c.teclaTexto),
                            ),
                          ],
                        ),
                      ),
                    ),
                ],
              ),
            ],
          ),
        ),
      ],
    );
  }

  /// Uma escolha que abre uma lista numa folha de baixo, com o atual marcado.
  ///
  /// No lugar dos menus de seta com sublinhado: eles tinham cara de formulário
  /// antigo e espremiam o nome da automação num campo estreito.
  Widget _linhaDeEscolha({
    required String rotulo,
    required String valor,
    IconData? icone,
    required VoidCallback onTap,
  }) {
    final c = context.cores;
    return ListTile(
      title: Text(rotulo),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (icone != null) ...[
            Icon(icone, size: 18, color: c.aoVivo),
            const SizedBox(width: 6),
          ],
          ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 180),
            child: Text(valor,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(fontSize: 14, color: c.texto2)),
          ),
          const SizedBox(width: 4),
          Icon(Icons.chevron_right, size: 20, color: c.texto3),
        ],
      ),
      onTap: onTap,
    );
  }

  Future<String?> _escolherDaLista(
    String titulo,
    List<(String chave, String rotulo, IconData? icone)> opcoes,
    String? atual,
  ) {
    return showModalBottomSheet<String>(
      context: context,
      isScrollControlled: true,
      builder: (folha) {
        final c = folha.cores;
        return SafeArea(
          child: ConstrainedBox(
            constraints: BoxConstraints(maxHeight: MediaQuery.sizeOf(folha).height * 0.7),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(20, 0, 20, 8),
                  child: Text(titulo, style: Theme.of(folha).textTheme.titleLarge),
                ),
                Flexible(
                  child: ListView(
                    shrinkWrap: true,
                    children: [
                      for (final (chave, rotulo, icone) in opcoes)
                        ListTile(
                          leading: icone == null ? null : Icon(icone),
                          title: Text(rotulo),
                          trailing: chave == atual
                              ? Icon(Icons.check_rounded, color: c.aoVivo)
                              : null,
                          onTap: () => Navigator.pop(folha, chave),
                        ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  List<Widget> _secaoDoWidget(BuildContext context, Strings t) {
    final c = context.cores;
    final computadores = _state.devices;
    if (computadores.isEmpty) {
      return [Text(t.widgetsSemComputador)];
    }
    // Um computador que saiu da conta não pode ficar escolhido: vale o
    // primeiro da lista.
    final escolhido = computadores.firstWhere(
      (d) => d.deviceId == _computador,
      orElse: () => computadores.first,
    );
    return [
      Material(
        color: c.superficie,
        clipBehavior: Clip.antiAlias,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(18),
          side: BorderSide(color: c.linha),
        ),
        child: Column(
          children: [
            _linhaDeEscolha(
              rotulo: t.widgetsComputador,
              valor: escolhido.name,
              onTap: () async {
                final v = await _escolherDaLista(
                  t.widgetsComputador,
                  [for (final d in computadores) (d.deviceId, d.name, null)],
                  escolhido.deviceId,
                );
                if (v != null) setState(() => _computador = v);
              },
            ),
            for (var i = 0; i < _botoes.length; i++) _escolhaDeBotao(context, t, i),
          ],
        ),
      ),
    ];
  }

  Widget _escolhaDeBotao(BuildContext context, Strings t, int i) {
    final automacoes = _state.automations;
    final opcoes = <BotaoDoWidget>[
      for (final tipo in TipoDeBotao.values)
        if (tipo != TipoDeBotao.automacao) BotaoDoWidget(tipo),
      for (final a in automacoes)
        BotaoDoWidget(TipoDeBotao.automacao, automacaoId: a.id),
    ];
    final chaves = {for (final o in opcoes) o.chave};
    // Automação apagada desde a última vez: mostra "Nenhum" em vez de um
    // valor que não existe mais.
    final atualValido = _botoes[i] != null && chaves.contains(_botoes[i]!.chave)
        ? _botoes[i]
        : null;
    String rotulo(BotaoDoWidget o) => o.tipo == TipoDeBotao.automacao
        ? t.botaoAutomacao(rotuloDoBotao(t, o, automacoes))
        : rotuloDoBotao(t, o, automacoes);
    return _linhaDeEscolha(
      rotulo: t.widgetsBotao(i + 1),
      valor: atualValido == null ? t.widgetsNenhum : rotuloDoBotao(t, atualValido, automacoes),
      icone: atualValido == null ? null : iconeDoBotao(atualValido.tipo),
      onTap: () async {
        final v = await _escolherDaLista(
          t.widgetsBotao(i + 1),
          [
            ('', t.widgetsNenhum, null),
            for (final o in opcoes) (o.chave, rotulo(o), iconeDoBotao(o.tipo)),
          ],
          atualValido?.chave ?? '',
        );
        if (v == null) return;
        setState(() => _botoes[i] = v.isEmpty ? null : BotaoDoWidget.daChave(v));
      },
    );
  }

  List<Widget> _secaoDosAtalhos(BuildContext context, Strings t) {
    final theme = Theme.of(context);
    final automacoes = _state.automations;
    return [
      Text(t.widgetsAtalhosTitulo, style: theme.textTheme.titleSmall),
      const SizedBox(height: 4),
      Text(t.widgetsAtalhosDica, style: theme.textTheme.bodySmall),
      const SizedBox(height: 8),
      for (final a in automacoes)
        CheckboxListTile(
          value: _atalhos.contains(a.id),
          title: Text(a.name),
          // A posição na fila: a ordem dos toques é a ordem no menu do ícone.
          secondary: _atalhos.contains(a.id)
              ? CircleAvatar(
                  radius: 12,
                  child: Text('${_atalhos.indexOf(a.id) + 1}',
                      style: const TextStyle(fontSize: 12)),
                )
              : null,
          onChanged: (marcado) {
            setState(() {
              if (marcado == true) {
                if (_atalhos.length >= maxAtalhosDoIcone) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(content: Text(t.widgetsAtalhosMaximo)),
                  );
                  return;
                }
                _atalhos.add(a.id);
              } else {
                _atalhos.remove(a.id);
              }
            });
          },
        ),
    ];
  }
}
