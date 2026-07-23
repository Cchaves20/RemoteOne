import 'package:flutter/material.dart';

import '../models/device.dart';
import '../services/app_state.dart';
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
  @override
  void initState() {
    super.initState();
    // Atualiza a lista ao abrir (ignora erros de rede iniciais).
    WidgetsBinding.instance.addPostFrameCallback((_) {
      widget.state.refreshDevices().catchError((_) {});
    });
  }

  Future<void> _showPairDialog() async {
    final controller = TextEditingController();
    final code = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Parear computador'),
        content: TextField(
          controller: controller,
          autofocus: true,
          textCapitalization: TextCapitalization.characters,
          decoration: const InputDecoration(
            labelText: 'Código exibido no computador',
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancelar'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, controller.text.trim()),
            child: const Text('Parear'),
          ),
        ],
      ),
    );
    if (code == null || code.isEmpty) return;
    try {
      await widget.state.pair(code);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Computador pareado!')),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(e.toString())));
      }
    }
  }

  void _openControl(Device device) {
    widget.state.selectDevice(device);
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => RemoteScreen(state: widget.state, device: device),
      ),
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
    final controller = TextEditingController(text: device.name);
    final name = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Renomear computador'),
        content: TextField(
          controller: controller,
          autofocus: true,
          decoration: const InputDecoration(labelText: 'Nome'),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancelar'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, controller.text.trim()),
            child: const Text('Salvar'),
          ),
        ],
      ),
    );
    if (name == null || name.isEmpty) return;
    await _runDeviceAction(
      () => widget.state.renameDevice(device, name),
      'Nome atualizado.',
    );
  }

  Future<void> _confirmRemove(Device device) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Remover computador'),
        content: Text('Desvincular "${device.name}" da sua conta?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancelar'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Remover'),
          ),
        ],
      ),
    );
    if (ok != true) return;
    await _runDeviceAction(
      () => widget.state.removeDevice(device),
      'Computador removido.',
    );
  }

  Future<void> _wake(Device device) async {
    final messenger = ScaffoldMessenger.of(context);
    try {
      await widget.state.wakeDevice(device);
      if (mounted) {
        messenger.showSnackBar(const SnackBar(
          content: Text('Sinal enviado. O computador deve ligar em instantes.'),
        ));
      }
    } catch (e) {
      if (mounted) {
        messenger.showSnackBar(SnackBar(content: Text(e.toString())));
      }
    }
  }

  Future<void> _confirmPower(Device device, String action) async {
    const labels = {
      'shutdown': 'Desligar',
      'restart': 'Reiniciar',
      'suspend': 'Suspender',
    };
    final label = labels[action]!;
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('$label computador'),
        content: Text('$label "${device.name}" agora?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancelar'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: Text(label),
          ),
        ],
      ),
    );
    if (ok != true) return;
    await _runDeviceAction(
      () => widget.state.powerDevice(device, action),
      '$label enviado.',
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
      itemBuilder: (context) => [
        if (!d.online)
          const PopupMenuItem(
            value: 'wake',
            child: ListTile(
              leading: Icon(Icons.power),
              title: Text('Ligar (Wake-on-LAN)'),
            ),
          ),
        const PopupMenuItem(
          value: 'open',
          child: ListTile(
            leading: Icon(Icons.play_arrow),
            title: Text('Controlar'),
          ),
        ),
        const PopupMenuItem(
          value: 'rename',
          child: ListTile(
            leading: Icon(Icons.edit),
            title: Text('Renomear'),
          ),
        ),
        const PopupMenuDivider(),
        PopupMenuItem(
          value: 'shutdown',
          enabled: d.online,
          child: const ListTile(
            leading: Icon(Icons.power_settings_new),
            title: Text('Desligar'),
          ),
        ),
        PopupMenuItem(
          value: 'restart',
          enabled: d.online,
          child: const ListTile(
            leading: Icon(Icons.restart_alt),
            title: Text('Reiniciar'),
          ),
        ),
        PopupMenuItem(
          value: 'suspend',
          enabled: d.online,
          child: const ListTile(
            leading: Icon(Icons.bedtime),
            title: Text('Suspender'),
          ),
        ),
        const PopupMenuDivider(),
        const PopupMenuItem(
          value: 'remove',
          child: ListTile(
            leading: Icon(Icons.link_off),
            title: Text('Remover'),
          ),
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Meus computadores'),
        actions: [
          IconButton(
            tooltip: 'Configurações',
            icon: const Icon(Icons.settings),
            onPressed: () => Navigator.of(context).push(
              MaterialPageRoute(
                builder: (_) => SettingsScreen(state: widget.state),
              ),
            ),
          ),
        ],
      ),
      body: ListenableBuilder(
        listenable: widget.state,
        builder: (context, _) {
          final devices = widget.state.devices;
          if (devices.isEmpty) {
            return const Center(
              child: Padding(
                padding: EdgeInsets.all(24),
                child: Text(
                  'Nenhum computador pareado.\n'
                  'Toque em + e informe o código exibido pelo agente.',
                  textAlign: TextAlign.center,
                ),
              ),
            );
          }
          return RefreshIndicator(
            onRefresh: widget.state.refreshDevices,
            child: ListView.builder(
              itemCount: devices.length,
              itemBuilder: (context, i) {
                final d = devices[i];
                return ListTile(
                  leading: _StatusIcon(online: d.online),
                  title: Text(d.name),
                  subtitle: Text(
                    '${d.online ? 'Online' : 'Offline'} · ${d.os} · ${d.hostname}',
                  ),
                  trailing: _deviceMenu(d),
                  onTap: () => _openControl(d),
                );
              },
            ),
          );
        },
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _showPairDialog,
        icon: const Icon(Icons.add_link),
        label: const Text('Parear'),
      ),
    );
  }
}

/// Ícone de computador com um ponto de status (verde = online, cinza = offline).
class _StatusIcon extends StatelessWidget {
  const _StatusIcon({required this.online});

  final bool online;

  @override
  Widget build(BuildContext context) {
    final color = online ? Colors.green : Theme.of(context).disabledColor;
    return Stack(
      alignment: Alignment.bottomRight,
      children: [
        const Icon(Icons.computer),
        Container(
          width: 10,
          height: 10,
          decoration: BoxDecoration(
            color: color,
            shape: BoxShape.circle,
            border: Border.all(
              color: Theme.of(context).scaffoldBackgroundColor,
              width: 1.5,
            ),
          ),
        ),
      ],
    );
  }
}
