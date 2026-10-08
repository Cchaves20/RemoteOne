import 'package:flutter/material.dart';

import '../l10n/strings.dart';
import '../models/automation.dart';
import '../models/widget_config.dart';
import '../services/app_state.dart';
import '../services/atalhos_do_icone.dart';

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

  /// O widget como vai ficar, desenhado com a escolha ainda não salva.
  Widget _previa(BuildContext context, Strings t) {
    final theme = Theme.of(context);
    final computador =
        _state.devices.where((d) => d.deviceId == _computador).firstOrNull ??
            _state.devices.firstOrNull;
    final botoes = [for (final b in _botoes) if (b != null) b];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(t.widgetsPrevia, style: theme.textTheme.labelLarge),
        const SizedBox(height: 8),
        Container(
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            color: theme.colorScheme.surfaceContainerHighest,
            borderRadius: BorderRadius.circular(22),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Icon(
                    Icons.circle,
                    size: 10,
                    color: (computador?.online ?? false)
                        ? Colors.green
                        : theme.colorScheme.outline,
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      computador?.name ?? t.widgetsSemComputador,
                      style: theme.textTheme.titleSmall,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 14),
              Row(
                children: [
                  for (final b in botoes)
                    Expanded(
                      child: Column(
                        children: [
                          CircleAvatar(
                            radius: 22,
                            backgroundColor: theme.colorScheme.primary.withAlpha(46),
                            child: Icon(iconeDoBotao(b.tipo),
                                color: theme.colorScheme.primary),
                          ),
                          const SizedBox(height: 6),
                          Text(
                            rotuloDoBotao(t, b, _state.automations),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: theme.textTheme.labelSmall,
                          ),
                        ],
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

  List<Widget> _secaoDoWidget(BuildContext context, Strings t) {
    final theme = Theme.of(context);
    final computadores = _state.devices;
    if (computadores.isEmpty) {
      return [Text(t.widgetsSemComputador)];
    }
    // Um computador que saiu da conta não pode ficar escolhido no menu: o
    // valor do `DropdownButton` precisa existir na lista.
    final escolhido = computadores.any((d) => d.deviceId == _computador)
        ? _computador
        : computadores.first.deviceId;
    return [
      Text(t.widgetsComputador, style: theme.textTheme.titleSmall),
      DropdownButton<String>(
        isExpanded: true,
        value: escolhido,
        items: [
          for (final d in computadores)
            DropdownMenuItem(value: d.deviceId, child: Text(d.name)),
        ],
        onChanged: (v) => setState(() => _computador = v),
      ),
      const SizedBox(height: 12),
      for (var i = 0; i < _botoes.length; i++) _escolhaDeBotao(context, t, i),
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
    final atual = _botoes[i]?.chave;
    return Padding(
      padding: const EdgeInsets.only(top: 4),
      child: Row(
        children: [
          SizedBox(
            width: 80,
            child: Text(t.widgetsBotao(i + 1),
                style: Theme.of(context).textTheme.bodyMedium),
          ),
          Expanded(
            child: DropdownButton<String>(
              isExpanded: true,
              // Automação apagada desde a última vez: o menu mostra "Nenhum"
              // em vez de quebrar com um valor que não está na lista.
              value: (atual != null && chaves.contains(atual)) ? atual : '',
              items: [
                DropdownMenuItem(value: '', child: Text(t.widgetsNenhum)),
                for (final o in opcoes)
                  DropdownMenuItem(
                    value: o.chave,
                    child: Row(
                      children: [
                        Icon(iconeDoBotao(o.tipo), size: 18),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            o.tipo == TipoDeBotao.automacao
                                ? t.botaoAutomacao(
                                    rotuloDoBotao(t, o, automacoes))
                                : rotuloDoBotao(t, o, automacoes),
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                      ],
                    ),
                  ),
              ],
              onChanged: (v) => setState(
                () => _botoes[i] = (v == null || v.isEmpty)
                    ? null
                    : BotaoDoWidget.daChave(v),
              ),
            ),
          ),
        ],
      ),
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
          contentPadding: EdgeInsets.zero,
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
