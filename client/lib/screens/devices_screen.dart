import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../config.dart';
import '../models/device.dart';
import '../services/app_state.dart';
import '../theme.dart';
import '../widgets/plano.dart';
import '../widgets/pulse.dart';
import '../widgets/transitions.dart';
import 'apps_screen.dart';
import 'files_screen.dart';
import 'keep_awake_screen.dart';
import 'remote_screen.dart';
import 'settings_screen.dart';

/// Lista os computadores pareados e permite parear um novo pelo código.
class DevicesScreen extends StatefulWidget {
  const DevicesScreen({super.key, required this.state});

  final AppState state;

  @override
  State<DevicesScreen> createState() => _DevicesScreenState();
}

class _DevicesScreenState extends State<DevicesScreen> {
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    // Atualiza a lista ao abrir (ignora erros de rede iniciais).
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      try {
        await widget.state.refreshDevices();
      } catch (_) {
        // Sem rede: mostra o que tiver (ou o estado vazio).
      }
      if (mounted) setState(() => _loading = false);
    });
  }

  Future<void> _showPairDialog() async {
    final t = widget.state.t;
    final controller = TextEditingController();
    final code = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(t.pairComputer),
        content: TextField(
          controller: controller,
          autofocus: true,
          textCapitalization: TextCapitalization.characters,
          decoration: InputDecoration(labelText: t.codeShownOnComputer),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: Text(t.cancel),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, controller.text.trim()),
            child: Text(t.pair),
          ),
        ],
      ),
    );
    if (code == null || code.isEmpty) return;
    try {
      await widget.state.pair(code);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(t.computerPaired)),
        );
      }
    } catch (e) {
      if (!mounted) return;
      // O limite de plano sai do aviso vermelho e vira conversa. É o caminho
      // mais provável de esbarrar nele: a pessoa gostou e foi instalar no
      // segundo computador.
      if (ehLimiteDePlano(e)) {
        await mostrarLimiteDePlano(context, t, e.toString());
        return;
      }
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(e.toString())));
    }
  }

  void _openControl(Device device) {
    widget.state.selectDevice(device);
    Navigator.of(context).push(
      fadeThroughRoute(RemoteScreen(state: widget.state, device: device)),
    );
  }

  Future<void> _runDeviceAction(
      Future<void> Function() action, String success) async {
    final messenger = ScaffoldMessenger.of(context);
    try {
      await action();
      if (mounted) {
        messenger.showSnackBar(SnackBar(content: Text(success)));
      }
    } catch (e) {
      if (mounted) {
        messenger.showSnackBar(SnackBar(content: Text(e.toString())));
      }
    }
  }

  Future<void> _showRenameDialog(Device device) async {
    final t = widget.state.t;
    final controller = TextEditingController(text: device.name);
    final name = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(t.renameComputer),
        content: TextField(
          controller: controller,
          autofocus: true,
          decoration: InputDecoration(labelText: t.name),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: Text(t.cancel),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, controller.text.trim()),
            child: Text(t.save),
          ),
        ],
      ),
    );
    if (name == null || name.isEmpty) return;
    await _runDeviceAction(
      () => widget.state.renameDevice(device, name),
      t.nameUpdated,
    );
  }

  Future<void> _confirmRemove(Device device) async {
    final t = widget.state.t;
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(t.removeComputer),
        content: Text(t.unlinkConfirm(device.name)),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: Text(t.cancel),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: Text(t.remove),
          ),
        ],
      ),
    );
    if (ok != true) return;
    await _runDeviceAction(
      () => widget.state.removeDevice(device),
      t.computerRemoved,
    );
  }

  Future<void> _wake(Device device) async {
    final t = widget.state.t;
    final messenger = ScaffoldMessenger.of(context);
    try {
      await widget.state.wakeDevice(device);
      if (mounted) {
        messenger.showSnackBar(SnackBar(content: Text(t.wakeSent)));
      }
    } catch (e) {
      if (mounted) {
        messenger.showSnackBar(SnackBar(content: Text(e.toString())));
      }
    }
  }

  Future<void> _confirmPower(Device device, String action) async {
    final t = widget.state.t;
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(t.powerLabel(action)),
        content: Text(t.powerConfirm(action, device.name)),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: Text(t.cancel),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: Text(t.powerLabel(action)),
          ),
        ],
      ),
    );
    if (ok != true) return;
    await _runDeviceAction(
      () => widget.state.powerDevice(device, action),
      t.powerSent(action),
    );
  }

  /// Menu de ações do computador: abrir, renomear, energia e remover.
  Widget _deviceMenu(Device d) {
    return PopupMenuButton<String>(
      icon: const Icon(Icons.more_vert),
      onSelected: (value) {
        switch (value) {
          case 'wake':
            _wake(d);
          case 'open':
            _openControl(d);
          case 'apps':
            Navigator.of(context).push(
              fadeThroughRoute(AppsScreen(state: widget.state, device: d)),
            );
          case 'files':
            Navigator.of(context).push(
              fadeThroughRoute(FilesScreen(state: widget.state, device: d)),
            );
          case 'ready':
            Navigator.of(context).push(
              fadeThroughRoute(
                KeepAwakeScreen(state: widget.state, device: d),
              ),
            );
          case 'rename':
            _showRenameDialog(d);
          case 'shutdown':
          case 'restart':
          case 'suspend':
            _confirmPower(d, value);
          case 'remove':
            _confirmRemove(d);
        }
      },
      itemBuilder: (context) {
        final t = widget.state.t;
        return [
          if (!d.online)
            PopupMenuItem(
              value: 'wake',
              child: ListTile(
                leading: const Icon(Icons.power),
                title: Text(t.wake),
              ),
            ),
          PopupMenuItem(
            value: 'open',
            child: ListTile(
              leading: const Icon(Icons.play_arrow),
              title: Text(t.control),
            ),
          ),
          PopupMenuItem(
            value: 'apps',
            enabled: d.online,
            child: ListTile(
              leading: const Icon(Icons.apps),
              title: Text(t.apps),
            ),
          ),
          PopupMenuItem(
            value: 'files',
            enabled: d.online,
            child: ListTile(
              leading: const Icon(Icons.folder),
              title: Text(t.files),
            ),
          ),
          PopupMenuItem(
            value: 'ready',
            enabled: d.online,
            child: ListTile(
              leading: const Icon(Icons.bedtime_off),
              title: Text(t.keepAwakeTitle),
            ),
          ),
          PopupMenuItem(
            value: 'rename',
            child: ListTile(
              leading: const Icon(Icons.edit),
              title: Text(t.rename),
            ),
          ),
          const PopupMenuDivider(),
          PopupMenuItem(
            value: 'shutdown',
            enabled: d.online,
            child: ListTile(
              leading: const Icon(Icons.power_settings_new),
              title: Text(t.shutdown),
            ),
          ),
          PopupMenuItem(
            value: 'restart',
            enabled: d.online,
            child: ListTile(
              leading: const Icon(Icons.restart_alt),
              title: Text(t.restart),
            ),
          ),
          PopupMenuItem(
            value: 'suspend',
            enabled: d.online,
            child: ListTile(
              leading: const Icon(Icons.bedtime),
              title: Text(t.suspend),
            ),
          ),
          const PopupMenuDivider(),
          PopupMenuItem(
            value: 'remove',
            child: ListTile(
              leading: const Icon(Icons.link_off),
              title: Text(t.remove),
            ),
          ),
        ];
      },
    );
  }

  /// A tela de primeiro uso.
  ///
  /// Era um ícone e uma frase: "Nenhum computador pareado. Toque em + e informe
  /// o código exibido pelo agente." Um beco sem saída para quem chega aqui pela
  /// primeira vez, porque supunha duas coisas que essa pessoa não tem — saber o
  /// que é "o agente", e tê-lo já instalado. **Nunca dizia que existe um
  /// programa a instalar no computador**, que é justamente o passo que falta.
  ///
  /// Três passos e um botão, e não um assistente de várias telas: o que faltava
  /// era informação, não cerimônia.
  ///
  /// Rolável de propósito: são três parágrafos mais o rodapé, e num telefone
  /// pequeno com a fonte do sistema aumentada isso não cabe na altura da tela.
  /// Um `Center` fixo cortaria justamente o botão, que é o único elemento que
  /// precisa ser alcançado.
  Widget _emptyState(BuildContext context) {
    final theme = Theme.of(context);
    final t = widget.state.t;
    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(28, 40, 28, 120),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Icon(Icons.devices_other,
              size: 56, color: theme.colorScheme.primary.withAlpha(140)),
          const SizedBox(height: 20),
          Text(t.noComputers,
              textAlign: TextAlign.center, style: theme.textTheme.titleLarge),
          const SizedBox(height: 28),
          _passo(1, Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(t.primeiroPassoBaixar(siteDeskside),
                  style: theme.textTheme.bodyMedium),
              const SizedBox(height: 6),
              // Copiar em vez de abrir: abrir exigiria o `url_launcher`, e uma
              // dependência nova para um toque não se paga. E copiar é o que
              // serve melhor ao caso real — o endereço tem que ser digitado no
              // **computador**, não aberto no celular.
              Align(
                alignment: Alignment.centerLeft,
                child: OutlinedButton.icon(
                  onPressed: _copiarEndereco,
                  icon: const Icon(Icons.copy, size: 16),
                  label: Text(siteDeskside),
                ),
              ),
            ],
          )),
          _passo(2, Text(t.primeiroPassoCodigo, style: theme.textTheme.bodyMedium)),
          _passo(3, Text(t.primeiroPassoDigitar, style: theme.textTheme.bodyMedium)),
          const SizedBox(height: 12),
          // O botão grande **além** do botão flutuante, e não em vez dele. O
          // flutuante tem um ícone de elo de corrente e a palavra "Parear" —
          // quem nunca pareou nada não lê nenhum dos dois como "é aqui que eu
          // começo".
          FilledButton.icon(
            onPressed: _showPairDialog,
            icon: const Icon(Icons.dialpad),
            label: Text(t.tenhoUmCodigo),
            style: FilledButton.styleFrom(
              padding: const EdgeInsets.symmetric(vertical: 16),
            ),
          ),
          const SizedBox(height: 24),
          Text(
            t.ondeAchoOCodigo,
            textAlign: TextAlign.center,
            style: theme.textTheme.bodySmall
                ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
          ),
        ],
      ),
    );
  }

  /// Um passo numerado: o círculo com o número e o conteúdo ao lado.
  Widget _passo(int numero, Widget conteudo) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.only(bottom: 18),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: 28,
            height: 28,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: theme.colorScheme.primary,
              shape: BoxShape.circle,
            ),
            child: Text(
              '$numero',
              style: TextStyle(
                color: theme.colorScheme.onPrimary,
                fontWeight: FontWeight.bold,
                fontSize: 13,
              ),
            ),
          ),
          const SizedBox(width: 14),
          Expanded(child: conteudo),
        ],
      ),
    );
  }

  Future<void> _copiarEndereco() async {
    await Clipboard.setData(const ClipboardData(text: siteDeskside));
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(widget.state.t.enderecoCopiado)),
    );
  }

  Widget _deviceCard(Device d) {
    final theme = Theme.of(context);
    return Card(
      elevation: 0,
      color: theme.colorScheme.surfaceContainerHighest,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
      margin: const EdgeInsets.symmetric(vertical: 6),
      child: InkWell(
        borderRadius: BorderRadius.circular(18),
        onTap: () => _openControl(d),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(12, 12, 4, 12),
          child: Row(
            children: [
              _osAvatar(d),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(d.name,
                        style: theme.textTheme.titleMedium,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis),
                    const SizedBox(height: 4),
                    Text('${d.os} · ${d.hostname}',
                        style: theme.textTheme.bodySmall?.copyWith(
                            color: theme.colorScheme.onSurfaceVariant),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis),
                    const SizedBox(height: 8),
                    _statusPill(d.online),
                  ],
                ),
              ),
              _deviceMenu(d),
            ],
          ),
        ),
      ),
    );
  }

  Widget _osAvatar(Device d) {
    final icon = d.os.toLowerCase().contains('win')
        ? Icons.desktop_windows
        : Icons.computer;
    return Container(
      width: 48,
      height: 48,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        gradient: auroraGradient,
        borderRadius: BorderRadius.circular(14),
      ),
      child: Icon(icon, color: Colors.white, size: 24),
    );
  }

  Widget _statusPill(bool online) {
    final t = widget.state.t;
    final color =
        online ? const Color(0xFF22C55E) : Theme.of(context).colorScheme.outline;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(
        color: color.withAlpha(38),
        borderRadius: BorderRadius.circular(20),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 8,
            height: 8,
            decoration: BoxDecoration(color: color, shape: BoxShape.circle),
          ),
          const SizedBox(width: 6),
          Text(online ? t.online : t.offline,
              style: TextStyle(
                  color: color, fontWeight: FontWeight.w600, fontSize: 12)),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final t = widget.state.t;
    return Scaffold(
      appBar: AppBar(
        title: Text(t.myComputers),
        actions: [
          IconButton(
            tooltip: t.settings,
            icon: const Icon(Icons.settings),
            onPressed: () => Navigator.of(context).push(
              fadeThroughRoute(SettingsScreen(state: widget.state)),
            ),
          ),
        ],
      ),
      body: ListenableBuilder(
        listenable: widget.state,
        builder: (context, _) {
          final devices = widget.state.devices;
          if (devices.isEmpty && _loading) return const _SkeletonList();
          if (devices.isEmpty) return _emptyState(context);
          return RefreshIndicator(
            onRefresh: widget.state.refreshDevices,
            child: ListView.builder(
              padding: const EdgeInsets.fromLTRB(12, 8, 12, 96),
              itemCount: devices.length,
              // Entrada em cascata: cada card aparece um pouco depois do anterior.
              itemBuilder: (context, i) => FadeSlideIn(
                delay: Duration(milliseconds: 50 * i),
                child: _deviceCard(devices[i]),
              ),
            ),
          );
        },
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _showPairDialog,
        icon: const Icon(Icons.add_link),
        label: Text(t.pair),
      ),
    );
  }
}

/// Placeholder animado enquanto a lista de computadores carrega.
class _SkeletonList extends StatelessWidget {
  const _SkeletonList();

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Pulse(
      child: ListView(
        padding: const EdgeInsets.fromLTRB(12, 8, 12, 12),
        children: List.generate(
          4,
          (_) => Card(
            elevation: 0,
            color: scheme.surfaceContainerHighest,
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
            margin: const EdgeInsets.symmetric(vertical: 6),
            child: const Padding(
              padding: EdgeInsets.all(12),
              child: Row(
                children: [
                  SkeletonBox(width: 48, height: 48, radius: 14),
                  SizedBox(width: 14),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        SkeletonBox(width: 140, height: 14),
                        SizedBox(height: 8),
                        SkeletonBox(width: 90, height: 12),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
