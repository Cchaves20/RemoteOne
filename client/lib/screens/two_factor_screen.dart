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
        SnackBar(content: Text(widget.state.t.twoFactorEnabled)),
      );
      navigator.pop();
    } catch (e) {
      messenger.showSnackBar(SnackBar(content: Text(e.toString())));
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = widget.state.t;
    return Scaffold(
      appBar: AppBar(title: Text(t.twoFactorTitle)),
      body: _error != null
          ? Center(child: Padding(padding: const EdgeInsets.all(24), child: Text(_error!)))
          : ListView(
              padding: const EdgeInsets.all(20),
              children: [
                Text(t.twoFactorSteps),
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
                      label: Text(t.manualCode(_secret!)),
                      onPressed: () {
                        Clipboard.setData(ClipboardData(text: _secret!));
                        ScaffoldMessenger.of(context).showSnackBar(
                          SnackBar(content: Text(t.codeCopied)),
                        );
                      },
                    ),
                  ),
                const SizedBox(height: 20),
                TextField(
                  controller: _code,
                  keyboardType: TextInputType.number,
                  decoration: InputDecoration(labelText: t.sixDigitCode),
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
                      : Text(t.enable),
                ),
              ],
            ),
    );
  }
}
