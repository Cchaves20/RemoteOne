import 'package:flutter/material.dart';

import '../l10n/strings.dart';
import '../models/automation.dart';
import '../models/control_profile.dart';
import '../models/device.dart';
import '../models/remote_app.dart';
import '../models/window_zone.dart';
import '../services/app_state.dart';
import '../theme.dart';
import '../widgets/layout_picker.dart';
import 'app_picker_screen.dart';

/// Criação e edição de uma automação.
///
/// Mora ao lado do editor de perfis, e a semelhança entre os dois é
/// deliberada: nome, ícone, uma lista, os computadores. A diferença é uma só e
/// aparece na lista — aqui a ordem **é** o recurso, e por isso ela se arrasta.
class AutomationEditorScreen extends StatefulWidget {
  const AutomationEditorScreen({super.key, required this.state, this.automation});

  final AppState state;

  /// `null` = automação nova.
  final Automation? automation;

  @override
  State<AutomationEditorScreen> createState() => _AutomationEditorScreenState();
}

class _AutomationEditorScreenState extends State<AutomationEditorScreen> {
  late final TextEditingController _nome =
      TextEditingController(text: widget.automation?.name ?? '');
  late String _icone = widget.automation?.icon ?? 'tune';
  late List<AutomationStep> _passos = [...?widget.automation?.steps];
  /// Onde a automação roda.
  ///
  /// Numa automação nova com **um só** computador na conta, ele já vem
  /// escolhido. "Perguntar na hora" só ganha sentido com duas máquinas, e
  /// deixá-lo como padrão trancava o agendamento atrás de uma escolha que a
  /// pessoa não tinha motivo para fazer — e nem sabia que precisava.
  late String _deviceId = widget.automation?.deviceId ??
      (widget.state.devices.length == 1
          ? widget.state.devices.first.deviceId
          : '');
  late String _hora = widget.automation?.scheduleTime ?? '';
  late List<int> _dias = [...?widget.automation?.scheduleDays];
  bool _salvando = false;

  /// Como a tela é dividida pelos passos que abrem programas.
  ///
  /// Deduzido das zonas guardadas, como no editor de perfis: um campo separado
  /// poderia discordar delas, e ninguém saberia em qual acreditar.
  late WindowLayout? _layout =
      WindowLayout.ofZones(_passos.map((p) => p.zone));

  @override
  void dispose() {
    _nome.dispose();
    super.dispose();
  }

  void _avisar(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
  }

  int get _quantosAbrem =>
      _passos.where((p) => p.kind == AutomationStep.kindLaunch).length;

  Future<void> _salvar() async {
    final t = widget.state.t;
    final nome = _nome.text.trim();
    if (nome.isEmpty) {
      _avisar(t.automationNameRequired);
      return;
    }
    if (_passos.isEmpty) {
      // Uma automação sem passo nenhum é um botão que não faz nada. O servidor
      // também recusa rodá-la, mas dizer isso aqui evita a viagem.
      _avisar(t.automationEmpty);
      return;
    }
    setState(() => _salvando = true);
    final automacao = Automation(
      // Automação nova ainda não tem identificador: quem o gera é o servidor.
      id: widget.automation?.id ?? '',
      name: nome,
      icon: _icone,
      steps: _passos,
      deviceId: _deviceId,
      // Sem computador não há agenda: quem a guarda é a máquina. O servidor
      // recusa, e limpar aqui evita um 422 no fim de um formulário inteiro —
      // a tela já esconde o horário nesse caso.
      scheduleTime: _deviceId.isEmpty ? '' : _hora,
      scheduleDays: _deviceId.isEmpty || _hora.isEmpty ? const [] : _dias,
    );
    try {
      if (widget.automation == null) {
        await widget.state.createAutomation(automacao);
      } else {
        await widget.state.updateAutomation(automacao);
      }
      if (mounted) Navigator.of(context).pop(true);
    } catch (e) {
      if (!mounted) return;
      setState(() => _salvando = false);
      _avisar(e.toString());
    }
  }

  void _trocar(int i, AutomationStep novo) {
    if (!mounted) return;
    setState(() {
      _passos = [
        for (var k = 0; k < _passos.length; k++) k == i ? novo : _passos[k],
      ];
    });
  }

  void _reordenar(int de, int para) {
    // O `onReorder` entrega o índice de destino contando a posição antiga
    // ainda ocupada; um item que desce precisa deste ajuste. (É exatamente isto
    // que o `onReorderItem` novo faz sozinho — ver a nota no `build`.)
    if (para > de) para -= 1;
    setState(() {
      final nova = [..._passos];
      nova.insert(para, nova.removeAt(de));
      _passos = nova;
    });
  }

  // --- adicionar passos -------------------------------------------------------

  Future<void> _adicionarPasso() async {
    final t = widget.state.t;
    final tipo = await showModalBottomSheet<String>(
      context: context,
      backgroundColor: const Color(0xFF14162C),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (sheet) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const SizedBox(height: 8),
            for (final e in <(String, String, IconData)>[
              (AutomationStep.kindLaunch, t.stepKindLaunch, Icons.launch),
              (AutomationStep.kindClose, t.stepKindClose, Icons.close),
              // "Salvar" vem **antes** de "fechar tudo" na lista, e é de
              // propósito: é a ordem em que os dois se usam, e a lista é o
              // único lugar onde essa dica cabe sem virar um aviso.
              (
                AutomationStep.kindSaveAll,
                t.stepKindSaveAll,
                Icons.save_outlined
              ),
              (
                AutomationStep.kindCloseAll,
                t.stepKindCloseAll,
                Icons.clear_all
              ),
              (AutomationStep.kindInput, t.stepKindKeys, Icons.keyboard),
              (AutomationStep.kindMedia, t.stepKindMedia, Icons.volume_up),
              (
                AutomationStep.kindBrightness,
                t.stepKindBrightness,
                Icons.brightness_6
              ),
              (
                AutomationStep.kindPower,
                t.stepKindPower,
                Icons.power_settings_new
              ),
            ])
              ListTile(
                leading: Icon(e.$3, color: Colors.white70),
                title: Text(e.$2, style: const TextStyle(color: Colors.white)),
                onTap: () => Navigator.of(sheet).pop(e.$1),
              ),
          ],
        ),
      ),
    );
    if (tipo == null || !mounted) return;

    switch (tipo) {
      case AutomationStep.kindLaunch:
        await _passoAbrir();
      case AutomationStep.kindClose:
        await _passoFechar();
      case AutomationStep.kindCloseAll:
        // Sem diálogo: não há o que escolher. É o único passo que entra na
        // lista com um toque só, e é de propósito — "fecha tudo" não tem
        // parâmetro, e inventar uma tela de confirmação aqui só atrasaria
        // quem já sabe o que pediu. O aviso de passo destrutivo continua
        // valendo na hora de rodar.
        _acrescentar(AutomationStep.closeAll());
      case AutomationStep.kindSaveAll:
        // Uma folha só para explicar o alcance. Sem ela, a pessoa põe o passo
        // achando que ele salva tudo que está aberto — e descobriria o
        // contrário na noite em que perdesse algo.
        await _passoSalvar();
      case AutomationStep.kindInput:
        await _passoTeclas();
      case AutomationStep.kindMedia:
        await _passoMidia();
      case AutomationStep.kindBrightness:
        await _passoBrilho();
      case AutomationStep.kindPower:
        await _passoEnergia();
    }
  }

  void _acrescentar(AutomationStep passo) {
    // Vem sempre depois de uma folha ou diálogo, ou seja, depois de um `await`:
    // sem a guarda, sair da tela enquanto a folha está aberta faria o `setState`
    // estourar numa tela que já não existe.
    if (!mounted) return;
    setState(() => _passos = [..._passos, passo]);
  }

  Future<void> _passoAbrir() async {
    final t = widget.state.t;
    final computadores = widget.state.devices;
    if (computadores.isEmpty) {
      _avisar(t.profileNoComputers);
      return;
    }
    // De qual computador vem a lista: o da automação, se ela fixou um. É quase
    // sempre o certo, e poupa uma pergunta a cada passo.
    final fixado = computadores.where((d) => d.deviceId == _deviceId);
    final onde = fixado.isNotEmpty
        ? fixado.first
        : computadores.length == 1
            ? computadores.first
            : await _escolherComputador(computadores, t.profilePickFrom);
    if (onde == null || !mounted) return;

    final escolhidos = await Navigator.of(context).push<List<RemoteApp>>(
      MaterialPageRoute(
        builder: (_) => AppPickerScreen(state: widget.state, device: onde),
      ),
    );
    if (escolhidos == null) return;
    for (final a in escolhidos) {
      _acrescentar(AutomationStep.launch(appName: a.name, path: a.id));
    }
  }

  Future<void> _passoFechar() async {
    final t = widget.state.t;
    final controle = TextEditingController();
    final nome = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(t.stepKindClose),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            TextField(
              controller: controle,
              autofocus: true,
              decoration: InputDecoration(hintText: t.stepCloseHint),
              onSubmitted: (v) => Navigator.of(ctx).pop(v.trim()),
            ),
            const SizedBox(height: 12),
            Text(
              t.stepCloseGentle,
              style: const TextStyle(color: Colors.white54, fontSize: 12),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: Text(t.cancel),
          ),
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(controle.text.trim()),
            child: Text(t.save),
          ),
        ],
      ),
    );
    controle.dispose();
    if (nome == null || nome.isEmpty) return;
    _acrescentar(AutomationStep.close(processName: nome));
  }

  /// Os atalhos que uma automação pode mandar são os dos perfis de fábrica.
  ///
  /// Não é preguiça de catálogo: são exatamente as teclas que a pessoa já
  /// dispara tocando nos botões, cada uma com o formato certo já resolvido
  /// (tecla com nome próprio, letra solta ou combinação). Um campo livre de
  /// "escreva o atalho" ofereceria combinações que o computador não sabe
  /// receber, e a falha só apareceria na hora de rodar.
  Future<void> _passoTeclas() async {
    final t = widget.state.t;
    final escolhida = await showModalBottomSheet<ProfileAction>(
      context: context,
      backgroundColor: const Color(0xFF14162C),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      isScrollControlled: true,
      builder: (sheet) => SafeArea(
        child: DraggableScrollableSheet(
          expand: false,
          initialChildSize: 0.7,
          builder: (_, controller) => ListView(
            controller: controller,
            children: [
              for (final perfil in ControlProfile.builtIn) ...[
                Padding(
                  padding: const EdgeInsets.fromLTRB(18, 16, 18, 6),
                  child: Text(
                    perfil.name(t),
                    style: const TextStyle(color: Colors.white54, fontSize: 12),
                  ),
                ),
                for (final a in perfil.actions)
                  // Brilho tem passo próprio (com valor absoluto), e abrir
                  // programa também: aqui só entram as ações que são teclas.
                  if (!a.isBrightness && !a.isLaunch && !a.isOpenAll)
                    ListTile(
                      dense: true,
                      leading: Icon(a.icon, color: Colors.white70),
                      title: Text(a.label(t),
                          style: const TextStyle(color: Colors.white)),
                      trailing: Text(
                        a.shortcut,
                        style:
                            const TextStyle(color: Colors.white38, fontSize: 12),
                      ),
                      onTap: () => Navigator.of(sheet).pop(a),
                    ),
              ],
            ],
          ),
        ),
      ),
    );
    if (escolhida == null) return;
    _acrescentar(AutomationStep.input(keys: escolhida.input));
  }

  /// O passo de salvar, com o alcance dito antes de entrar na lista.
  ///
  /// Não há o que escolher — como o "fechar tudo", ele pergunta ao computador o
  /// que está aberto na hora de rodar. A folha existe só para uma frase, e essa
  /// frase é o recurso: sem ela a pessoa põe o passo achando que ele salva
  /// **tudo**, e descobriria o contrário na noite em que perdesse algo.
  Future<void> _passoSalvar() async {
    final t = widget.state.t;
    final ok = await showModalBottomSheet<bool>(
      context: context,
      backgroundColor: const Color(0xFF14162C),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (sheet) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(18, 18, 18, 12),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(t.stepKindSaveAll,
                  style: const TextStyle(color: Colors.white, fontSize: 16)),
              const SizedBox(height: 8),
              Text(t.stepSaveAllHint,
                  style: const TextStyle(color: Colors.white54, fontSize: 13)),
              const SizedBox(height: 16),
              Align(
                alignment: Alignment.centerRight,
                child: TextButton(
                  onPressed: () => Navigator.of(sheet).pop(true),
                  child: Text(t.automationAddStep),
                ),
              ),
            ],
          ),
        ),
      ),
    );
    if (ok != true) return;
    _acrescentar(AutomationStep.saveAll());
  }

  Future<void> _passoMidia() async {
    final t = widget.state.t;
    final acao = await _escolherDeLista(
      t.stepKindMedia,
      AutomationStep.mediaActions,
      (a) => t.mediaLabel(a),
    );
    if (acao == null) return;
    _acrescentar(AutomationStep.media(action: acao));
  }

  Future<void> _passoEnergia() async {
    final t = widget.state.t;
    final acao = await _escolherDeLista(
      t.stepKindPower,
      AutomationStep.powerActions,
      (a) => t.powerLabel(a),
    );
    if (acao == null) return;
    _acrescentar(AutomationStep.power(action: acao));
  }

  Future<void> _passoBrilho() async {
    final t = widget.state.t;
    var nivel = 60;
    final escolhido = await showDialog<int>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, refazer) => AlertDialog(
          title: Text(t.stepKindBrightness),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text('$nivel%',
                  style: const TextStyle(color: Colors.white, fontSize: 22)),
              Slider(
                value: nivel.toDouble(),
                max: 100,
                divisions: 20,
                label: '$nivel%',
                onChanged: (v) => refazer(() => nivel = v.round()),
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(),
              child: Text(t.cancel),
            ),
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(nivel),
              child: Text(t.save),
            ),
          ],
        ),
      ),
    );
    if (escolhido == null) return;
    _acrescentar(AutomationStep.brightness(level: escolhido));
  }

  Future<String?> _escolherDeLista(
    String titulo,
    List<String> opcoes,
    String Function(String) rotulo,
  ) {
    return showModalBottomSheet<String>(
      context: context,
      backgroundColor: const Color(0xFF14162C),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (sheet) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.all(16),
              child: Text(titulo,
                  style: const TextStyle(color: Colors.white, fontSize: 15)),
            ),
            for (final o in opcoes)
              ListTile(
                title: Text(rotulo(o),
                    style: const TextStyle(color: Colors.white)),
                onTap: () => Navigator.of(sheet).pop(o),
              ),
          ],
        ),
      ),
    );
  }

  Future<Device?> _escolherComputador(List<Device> lista, String titulo) {
    return showModalBottomSheet<Device>(
      context: context,
      backgroundColor: const Color(0xFF14162C),
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.all(16),
              child: Text(titulo,
                  style: const TextStyle(color: Colors.white, fontSize: 15)),
            ),
            for (final d in lista)
              ListTile(
                leading: const Icon(Icons.computer, color: Colors.white70),
                title: Text(d.name, style: const TextStyle(color: Colors.white)),
                onTap: () => Navigator.of(ctx).pop(d),
              ),
          ],
        ),
      ),
    );
  }

  /// Quanto esperar depois de um passo, em opções prontas.
  ///
  /// Não é um campo de texto: o que importa é a ordem de grandeza ("deixa abrir"
  /// contra "segue direto"), e digitar 1837 ms seria precisão sobre um número
  /// que ninguém tem como medir daqui.
  static const List<int> _esperas = [0, 500, 1000, 1500, 2000, 3000, 5000, 10000];

  Future<void> _editarEspera(int i) async {
    final t = widget.state.t;
    final atual = _passos[i].waitMs ?? 0;
    final novo = await showModalBottomSheet<int>(
      context: context,
      backgroundColor: const Color(0xFF14162C),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (sheet) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(18, 18, 18, 2),
              child: Text(t.stepWait,
                  style: const TextStyle(color: Colors.white, fontSize: 15)),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(18, 0, 18, 12),
              child: Text(t.stepWaitHint,
                  style: const TextStyle(color: Colors.white38, fontSize: 12)),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(18, 0, 18, 18),
              child: Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  for (final ms in _esperas)
                    ChoiceChip(
                      selected: ms == atual,
                      label: Text(t.stepSeconds(ms)),
                      onSelected: (_) => Navigator.of(sheet).pop(ms),
                    ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
    if (novo == null) return;
    // Zero vira ausência de campo: mandar `wait_ms: 0` seria pedir ao
    // computador uma pausa de duração nenhuma.
    _trocar(i, _passos[i].comEspera(novo == 0 ? null : novo));
  }

  @override
  Widget build(BuildContext context) {
    final t = widget.state.t;
    return Scaffold(
      appBar: AppBar(
        title: Text(
            widget.automation == null ? t.automationNew : t.automationEdit),
        actions: [
          TextButton(
            onPressed: _salvando ? null : _salvar,
            child: Text(t.save),
          ),
        ],
      ),
      // `CustomScrollView` e não `ListView`: a lista de passos precisa ser
      // arrastável, e um `ReorderableListView` encolhido dentro de outra lista
      // é duas rolagens disputando o mesmo dedo. Com slivers há uma rolagem só,
      // e o `SliverReorderableList` cuida do arrasto.
      body: CustomScrollView(
        slivers: [
          SliverPadding(
            padding: const EdgeInsets.fromLTRB(18, 12, 18, 0),
            sliver: SliverList.list(children: [
              TextField(
                controller: _nome,
                maxLength: 60,
                style: const TextStyle(color: Colors.white),
                decoration: InputDecoration(
                  labelText: t.profileName,
                  hintText: t.automationNameHint,
                ),
              ),
              const SizedBox(height: 12),
              Text(t.profileIcon,
                  style: const TextStyle(color: Colors.white54, fontSize: 12)),
              const SizedBox(height: 8),
              Wrap(
                spacing: 10,
                runSpacing: 10,
                children: [
                  for (final e in profileIcons.entries)
                    GestureDetector(
                      onTap: () => setState(() => _icone = e.key),
                      child: Container(
                        width: 46,
                        height: 46,
                        decoration: BoxDecoration(
                          color: _icone == e.key ? auroraViolet : Colors.white10,
                          borderRadius: BorderRadius.circular(12),
                        ),
                        child: Icon(e.value, color: Colors.white),
                      ),
                    ),
                ],
              ),
              // "Onde rodar" e "Horário" vêm **antes** dos passos, e nesta
              // ordem, porque uma coisa depende da outra: quem guarda a agenda
              // é o computador. No fim da tela, depois de uma lista de passos
              // que pode ter vinte itens, o horário simplesmente não era
              // encontrado.
              const Divider(height: 32, color: Colors.white12),
              Text(t.automationWhere,
                  style: const TextStyle(color: Colors.white, fontSize: 15)),
              // `ListTile` com o desenho do rádio, e não `RadioListTile`: o
              // `groupValue`/`onChanged` dele está a caminho da aposentadoria
              // nas versões novas do Flutter, e o Codemagic compila em
              // `stable` - que pode estar à frente da máquina de quem escreve.
              // Um aviso de API obsoleta pararia o build por um detalhe visual.
              _escolha('', t.automationWhereAsk),
              for (final d in widget.state.devices) _escolha(d.deviceId, d.name),
              const Divider(height: 32, color: Colors.white12),
              ..._agenda(t),
              const Divider(height: 32, color: Colors.white12),
              Row(
                children: [
                  Expanded(
                    child: Text(t.automationSteps,
                        style: const TextStyle(color: Colors.white, fontSize: 15)),
                  ),
                  TextButton.icon(
                    // O teto é o do servidor e o do agente: passar dele daria um
                    // 422 na hora de salvar, depois de a pessoa montar tudo.
                    onPressed: _passos.length >= 24 ? null : _adicionarPasso,
                    icon: const Icon(Icons.add),
                    label: Text(t.automationAddStep),
                  ),
                ],
              ),
              if (_passos.isEmpty)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 8),
                  child: Text(t.automationNoSteps,
                      style:
                          const TextStyle(color: Colors.white38, fontSize: 12)),
                ),
            ]),
          ),
          SliverPadding(
            padding: const EdgeInsets.symmetric(horizontal: 18),
            sliver: SliverReorderableList(
              itemCount: _passos.length,
              // Ver a nota igual em `profiles_screen.dart`, inclusive o aviso
              // sobre apagar o ajuste de índice ao migrar.
              // ignore: deprecated_member_use
              onReorder: _reordenar,
              itemBuilder: (context, i) => _linha(i, t),
            ),
          ),
          SliverPadding(
            padding: const EdgeInsets.fromLTRB(18, 0, 18, 32),
            sliver: SliverList.list(children: [
              // O seletor de layout vem depois da lista, e só com dois programas
              // ou mais: com um só não há tela para dividir.
              if (_quantosAbrem >= 2) ...[
                const SizedBox(height: 8),
                LayoutPicker(
                  selected: _layout,
                  strings: t,
                  onSelect: (l) => setState(() {
                    _layout = l;
                    // Trocar de layout invalida as zonas antigas: uma célula da
                    // grade de dois não é uma célula da grade de três.
                    _passos = [for (final p in _passos) p.comZona(null)];
                  }),
                ),
              ],
            ]),
          ),
        ],
      ),
    );
  }

  /// A seção de horário, **depois** da escolha do computador.
  ///
  /// Nessa ordem porque uma depende da outra: quem guarda a agenda é a máquina,
  /// e sem computador escolhido não há a quem mandá-la. Mostrar o horário antes
  /// deixaria a pessoa preencher algo que o servidor vai recusar no fim.
  List<Widget> _agenda(Strings t) {
    final semComputador = _deviceId.isEmpty;
    return [
      Text(t.automationSchedule,
          style: const TextStyle(color: Colors.white, fontSize: 15)),
      if (semComputador)
        Padding(
          padding: const EdgeInsets.only(top: 8),
          child: Text(t.automationScheduleNeedsDevice,
              style: const TextStyle(color: Colors.white38, fontSize: 12)),
        )
      else ...[
        _radio(
          marcado: _hora.isEmpty,
          rotulo: t.automationScheduleOff,
          aoTocar: () => setState(() {
            _hora = '';
            // Os dias vão junto: dias sem horário não agendam nada, e guardá-los
            // faria a próxima edição reaparecer com uma seleção que não valia.
            _dias = [];
          }),
        ),
        _radio(
          marcado: _hora.isNotEmpty,
          rotulo: _hora.isEmpty ? t.automationScheduleOn : _hora,
          aoTocar: _escolherHora,
        ),
        if (_hora.isNotEmpty) ...[
          Padding(
            padding: const EdgeInsets.only(bottom: 12),
            child: Text(t.automationScheduleHint,
                style: const TextStyle(color: Colors.white38, fontSize: 12)),
          ),
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: Text(t.automationScheduleDays,
                style: const TextStyle(color: Colors.white54, fontSize: 12)),
          ),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              for (var d = 0; d < 7; d++)
                FilterChip(
                  selected: _dias.contains(d),
                  label: Text(t.weekdayShort(d)),
                  onSelected: (marcar) => setState(() {
                    _dias = [
                      for (final v in _dias)
                        if (v != d) v,
                      if (marcar) d,
                    ]..sort();
                  }),
                ),
            ],
          ),
          if (_dias.isEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              // Nenhum dia marcado **não** é "nunca": é todos os dias, tanto no
              // servidor quanto no agente. Deixar isso implícito faria a pessoa
              // ler a tela como uma automação desligada.
              child: Text(t.automationScheduleEveryDay,
                  style: const TextStyle(color: Colors.white54, fontSize: 12)),
            ),
        ],
      ],
    ];
  }

  Future<void> _escolherHora() async {
    final partes = _hora.split(':');
    final inicial = partes.length == 2
        ? TimeOfDay(
            hour: int.tryParse(partes[0]) ?? 18,
            minute: int.tryParse(partes[1]) ?? 0,
          )
        : const TimeOfDay(hour: 18, minute: 0);
    final escolhida =
        await showTimePicker(context: context, initialTime: inicial);
    if (escolhida == null || !mounted) return;
    setState(() {
      // Formatado à mão, e não com `format(context)`: o relógio de 12 horas
      // daria "6:00 PM", e o servidor e o agente comparam texto com "18:00".
      _hora = '${escolhida.hour.toString().padLeft(2, '0')}:'
          '${escolhida.minute.toString().padLeft(2, '0')}';
    });
  }

  Widget _radio({
    required bool marcado,
    required String rotulo,
    required VoidCallback aoTocar,
  }) =>
      ListTile(
        contentPadding: EdgeInsets.zero,
        leading: Icon(
          marcado ? Icons.radio_button_checked : Icons.radio_button_unchecked,
          color: marcado ? auroraCyan : Colors.white38,
        ),
        title: Text(rotulo, style: const TextStyle(color: Colors.white)),
        onTap: aoTocar,
      );

  Widget _escolha(String id, String rotulo) => _radio(
        marcado: _deviceId == id,
        rotulo: rotulo,
        aoTocar: () => setState(() => _deviceId = id),
      );

  Widget _linha(int i, Strings t) {
    final p = _passos[i];
    final espera = p.waitMs ?? 0;
    return Padding(
      // `ObjectKey` e não o índice: numa lista que se arrasta, a chave tem de
      // acompanhar o item, não a posição. Funciona porque cada passo é um
      // objeto distinto - ver a nota em `AutomationStep`.
      key: ObjectKey(p),
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        children: [
          ReorderableDragStartListener(
            index: i,
            child: const Padding(
              padding: EdgeInsets.only(right: 8),
              child: Icon(Icons.drag_handle, color: Colors.white38),
            ),
          ),
          Icon(p.icon, size: 18, color: Colors.white70),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(p.describe(t),
                    style: const TextStyle(color: Colors.white, fontSize: 14)),
                if (espera > 0)
                  Text(
                    '${t.stepWait}: ${t.stepSeconds(espera)}',
                    style:
                        const TextStyle(color: Colors.white38, fontSize: 11),
                  ),
              ],
            ),
          ),
          // A zona só aparece nos passos que abrem programa, e só com um
          // layout escolhido: sem grade não há onde encaixar.
          if (p.kind == AutomationStep.kindLaunch && _layout != null)
            ZoneChooser(
              layout: _layout!,
              zone: p.zone,
              strings: t,
              onPick: (z) => _trocar(i, p.comZona(z)),
            ),
          IconButton(
            tooltip: t.stepWait,
            icon: const Icon(Icons.timer_outlined,
                size: 20, color: Colors.white38),
            onPressed: () => _editarEspera(i),
          ),
          IconButton(
            icon: const Icon(Icons.close, size: 20, color: Colors.white38),
            onPressed: () => setState(() {
              final nova = [..._passos]..removeAt(i);
              _passos = nova;
            }),
          ),
        ],
      ),
    );
  }
}

/// Roda uma automação e conta o que aconteceu.
///
/// Vive fora das telas para os dois lugares que rodam automação — a lista, e
/// mais tarde qualquer atalho — se comportarem igual: a mesma confirmação, a
/// mesma pergunta de computador, o mesmo relatório.
Future<void> runAutomationFlow(
  BuildContext context,
  AppState state,
  Automation automacao, {
  String? emQual,
}) async {
  final t = state.t;

  // Passos destrutivos confirmam antes. Só eles: pedir confirmação em toda
  // automação faria o recurso custar dois toques, que é o oposto do que ele
  // existe para fazer.
  if (automacao.hasDestructive) {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(automacao.name),
        content: Text(t.automationConfirmDestructive(automacao.name)),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: Text(t.cancel),
          ),
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: Text(t.automationRun),
          ),
        ],
      ),
    );
    if (ok != true || !context.mounted) return;
  }

  // Onde rodar: o computador fixado, o que o chamador já sabe, ou uma pergunta.
  //
  // `emQual` é o que a barra da tela de controle passa: ali a pessoa está
  // olhando para uma máquina, e perguntar em qual rodar seria perguntar o que
  // está à vista. Não atropela a automação que fixou uma: quem fixou, fixou por
  // um motivo — e o servidor recusaria o desvio de qualquer forma.
  var alvo = automacao.deviceId.isNotEmpty ? automacao.deviceId : (emQual ?? '');
  if (alvo.isEmpty) {
    final lista = state.devices;
    if (lista.isEmpty) {
      _dizer(context, t.profileNoComputers);
      return;
    }
    if (lista.length == 1) {
      alvo = lista.first.deviceId;
    } else {
      final escolhido = await showModalBottomSheet<Device>(
        context: context,
        backgroundColor: const Color(0xFF14162C),
        builder: (ctx) => SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Padding(
                padding: const EdgeInsets.all(16),
                child: Text(t.automationPickComputer,
                    style: const TextStyle(color: Colors.white, fontSize: 15)),
              ),
              for (final d in lista)
                ListTile(
                  leading: const Icon(Icons.computer, color: Colors.white70),
                  title:
                      Text(d.name, style: const TextStyle(color: Colors.white)),
                  onTap: () => Navigator.of(ctx).pop(d),
                ),
            ],
          ),
        ),
      );
      if (escolhido == null || !context.mounted) return;
      alvo = escolhido.deviceId;
    }
  }

  final messenger = ScaffoldMessenger.of(context);
  messenger.showSnackBar(
    SnackBar(
      content: Text(t.automationRunning),
      duration: const Duration(seconds: 30),
    ),
  );
  List<StepResult> resultados;
  try {
    resultados = await state.runAutomation(automacao, deviceId: alvo);
  } catch (e) {
    messenger
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(e.toString())));
    return;
  }
  messenger.hideCurrentSnackBar();

  final falhas = resultados.where((r) => !r.ok).toList();
  if (falhas.isEmpty) {
    // Diz o número porque tudo acontece **no computador**: de longe, uma
    // automação que rodou inteira e uma que não fez nada seriam idênticas.
    messenger.showSnackBar(
      SnackBar(content: Text(t.automationDone(resultados.length))),
    );
    return;
  }
  messenger.showSnackBar(
    SnackBar(
      content: Text(
        t.automationPartial(resultados.length - falhas.length, resultados.length),
      ),
      action: SnackBarAction(
        label: t.automationResult,
        onPressed: () {
          if (!context.mounted) return;
          _mostrarFalhas(context, state, automacao, falhas);
        },
      ),
      duration: const Duration(seconds: 8),
    ),
  );
}

void _dizer(BuildContext context, String msg) =>
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));

/// Quais passos falharam, e por quê.
///
/// Pelo índice, e não pelo nome: dois passos podem ser idênticos ("baixar o
/// volume" duas vezes), e dizer só "baixar o volume falhou" não diria qual.
void _mostrarFalhas(
  BuildContext context,
  AppState state,
  Automation automacao,
  List<StepResult> falhas,
) {
  final t = state.t;
  showModalBottomSheet<void>(
    context: context,
    backgroundColor: const Color(0xFF14162C),
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
    ),
    builder: (sheet) => SafeArea(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(18, 18, 18, 8),
            child: Text(t.automationResult,
                style: const TextStyle(color: Colors.white, fontSize: 17)),
          ),
          for (final f in falhas)
            ListTile(
              leading: const Icon(Icons.error_outline, color: Colors.orangeAccent),
              title: Text(
                f.index < automacao.steps.length
                    ? automacao.steps[f.index].describe(t)
                    : '#${f.index + 1}',
                style: const TextStyle(color: Colors.white),
              ),
              subtitle: f.error == null
                  ? null
                  : Text(f.error!,
                      style: const TextStyle(
                          color: Colors.white54, fontSize: 12)),
            ),
        ],
      ),
    ),
  );
}
