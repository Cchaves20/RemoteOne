import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../config.dart';
import '../services/app_state.dart';

/// Abre uma página do site (`/termos`, `/privacidade`) no navegador.
///
/// Avisa quando não abre: o `launchUrl` devolve `false` em vez de lançar
/// quando não há navegador, e um toque sem resposta parece app quebrado.
Future<void> abrirNoSite(
    BuildContext context, AppState state, String caminho) async {
  final endereco = Uri.parse('https://$siteDeskside$caminho');
  var abriu = false;
  try {
    abriu = await launchUrl(endereco, mode: LaunchMode.externalApplication);
  } catch (_) {
    abriu = false;
  }
  if (!abriu && context.mounted) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(state.t.assinaturaLinkFalhou)),
    );
  }
}

/// "Li e aceito os Termos de uso e a Política de privacidade", com os dois
/// nomes tocáveis. O leitor de tela anuncia cada um como link.
class TextoDeAceite extends StatelessWidget {
  const TextoDeAceite({super.key, required this.state, this.estilo});

  final AppState state;
  final TextStyle? estilo;

  @override
  Widget build(BuildContext context) {
    final t = state.t;
    // A cor de "ao vivo", a dos links do app inteiro.
    final cor = Theme.of(context).colorScheme.secondary;
    Widget link(String texto, String caminho) => Semantics(
          link: true,
          button: false,
          child: InkWell(
            onTap: () => abrirNoSite(context, state, caminho),
            child: Text(
              texto,
              style: (estilo ?? const TextStyle()).copyWith(
                color: cor,
                decoration: TextDecoration.underline,
              ),
            ),
          ),
        );
    return Wrap(
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        Text(t.termosAceitoPrefixo, style: estilo),
        link(t.assinaturaTermos, '/termos'),
        Text(t.termosAceitoMeio, style: estilo),
        link(t.assinaturaPrivacidade, '/privacidade'),
      ],
    );
  }
}

/// Pede o aceite de uma versão nova dos termos, sem fechar por fora.
///
/// Não tem "agora não": sem aceite da versão em vigor não há contrato, e o
/// servidor só conhece aceites daquela versão. Quem não quiser aceitar pode
/// sair da conta, ou excluí-la, nas configurações - que continuam ao alcance
/// depois de fechar o app.
Future<void> pedirAceiteDosTermos(BuildContext context, AppState state) {
  final t = state.t;
  var enviando = false;
  return showDialog<void>(
    context: context,
    barrierDismissible: false,
    builder: (dialogo) => PopScope(
      canPop: false,
      child: StatefulBuilder(
        builder: (dialogo, setDialogo) => AlertDialog(
          title: Text(t.termosNovaVersaoTitulo),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(t.termosNovaVersaoTexto),
              const SizedBox(height: 14),
              TextoDeAceite(state: state),
            ],
          ),
          actions: [
            FilledButton(
              onPressed: enviando
                  ? null
                  : () async {
                      setDialogo(() => enviando = true);
                      try {
                        await state.acceptTerms();
                        if (dialogo.mounted) Navigator.of(dialogo).pop();
                      } catch (_) {
                        setDialogo(() => enviando = false);
                        if (dialogo.mounted) {
                          ScaffoldMessenger.of(dialogo).showSnackBar(
                            SnackBar(content: Text(t.termosAceitarFalhou)),
                          );
                        }
                      }
                    },
              child: Text(t.termosAceitar),
            ),
          ],
        ),
      ),
    ),
  );
}
