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
            return Center(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Text(t.noComputers, textAlign: TextAlign.center),
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
                    '${d.online ? t.online : t.offline} · ${d.os} · ${d.hostname}',
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
        label: Text(t.pair),
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
