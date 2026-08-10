import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

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
import 'automations_screen.dart';

/// Editor de perfis: criar, editar, reordenar e apagar.
///
/// Fica **fora** da tela de controle, e isso é deliberado: montar um perfil é
/// uma tarefa de arrumar a casa, não de usar o computador. Quem está no meio de
/// uma apresentação não quer esbarrar num editor.
///
/// Os cinco perfis de fábrica aparecem aqui, mas só para serem arrastados: eles
/// são atalhos de teclado escritos no app, não dados — não há o que editar sem
/// virar outro recurso.
class ProfilesScreen extends StatefulWidget {
  const ProfilesScreen({super.key, required this.state});

  final AppState state;

  @override
  State<ProfilesScreen> createState() => _ProfilesScreenState();
}

class _ProfilesScreenState extends State<ProfilesScreen> {
  bool _carregando = true;

  /// A fila inteira, de fábrica e criados juntos — é ela que se arrasta.
  List<ControlProfile> _fila = const [];

  @override
  void initState() {
    super.initState();
    _recarregar();
  }

  Future<void> _recarregar() async {
    await widget.state.loadProfiles();
    await widget.state.loadAutomations();
    if (!mounted) return;
    setState(() {
      // Sem filtro por computador: aqui se edita a coleção inteira.
      _fila = ControlProfile.arrange(
        widget.state.customProfiles,
        widget.state.profileOrder,
      );
      _carregando = false;
    });
  }

  Future<void> _reordenar(int de, int para) async {
    // O `ReorderableListView` entrega o índice de destino contando a posição
    // antiga ainda ocupada; um item que desce precisa deste ajuste.
    if (para > de) para -= 1;
    final nova = [..._fila];
    nova.insert(para, nova.removeAt(de));
    setState(() => _fila = nova);
    HapticFeedback.selectionClick();
    try {
      await widget.state.setProfileOrder([for (final p in nova) p.id]);
    } catch (e) {
      if (!mounted) return;
      await _recarregar();
      _avisar(e.toString());
    }
  }

  void _avisar(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
  }

  Future<void> _editar(ControlProfile? perfil) async {
    final salvou = await Navigator.of(context).push<bool>(
      MaterialPageRoute(
        builder: (_) => ProfileEditorScreen(state: widget.state, profile: perfil),
      ),
    );
    if (salvou == true) await _recarregar();
  }

  Future<void> _apagar(ControlProfile perfil) async {
    final t = widget.state.t;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(t.profileDelete),
        content: Text(t.profileDeleteConfirm(perfil.rawName)),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: Text(t.cancel),
          ),
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: Text(t.delete),
          ),
        ],
      ),
    );
    if (ok != true) return;
    try {
      await widget.state.deleteProfile(perfil.id);
      await _recarregar();
    } catch (e) {
      _avisar(e.toString());
    }
  }

  Future<void> _editarAutomacao(Automation? automacao) async {
    final salvou = await Navigator.of(context).push<bool>(
      MaterialPageRoute(
        builder: (_) => AutomationEditorScreen(
          state: widget.state,
          automation: automacao,
        ),
      ),
    );
    if (salvou == true) await _recarregar();
  }

  Future<void> _apagarAutomacao(Automation a) async {
    final t = widget.state.t;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(a.name),
        content: Text(t.automationDeleteConfirm(a.name)),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: Text(t.cancel),
          ),
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: Text(t.delete),
          ),
        ],
      ),
    );
    if (ok != true) return;
    try {
      await widget.state.deleteAutomation(a.id);
      await _recarregar();
    } catch (e) {
      _avisar(e.toString());
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = widget.state.t;
    return Scaffold(
      appBar: AppBar(title: Text(t.profilesTitle)),
      body: _carregando
          ? const Center(child: CircularProgressIndicator())
          // Duas listas numa rolagem só, e a de perfis continua arrastável:
          // é para isso que existe o `SliverReorderableList`. Empilhar duas
          // listas roláveis daria duas barras de rolagem competindo pelo dedo.
          : CustomScrollView(
              slivers: [
                SliverToBoxAdapter(
                  child: _cabecalho(
                    titulo: t.profilesTitle,
                    dica: t.profilesHint,
                    botao: t.profileNew,
                    onAdd: () => _editar(null),
                  ),
                ),
                SliverReorderableList(
                  itemCount: _fila.length,
                  onReorder: _reordenar,
                  itemBuilder: (context, i) => _linha(_fila[i], t, i),
                ),
                SliverToBoxAdapter(
                  child: _cabecalho(
                    titulo: t.automations,
                    dica: t.automationsHint,
                    botao: t.automationNew,
                    onAdd: () => _editarAutomacao(null),
                    comDivisor: true,
                  ),
                ),
                SliverList.builder(
                  itemCount: widget.state.automations.length,
                  itemBuilder: (context, i) =>
                      _linhaAutomacao(widget.state.automations[i], t),
                ),
                if (widget.state.automations.isEmpty)
                  SliverToBoxAdapter(
                    child: Padding(
                      padding: const EdgeInsets.fromLTRB(18, 4, 18, 0),
                      child: Text(
                        t.automationsEmpty,
                        style: const TextStyle(
                            color: Colors.white38, fontSize: 12),
                      ),
                    ),
                  ),
                const SliverToBoxAdapter(child: SizedBox(height: 32)),
              ],
            ),
    );
  }

  Widget _cabecalho({
    required String titulo,
    required String dica,
    required String botao,
    required VoidCallback onAdd,
    bool comDivisor = false,
  }) {
    return Padding(
      padding: EdgeInsets.fromLTRB(18, comDivisor ? 8 : 12, 18, 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (comDivisor) const Divider(height: 24, color: Colors.white12),
          Row(
            children: [
              Expanded(
                child: Text(
                  titulo,
                  style: const TextStyle(color: Colors.white, fontSize: 15),
                ),
              ),
              TextButton.icon(
                onPressed: onAdd,
                icon: const Icon(Icons.add),
                label: Text(botao),
              ),
            ],
          ),
          Text(
            dica,
            style: const TextStyle(color: Colors.white54, fontSize: 12),
          ),
          const SizedBox(height: 4),
        ],
      ),
    );
  }

  Widget _linhaAutomacao(Automation a, Strings t) {
    final onde = widget.state.devices
        .where((d) => d.deviceId == a.deviceId)
        .map((d) => d.name);
    return ListTile(
      key: ValueKey(a.id),
      leading: Icon(a.iconData, color: auroraCyan),
      title: Text(a.name, style: const TextStyle(color: Colors.white)),
      subtitle: Text(
        [
          t.automationStepCount(a.steps.length),
          if (onde.isNotEmpty) onde.first,
        ].join(' · '),
        style: const TextStyle(color: Colors.white54, fontSize: 12),
      ),
      onTap: () => _editarAutomacao(a),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          // Rodar daqui é o caminho principal: a tela de perfis é onde a
          // automação existe, e obrigar a abrir o editor para executá-la faria
          // do recurso de um toque um recurso de três.
          IconButton(
            tooltip: t.automationRun,
            icon: const Icon(Icons.play_arrow, color: Colors.white70),
            onPressed: () => runAutomationFlow(context, widget.state, a),
          ),
          IconButton(
            icon: const Icon(Icons.delete_outline, color: Colors.white38),
            onPressed: () => _apagarAutomacao(a),
          ),
        ],
      ),
    );
  }

  Widget _linha(ControlProfile p, Strings t, int i) {
    final quantos = p.actions.length;
    return ListTile(
      key: ValueKey(p.id),
      leading: Icon(p.icon, color: p.custom ? auroraCyan : Colors.white54),
      title: Text(
        p.custom ? p.rawName : p.name(t),
        style: const TextStyle(color: Colors.white),
      ),
      subtitle: Text(
        p.custom
            ? [
                t.profileAppCount(quantos),
                if (p.devices.isNotEmpty) t.profileOnComputers(p.devices.length),
              ].join(' · ')
            : t.profileBuiltIn,
        style: const TextStyle(color: Colors.white54, fontSize: 12),
      ),
      // Só os criados abrem para edição. Um perfil de fábrica é código: um
      // editor que não edita nada seria pior que a ausência dele.
      onTap: p.custom ? () => _editar(p) : null,
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (p.custom)
            IconButton(
              icon: const Icon(Icons.delete_outline, color: Colors.white38),
              onPressed: () => _apagar(p),
            ),
          // O `SliverReorderableList` não desenha alça por conta própria (ao
          // contrário do `ReorderableListView`): quem arrasta é este ouvinte.
          ReorderableDragStartListener(
            index: i,
            child: const Icon(Icons.drag_handle, color: Colors.white38),
          ),
        ],
      ),
    );
  }
}

/// Criação e edição de um perfil.
class ProfileEditorScreen extends StatefulWidget {
  const ProfileEditorScreen({super.key, required this.state, this.profile});

  final AppState state;

  /// `null` = perfil novo.
  final ControlProfile? profile;

  @override
  State<ProfileEditorScreen> createState() => _ProfileEditorScreenState();
}

class _ProfileEditorScreenState extends State<ProfileEditorScreen> {
  late final TextEditingController _nome =
      TextEditingController(text: widget.profile?.rawName ?? '');
  late String _icone =
      widget.profile == null ? 'tune' : profileIconKey(widget.profile!.icon);

  /// Os programas escolhidos, na ordem em que virarão botões.
  ///
  /// A ordem tem duas leituras, e as duas valem: é a ordem dos botões na barra,
  /// e é a ordem de abertura no "abrir todos" — onde o último a abrir fica por
  /// cima e em foco.
  late List<({String name, String path, WindowZone? zone})> _apps = [
    for (final a in widget.profile?.actions ?? const <ProfileAction>[])
      (name: a.appName, path: a.appPath ?? '', zone: a.zone),
  ];

  /// Como a tela é dividida quando se abre todos de uma vez.
  ///
  /// Deduzido das zonas guardadas em vez de gravado à parte: um campo separado
  /// poderia discordar delas, e ninguém saberia em qual acreditar.
  late WindowLayout? _layout =
      WindowLayout.ofZones(_apps.map((a) => a.zone));

  late final Set<String> _devices = {...?widget.profile?.devices};
  bool _salvando = false;

  @override
  void dispose() {
    _nome.dispose();
    super.dispose();
  }

  void _avisar(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
  }

  Future<void> _salvar() async {
    final t = widget.state.t;
    final nome = _nome.text.trim();
    if (nome.isEmpty) {
      _avisar(t.profileNameRequired);
      return;
    }
    setState(() => _salvando = true);
    final perfil = ControlProfile(
      // Perfil novo ainda não tem identificador: quem o gera é o servidor.
      id: widget.profile?.id ?? '',
      icon: profileIcon(_icone),
      name: (_) => nome,
      rawName: nome,
      custom: true,
      devices: _devices.toList(),
      actions: [
        for (final a in _apps)
          ProfileAction.launch(
            appName: a.name,
            appPath: a.path,
            zone: a.zone,
          ),
      ],
    );
    try {
      if (widget.profile == null) {
        await widget.state.createProfile(perfil);
      } else {
        await widget.state.updateProfile(perfil);
      }
      if (mounted) Navigator.of(context).pop(true);
    } catch (e) {
      if (!mounted) return;
      setState(() => _salvando = false);
      _avisar(e.toString());
    }
  }

  /// Escolhe programas num computador da conta.
  ///
  /// A lista vem do computador escolhido, mas o perfil pode valer para outros:
  /// por isso o que se guarda é o nome **e** o caminho — em outra máquina o
  /// caminho pode não existir, e é pelo nome que o agente procura.
  Future<void> _adicionarPrograma() async {
    final t = widget.state.t;
    final computadores = widget.state.devices;
    if (computadores.isEmpty) {
      _avisar(t.profileNoComputers);
      return;
    }
    final onde = computadores.length == 1
        ? computadores.first
        : await _escolherComputador(computadores, t);
    if (onde == null) return;
    // Guarda em instrução própria: o analisador não reconhece o `mounted`
    // escondido dentro de um `||` e acusa uso de contexto depois de `await`.
    if (!mounted) return;

    final escolhidos = await Navigator.of(context).push<List<RemoteApp>>(
      MaterialPageRoute(
        builder: (_) => AppPickerScreen(state: widget.state, device: onde),
      ),
    );
    if (escolhidos == null || escolhidos.isEmpty) return;
    setState(() {
      for (final a in escolhidos) {
        // Mesmo programa duas vezes viraria dois botões idênticos.
        if (_apps.any((x) => x.path == a.id)) continue;
        _apps = [..._apps, (name: a.name, path: a.id, zone: null)];
      }
    });
  }

  Future<Device?> _escolherComputador(List<Device> lista, Strings t) {
    return showModalBottomSheet<Device>(
      context: context,
      backgroundColor: const Color(0xFF14162C),
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.all(16),
              child: Text(
                t.profilePickFrom,
                style: const TextStyle(color: Colors.white, fontSize: 15),
              ),
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

  @override
  Widget build(BuildContext context) {
    final t = widget.state.t;
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.profile == null ? t.profileNew : t.profileEdit),
        actions: [
          TextButton(
            onPressed: _salvando ? null : _salvar,
            child: Text(t.save),
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(18, 12, 18, 32),
        children: [
          TextField(
            controller: _nome,
            maxLength: 60,
            style: const TextStyle(color: Colors.white),
            decoration: InputDecoration(
              labelText: t.profileName,
              hintText: t.profileNameHint,
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
          const Divider(height: 32, color: Colors.white12),
          Row(
            children: [
              Expanded(
                child: Text(
                  t.profilePrograms,
                  style: const TextStyle(color: Colors.white, fontSize: 15),
                ),
              ),
              TextButton.icon(
                onPressed: _apps.length >= 12 ? null : _adicionarPrograma,
                icon: const Icon(Icons.add),
                label: Text(t.profileAddProgram),
              ),
            ],
          ),
          if (_apps.isEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 8),
              child: Text(
                t.profileNoPrograms,
                style: const TextStyle(color: Colors.white38, fontSize: 12),
              ),
            ),
          for (final a in _apps)
            ListTile(
              contentPadding: EdgeInsets.zero,
              leading: const Icon(Icons.launch, color: Colors.white70),
              title: Text(a.name, style: const TextStyle(color: Colors.white)),
              subtitle: Text(
                a.path,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(color: Colors.white38, fontSize: 11),
              ),
              trailing: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  // O seletor de zona só existe com um layout escolhido: sem
                  // ele não há grade onde encaixar, e um botão que não leva a
                  // lugar nenhum é pior que botão nenhum.
                  if (_layout != null)
                    ZoneChooser(
                      layout: _layout!,
                      zone: a.zone,
                      strings: widget.state.t,
                      onPick: (nova) => setState(() {
                        _apps = [
                          for (final x in _apps)
                            if (identical(x, a))
                              (name: x.name, path: x.path, zone: nova)
                            else
                              x,
                        ];
                      }),
                    ),
                  IconButton(
                    icon: const Icon(Icons.close, color: Colors.white38),
                    onPressed: () => setState(
                        () => _apps = _apps.where((x) => x != a).toList()),
                  ),
                ],
              ),
            ),
          // O seletor de layout fica **depois** da lista de propósito: ele só
          // faz sentido com programas escolhidos, e num perfil vazio seria a
          // primeira coisa a aparecer sem ter o que dividir.
          if (_apps.length >= 2) ...[
            const SizedBox(height: 8),
            LayoutPicker(
              selected: _layout,
              strings: widget.state.t,
              onSelect: (l) => setState(() {
                _layout = l;
                // Trocar de layout invalida as zonas antigas: uma célula da
                // grade de dois não é uma célula da grade de três. Limpar é
                // mais honesto que traduzir por aproximação e pôr as janelas
                // em lugares que ninguém escolheu.
                _apps = [
                  for (final x in _apps) (name: x.name, path: x.path, zone: null),
                ];
              }),
            ),
          ],
          const Divider(height: 32, color: Colors.white12),
          Text(t.profileComputers,
              style: const TextStyle(color: Colors.white, fontSize: 15)),
          Padding(
            padding: const EdgeInsets.only(top: 4, bottom: 8),
            child: Text(
              t.profileComputersHint,
              style: const TextStyle(color: Colors.white54, fontSize: 12),
            ),
          ),
          for (final d in widget.state.devices)
            CheckboxListTile(
              contentPadding: EdgeInsets.zero,
              value: _devices.contains(d.deviceId),
              title: Text(d.name, style: const TextStyle(color: Colors.white)),
              onChanged: (v) => setState(() {
                if (v == true) {
                  _devices.add(d.deviceId);
                } else {
                  _devices.remove(d.deviceId);
                }
              }),
            ),
        ],
      ),
    );
  }
}
