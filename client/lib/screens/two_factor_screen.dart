import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:qr_flutter/qr_flutter.dart';

import '../services/app_state.dart';

/// Ativa a verificação em duas etapas: mostra o QR Code (e o segredo) para o
/// app autenticador e confirma com um código.
class TwoFactorScreen extends StatefulWidget {
  const TwoFactorScreen({super.key, required this.state});

  final AppState state;

  @override
  State<TwoFactorScreen> createState() => _TwoFactorScreenState();
}

class _TwoFactorScreenState extends State<TwoFactorScreen> {
  final _code = TextEditingController();
  String? _secret;
  String? _uri;
  String? _error;
  bool _busy = true;

  @override
  void initState() {
    super.initState();
    _startSetup();
  }

  @override
  void dispose() {
    _code.dispose();
    super.dispose();
  }

  Future<void> _startSetup() async {
    try {
      final data = await widget.state.setupTwoFactor();
      setState(() {
        _secret = data['secret'];
        _uri = data['otpauth_uri'];
        _busy = false;
      });
    } catch (e) {
      setState(() {
        _error = e.toString();
        _busy = false;
      });
    }
  }

  Future<void> _confirm() async {
    setState(() => _busy = true);
    final messenger = ScaffoldMessenger.of(context);
    final navigator = Navigator.of(context);
    try {
      await widget.state.enableTwoFactor(_code.text.trim());
      messenger.showSnackBar(
        const SnackBar(content: Text('Verificação em duas etapas ativada.')),
      );
      navigator.pop();
    } catch (e) {
      messenger.showSnackBar(SnackBar(content: Text(e.toString())));
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Verificação em duas etapas')),
      body: _error != null
          ? Center(child: Padding(padding: const EdgeInsets.all(24), child: Text(_error!)))
          : ListView(
              padding: const EdgeInsets.all(20),
              children: [
                const Text(
                  '1. Instale um app autenticador (Google Authenticator, '
                  'Microsoft Authenticator, etc.).\n'
                  '2. Escaneie o QR Code abaixo — ou digite o código manual.\n'
                  '3. Digite o código de 6 dígitos que o app mostrar para confirmar.',
                ),
                const SizedBox(height: 20),
                if (_uri != null)
                  Center(
                    child: Container(
                      padding: const EdgeInsets.all(12),
                      color: Colors.white,
                      child: QrImageView(data: _uri!, size: 200),
                    ),
                  ),
                const SizedBox(height: 16),
                if (_secret != null)
                  Center(
                    child: TextButton.icon(
                      icon: const Icon(Icons.copy),
                      label: Text('Código manual: ${_secret!}'),
                      onPressed: () {
                        Clipboard.setData(ClipboardData(text: _secret!));
                        ScaffoldMessenger.of(context).showSnackBar(
                          const SnackBar(content: Text('Código copiado.')),
                        );
                      },
                    ),
                  ),
                const SizedBox(height: 20),
                TextField(
                  controller: _code,
                  keyboardType: TextInputType.number,
                  decoration: const InputDecoration(
                    labelText: 'Código de 6 dígitos',
                  ),
                ),
                const SizedBox(height: 20),
                FilledButton(
                  onPressed: _busy ? null : _confirm,
                  child: _busy
                      ? const SizedBox(
                          height: 20,
                          width: 20,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Text('Ativar'),
                ),
              ],
            ),
    );
  }
}
