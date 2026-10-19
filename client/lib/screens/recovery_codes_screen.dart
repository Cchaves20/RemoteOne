import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:share_plus/share_plus.dart';

import '../l10n/strings.dart';

/// Mostra os códigos de recuperação, uma vez só.
///
/// O servidor guarda só um resumo de cada um: saindo desta tela, ninguém — nem
/// o Deskside — consegue mostrá-los de novo. Por isso a saída fica presa à
/// caixa "Guardei": fechar sem querer aqui é ficar com a verificação ligada e
/// sem a saída para quando o celular sumir.
class RecoveryCodesScreen extends StatefulWidget {
  const RecoveryCodesScreen({super.key, required this.t, required this.codigos});

  final Strings t;
  final List<String> codigos;

  @override
  State<RecoveryCodesScreen> createState() => _RecoveryCodesScreenState();
}

class _RecoveryCodesScreenState extends State<RecoveryCodesScreen> {
  bool _guardou = false;

  String get _texto => widget.codigos.join('\n');

  void _copiar() {
    Clipboard.setData(ClipboardData(text: _texto));
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(widget.t.recoveryCodesCopied)),
    );
  }

  Future<void> _compartilhar(BuildContext botao) async {
    // A origem é exigida no iPad: sem ela a folha de compartilhamento não sabe
    // de onde sair e o app fecha.
    final caixa = botao.findRenderObject() as RenderBox?;
    await SharePlus.instance.share(
      ShareParams(
        text: 'Deskside — ${widget.t.recoveryCodesTitle}\n\n$_texto',
        sharePositionOrigin: caixa == null
            ? null
            : caixa.localToGlobal(Offset.zero) & caixa.size,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final t = widget.t;
    final theme = Theme.of(context);
    return PopScope(
      canPop: _guardou,
      onPopInvokedWithResult: (saiu, _) {
        if (!saiu) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text(t.recoveryCodesMustConfirm)),
          );
        }
      },
      child: Scaffold(
        appBar: AppBar(
          title: Text(t.recoveryCodesTitle),
          automaticallyImplyLeading: false,
        ),
        body: SafeArea(
          child: ListView(
            padding: const EdgeInsets.all(20),
            children: [
              Icon(Icons.key_outlined, size: 48, color: theme.colorScheme.primary),
              const SizedBox(height: 12),
              Text(
                t.recoveryCodesHeadline,
                textAlign: TextAlign.center,
                style: theme.textTheme.titleLarge,
              ),
              const SizedBox(height: 8),
              Text(
                t.recoveryCodesExplain,
                textAlign: TextAlign.center,
                style: theme.textTheme.bodyMedium
                    ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
              ),
              const SizedBox(height: 20),
              Container(
                padding: const EdgeInsets.symmetric(vertical: 16, horizontal: 8),
                decoration: BoxDecoration(
                  color: theme.colorScheme.surfaceContainerHighest,
                  borderRadius: BorderRadius.circular(16),
                ),
                child: Wrap(
                  alignment: WrapAlignment.center,
                  spacing: 24,
                  runSpacing: 10,
                  children: [
                    for (final codigo in widget.codigos)
                      SelectableText(
                        codigo,
                        style: theme.textTheme.titleMedium?.copyWith(
                          fontFamily: 'monospace',
                          letterSpacing: 1.5,
                        ),
                      ),
                  ],
                ),
              ),
              const SizedBox(height: 16),
              Row(
                children: [
                  Expanded(
                    child: OutlinedButton.icon(
                      onPressed: _copiar,
                      icon: const Icon(Icons.copy, size: 18),
                      label: Text(t.actionCopy),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Builder(
                      builder: (botao) => OutlinedButton.icon(
                        onPressed: () => _compartilhar(botao),
                        icon: const Icon(Icons.ios_share, size: 18),
                        label: Text(t.share),
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 16),
              CheckboxListTile(
                contentPadding: EdgeInsets.zero,
                controlAffinity: ListTileControlAffinity.leading,
                value: _guardou,
                onChanged: (v) => setState(() => _guardou = v ?? false),
                title: Text(t.recoveryCodesSaved),
              ),
              const SizedBox(height: 8),
              FilledButton(
                onPressed: _guardou ? () => Navigator.of(context).pop() : null,
                child: Text(t.recoveryCodesDone),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
