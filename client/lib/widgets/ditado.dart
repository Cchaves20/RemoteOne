/// Ditar texto para o computador, usando o microfone do próprio aparelho.
///
/// ## Por que existe uma caixa, e não ditado direto na tela do computador
///
/// A tentação é óbvia: falar e ver as palavras aparecendo no computador. É
/// tecnicamente possível — o `key_replace` já sabe apagar e reescrever numa
/// ação só, que é o que o reconhecimento em tempo real exige quando muda de
/// ideia sobre o que já ouviu.
///
/// E seria a versão errada. Ditado em português erra alguma coisa entre 3% e
/// 8% das palavras em condições boas, e muito mais com ruído, nome próprio ou
/// palavra em inglês no meio. Esse erro é barato num aplicativo de mensagem,
/// onde a pessoa lê e conserta antes de mandar. Aqui ele é caro: a tela do
/// computador chega por vídeo com atraso, corrigir exige setas e backspaces
/// atravessando a rede, e se o cursor estiver num terminal, palavra errada é
/// comando errado.
///
/// Então o desenho não persegue reconhecimento perfeito. Ele põe a conferência
/// onde o erro custa pouco: **no celular, antes de sair**. Cinco por cento de
/// erro de reconhecimento vira zero por cento de erro entregue, porque tem
/// alguém lendo no meio — e continua muito mais rápido que tocar letra por
/// letra no teclado de vidro, que é o ganho de verdade.
///
/// ## Por que não pedimos permissão de microfone
///
/// Porque não tocamos no microfone. Quem escuta é o teclado do sistema, pelo
/// botão que ele já tem; o Deskside recebe texto, como receberia de qualquer
/// digitação. Não há `NSMicrophoneUsageDescription` a declarar, nem diálogo de
/// permissão, nem áudio saindo do aparelho para lugar nenhum.
///
/// Isso não é economia de trabalho: é o que permite a página de privacidade
/// continuar dizendo a verdade sem ganhar um parágrafo.
library;

import 'package:flutter/material.dart';

import '../l10n/strings.dart';

/// Teto de caracteres de um envio.
///
/// É o mesmo limite que o servidor aplica em `key_text` (`input.py`,
/// `max_length=4096`). Repetido aqui de propósito: sem ele, quem ditasse um
/// parágrafo longo só descobriria o problema **depois de falar**, num erro
/// 422 sem explicação — o pior instante possível para uma recusa.
const int limiteDeCaracteres = 4096;

/// Âncoras para os testes.
///
/// Por `Key` e não por tipo: `FilledButton.icon` e `TextButton.icon` constroem
/// **subclasses**, e o `find.byType` do Flutter casa por tipo exato — um teste
/// escrito contra `FilledButton` não acha o botão que está bem ali. Por texto
/// também não serve: quebraria ao traduzir uma palavra.
const chaveDitadoCampo = Key('ditado-campo');
const chaveDitadoEnviar = Key('ditado-enviar');
const chaveDitadoLimpar = Key('ditado-limpar');
const chaveDitadoTeclado = Key('ditado-teclado');

/// A caixa onde o texto ditado é conferido antes de ir para o computador.
class CaixaDeDitado extends StatefulWidget {
  const CaixaDeDitado({
    super.key,
    required this.t,
    required this.onEnviar,
    required this.onFechar,
  });

  final Strings t;

  /// Entrega o texto conferido. Chamado uma vez por envio, nunca com vazio.
  final void Function(String texto) onEnviar;

  /// Volta ao teclado desenhado.
  final VoidCallback onFechar;

  @override
  State<CaixaDeDitado> createState() => _CaixaDeDitadoState();
}

class _CaixaDeDitadoState extends State<CaixaDeDitado> {
  final _controle = TextEditingController();
  final _foco = FocusNode();

  @override
  void dispose() {
    _controle.dispose();
    _foco.dispose();
    super.dispose();
  }

  bool get _temTexto => _controle.text.trim().isNotEmpty;

  void _enviar() {
    final texto = _controle.text.trim();
    if (texto.isEmpty) return;
    widget.onEnviar(texto);
    // Limpa e **mantém o foco**: ditar acontece em pedaços — uma frase, olha,
    // manda, outra frase. Fechar o teclado a cada envio obrigaria a tocar no
    // campo de novo entre uma frase e a seguinte.
    _controle.clear();
    setState(() {});
    _foco.requestFocus();
  }

  @override
  Widget build(BuildContext context) {
    final t = widget.t;
    final cores = Theme.of(context).colorScheme;
    final textos = Theme.of(context).textTheme;

    return Material(
      color: cores.surfaceContainerHighest,
      child: SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Icon(Icons.mic_none, size: 18, color: cores.primary),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(t.ditadoTitulo, style: textos.titleSmall),
                  ),
                  TextButton.icon(
                    key: chaveDitadoTeclado,
                    onPressed: widget.onFechar,
                    icon: const Icon(Icons.keyboard, size: 18),
                    label: Text(t.ditadoTeclado),
                  ),
                ],
              ),
              Text(t.ditadoComo, style: textos.bodySmall),
              // Fica **acima** do campo, junto da outra explicação, e não na
              // linha dos botões: ali dentro de um `Expanded`, ao lado de dois
              // botões, esta frase quebraria em quatro linhas num celular e
              // comeria a altura que a tela do computador precisa.
              Text(
                t.ditadoSemEnter,
                style: textos.bodySmall?.copyWith(color: cores.outline),
              ),
              const SizedBox(height: 8),
              TextField(
                key: chaveDitadoCampo,
                controller: _controle,
                focusNode: _foco,
                // Abre o teclado do sistema assim que a caixa aparece, que é
                // onde mora o botão de microfone. Sem isto, a pessoa vê uma
                // caixa vazia e um convite para falar, sem nada para tocar.
                autofocus: true,
                maxLines: 4,
                minLines: 2,
                maxLength: limiteDeCaracteres,
                // `newline`, e não `send`: Enter aqui quebra linha no rascunho.
                // Mandar no Enter faria a tecla mais apertada por engano do
                // teclado disparar o envio no meio de uma frase.
                textInputAction: TextInputAction.newline,
                keyboardType: TextInputType.multiline,
                textCapitalization: TextCapitalization.sentences,
                onChanged: (_) => setState(() {}),
                decoration: InputDecoration(
                  hintText: t.ditadoCampo,
                  border: const OutlineInputBorder(),
                  isDense: true,
                  // O contador só interessa perto do teto; mostrá-lo sempre
                  // seria um número aceso embaixo de um campo que quase nunca
                  // passa de uma frase.
                  counterText: _controle.text.length > limiteDeCaracteres - 200
                      ? '${_controle.text.length}/$limiteDeCaracteres'
                      : '',
                ),
              ),
              const SizedBox(height: 4),
              Row(
                children: [
                  const Spacer(),
                  TextButton(
                    key: chaveDitadoLimpar,
                    onPressed: _temTexto
                        ? () {
                            _controle.clear();
                            setState(() {});
                            _foco.requestFocus();
                          }
                        : null,
                    child: Text(t.ditadoLimpar),
                  ),
                  const SizedBox(width: 4),
                  FilledButton.icon(
                    key: chaveDitadoEnviar,
                    onPressed: _temTexto ? _enviar : null,
                    icon: const Icon(Icons.send, size: 18),
                    label: Text(t.ditadoEnviar),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}
