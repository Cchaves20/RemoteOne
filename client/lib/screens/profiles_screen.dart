import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../l10n/strings.dart';
import '../models/control_profile.dart';
import '../models/device.dart';
import '../models/remote_app.dart';
import '../services/app_state.dart';
import '../theme.dart';

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

  @override
  Widget build(BuildContext context) {
    final t = widget.state.t;
    return Scaffold(
      appBar: AppBar(title: Text(t.profilesTitle)),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => _editar(null),
        icon: const Icon(Icons.add),
        label: Text(t.profileNew),
      ),
      body: _carregando
          ? const Center(child: CircularProgressIndicator())
          : Column(
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(18, 12, 18, 4),
                  child: Text(
                    t.profilesHint,
                    style: const TextStyle(color: Colors.white54, fontSize: 12),
                  ),
                ),
                Expanded(
                  child: ReorderableListView.builder(
                    padding: const EdgeInsets.only(bottom: 96),
                    itemCount: _fila.length,
                    onReorder: _reordenar,
                    itemBuilder: (context, i) => _linha(_fila[i], t),
                  ),
                ),
              ],
            ),
    );
  }

  Widget _linha(ControlProfile p, Strings t) {
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
          const Icon(Icons.drag_handle, color: Colors.white38),
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
  late List<({String name, String path})> _apps = [
    for (final a in widget.profile?.actions ?? const <ProfileAction>[])
      (name: a.appName, path: a.appPath ?? ''),
  ];

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
          ProfileAction.launch(appName: a.name, appPath: a.path),
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
        builder: (_) => _AppPickerScreen(state: widget.state, device: onde),
      ),
    );
    if (escolhidos == null || escolhidos.isEmpty) return;
    setState(() {
      for (final a in escolhidos) {
        // Mesmo programa duas vezes viraria dois botões idênticos.
        if (_apps.any((x) => x.path == a.id)) continue;
        _apps = [..._apps, (name: a.name, path: a.id)];
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
              trailing: IconButton(
                icon: const Icon(Icons.close, color: Colors.white38),
                onPressed: () =>
                    setState(() => _apps = _apps.where((x) => x != a).toList()),
              ),
            ),
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

/// Lista de programas de um computador, com seleção múltipla.
class _AppPickerScreen extends StatefulWidget {
  const _AppPickerScreen({super.key, required this.state, required this.device});


  final AppState state;
  final Device device;

  @override
  State<_AppPickerScreen> createState() => _AppPickerScreenState();
}

class _AppPickerScreenState extends State<_AppPickerScreen> {
  List<RemoteApp> _apps = const [];
  final Set<String> _escolhidos = {};
  String _busca = '';
  bool _carregando = true;
  String? _erro;

  @override
  void initState() {
    super.initState();
    _carregar();
  }

  Future<void> _carregar() async {
    try {
      // `installed` e não `desktop`: o pedido era poder escolher programas que
      // estão na área de trabalho **ou não**, e o menu Iniciar é onde estão
      // todos.
      final lista = await widget.state.listApps(widget.device, kind: 'installed');
      if (!mounted) return;
      setState(() {
        _apps = lista;
        _carregando = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _erro = e.toString();
        _carregando = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = widget.state.t;
    final filtrados = _busca.isEmpty
        ? _apps
        : _apps
            .where((a) => a.name.toLowerCase().contains(_busca.toLowerCase()))
            .toList();
    return Scaffold(
      appBar: AppBar(
        title: Text(t.profileAddProgram),
        actions: [
          TextButton(
            onPressed: _escolhidos.isEmpty
                ? null
                : () => Navigator.of(context).pop(
                      _apps.where((a) => _escolhidos.contains(a.id)).toList(),
                    ),
            child: Text('${t.save} (${_escolhidos.length})'),
          ),
        ],
      ),
      body: _carregando
          ? Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const CircularProgressIndicator(),
                  const SizedBox(height: 12),
                  Text(t.appsQuerying,
                      style: const TextStyle(color: Colors.white54)),
                ],
              ),
            )
          : _erro != null
              ? Center(
                  child: Padding(
                    padding: const EdgeInsets.all(24),
                    child: Text(_erro!,
                        textAlign: TextAlign.center,
                        style: const TextStyle(color: Colors.white54)),
                  ),
                )
              : Column(
                  children: [
                    Padding(
                      padding: const EdgeInsets.all(12),
                      child: TextField(
                        style: const TextStyle(color: Colors.white),
                        decoration: InputDecoration(
                          prefixIcon: const Icon(Icons.search),
                          hintText: t.appsSearch,
                        ),
                        onChanged: (v) => setState(() => _busca = v),
                      ),
                    ),
                    Expanded(
                      child: ListView.builder(
                        itemCount: filtrados.length,
                        itemBuilder: (context, i) {
                          final a = filtrados[i];
                          return CheckboxListTile(
                            value: _escolhidos.contains(a.id),
                            title: Text(a.name,
                                style: const TextStyle(color: Colors.white)),
                            onChanged: (v) => setState(() {
                              if (v == true) {
                                _escolhidos.add(a.id);
                              } else {
                                _escolhidos.remove(a.id);
                              }
                            }),
                          );
                        },
                      ),
                    ),
                  ],
                ),
    );
  }
}
