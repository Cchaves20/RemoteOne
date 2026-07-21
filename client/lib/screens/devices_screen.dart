import 'package:flutter/material.dart';

import '../models/device.dart';
import '../services/app_state.dart';
import 'remote_screen.dart';

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

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Meus computadores'),
        actions: [
          IconButton(
            tooltip: 'Sair',
            icon: const Icon(Icons.logout),
            onPressed: widget.state.logout,
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
                  leading: const Icon(Icons.computer),
                  title: Text(d.name),
                  subtitle: Text('${d.os} · ${d.hostname}'),
                  trailing: const Icon(Icons.chevron_right),
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
