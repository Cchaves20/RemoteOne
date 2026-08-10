import 'package:flutter/material.dart';

import '../models/device.dart';
import '../models/remote_app.dart';
import '../services/app_state.dart';

/// Lista de programas de um computador, com seleção múltipla.
///
/// Pública porque o editor de automações escolhe programas do mesmo jeito, e da
/// mesma lista: um passo "abrir programa" é o mesmo ato de um programa de
/// perfil. Uma segunda tela igual seria dois lugares para corrigir o mesmo
/// defeito.
class AppPickerScreen extends StatefulWidget {
  const AppPickerScreen({super.key, required this.state, required this.device});


  final AppState state;
  final Device device;

  @override
  State<AppPickerScreen> createState() => _AppPickerScreenState();
}

class _AppPickerScreenState extends State<AppPickerScreen> {
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
