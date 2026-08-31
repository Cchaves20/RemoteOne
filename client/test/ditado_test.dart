import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:deskside_client/l10n/strings.dart';
import 'package:deskside_client/widgets/ditado.dart';
import 'package:deskside_client/widgets/remote_keyboard.dart';

/// Monta a caixa de ditado sozinha, guardando o que ela entregou.
///
/// Sem tela de controle em volta de propósito: o que está sendo verificado é o
/// contrato da caixa — o que sai dela e quando —, e montar a `RemoteScreen`
/// inteira arrastaria vídeo, WebSocket e um dispositivo pareado para dentro de
/// um teste sobre um campo de texto e dois botões.
Future<List<String>> _montar(
  WidgetTester tester, {
  VoidCallback? aoFechar,
}) async {
  final enviados = <String>[];
  await tester.pumpWidget(MaterialApp(
    home: Scaffold(
      body: CaixaDeDitado(
        t: const Strings(AppLanguage.ptBr),
        onEnviar: enviados.add,
        onFechar: aoFechar ?? () {},
      ),
    ),
  ));
  return enviados;
}

/// O botão, pelo tipo-base. `FilledButton.icon` constrói uma subclasse, e o
/// `find.byType` casa por tipo exato — por isso a busca é por chave e o molde
/// é `ButtonStyleButton`, que é de quem os dois herdam.
ButtonStyleButton _botao(WidgetTester tester, Key chave) =>
    tester.widget<ButtonStyleButton>(find.byKey(chave));

void main() {
  group('CaixaDeDitado', () {
    testWidgets('não entrega nada enquanto o campo está vazio', (tester) async {
      final enviados = await _montar(tester);

      // O botão existe, mas desligado. É a diferença entre "não dá para mandar
      // agora" e um botão que some — que faria a pessoa procurar onde manda.
      expect(_botao(tester, chaveDitadoEnviar).onPressed, isNull);

      // `warnIfMissed: false`: um botão desligado não recebe o toque, e o
      // aviso do framework aqui seria ruído — é exatamente o que se espera.
      await tester.tap(find.byKey(chaveDitadoEnviar), warnIfMissed: false);
      await tester.pump();
      expect(enviados, isEmpty);
    });

    testWidgets('só espaço em branco não conta como texto', (tester) async {
      // O caso que o ditado cria sozinho: a pessoa toca no microfone, desiste
      // sem falar, e o teclado deixa um espaço no campo. Mandar isso digitaria
      // um espaço solto no computador, do nada.
      final enviados = await _montar(tester);
      await tester.enterText(find.byKey(chaveDitadoCampo), '   ');
      await tester.pump();

      expect(_botao(tester, chaveDitadoEnviar).onPressed, isNull);
      expect(enviados, isEmpty);
    });

    testWidgets('entrega o texto sem os espaços das pontas', (tester) async {
      final enviados = await _montar(tester);
      await tester.enterText(find.byKey(chaveDitadoCampo), '  bom dia  ');
      await tester.pump();

      await tester.tap(find.byKey(chaveDitadoEnviar));
      await tester.pump();
      expect(enviados, ['bom dia']);
    });

    testWidgets('limpa o campo depois de enviar', (tester) async {
      // Ditar acontece em pedaços: uma frase, confere, manda, outra frase. Se
      // o texto ficasse no campo, a segunda frase sairia grudada na primeira e
      // o computador receberia a primeira duas vezes.
      final enviados = await _montar(tester);
      await tester.enterText(find.byKey(chaveDitadoCampo), 'primeira frase');
      await tester.pump();
      await tester.tap(find.byKey(chaveDitadoEnviar));
      await tester.pump();

      final campo = tester.widget<TextField>(find.byKey(chaveDitadoCampo));
      expect(campo.controller?.text, isEmpty);

      await tester.enterText(find.byKey(chaveDitadoCampo), 'segunda frase');
      await tester.pump();
      await tester.tap(find.byKey(chaveDitadoEnviar));
      await tester.pump();
      expect(enviados, ['primeira frase', 'segunda frase']);
    });

    testWidgets('o botão de limpar apaga sem enviar nada', (tester) async {
      final enviados = await _montar(tester);
      await tester.enterText(find.byKey(chaveDitadoCampo), 'não era isso');
      await tester.pump();
      await tester.tap(find.byKey(chaveDitadoLimpar));
      await tester.pump();

      final campo = tester.widget<TextField>(find.byKey(chaveDitadoCampo));
      expect(campo.controller?.text, isEmpty);
      expect(enviados, isEmpty);
    });

    testWidgets('o campo não aceita mais do que o servidor', (tester) async {
      // 4096 é o `max_length` de `key_text` no backend (`app/input.py`). Sem o
      // teto aqui, um texto longo só seria recusado **depois** de a pessoa
      // falar, num 422 sem explicação.
      await _montar(tester);
      final campo = tester.widget<TextField>(find.byKey(chaveDitadoCampo));
      expect(campo.maxLength, limiteDeCaracteres);
      expect(limiteDeCaracteres, 4096);
    });

    testWidgets('o corretor e a previsão do aparelho ficam ligados',
        (tester) async {
      // São o motivo de a caixa existir para quem nunca vai ditar: dentro de
      // um campo nativo, o aparelho traz correção, previsão e o dicionário
      // pessoal de quem digita — coisas que o teclado desenhado não alcança,
      // porque o iOS não expõe o QuickType por API. Desligar qualquer um dos
      // dois esvaziaria metade do widget sem quebrar nada visível.
      await _montar(tester);
      final campo = tester.widget<TextField>(find.byKey(chaveDitadoCampo));
      expect(campo.autocorrect, isTrue);
      expect(campo.enableSuggestions, isTrue);
    });

    testWidgets('o interruptor devolve o teclado desenhado', (tester) async {
      // A outra metade da troca. O microfone leva para cá; esta tecla, no
      // mesmo canto da linha de baixo, leva de volta. Uma tecla só, sempre no
      // mesmo lugar, nos dois sentidos.
      var fechou = false;
      await _montar(tester, aoFechar: () => fechou = true);
      await tester.tap(find.byKey(chaveDitadoTeclado));
      await tester.pump();
      expect(fechou, isTrue);
    });

    testWidgets('o aviso de que não aperta Enter está sempre à vista',
        (tester) async {
      // Não é decoração: é a diferença entre escrever um comando e executá-lo,
      // e não há como descobrir isso tentando — quem tentar, executou. Saiu do
      // topo da caixa para debaixo do campo quando o cabeçalho foi removido, e
      // este teste existe para não sumir junto na próxima limpeza.
      await _montar(tester);
      expect(find.text(const Strings(AppLanguage.ptBr).ditadoSemEnter),
          findsOneWidget);
    });

    testWidgets('o envio não manda Enter junto', (tester) async {
      // A propriedade que mais importa deste widget. Um bloco de texto com
      // Enter no fim enviaria o formulário, rodaria a linha do terminal ou
      // mandaria a mensagem — sem ninguém ter pedido. O contrato é: sai texto,
      // e só texto.
      final enviados = await _montar(tester);
      await tester.enterText(find.byKey(chaveDitadoCampo), 'ls -la');
      await tester.pump();
      await tester.tap(find.byKey(chaveDitadoEnviar));
      await tester.pump();

      expect(enviados.single, 'ls -la');
      expect(enviados.single, isNot(contains('\n')));
    });
  });

  group('Tecla de microfone do teclado', () {
    Future<void> montarTeclado(
      WidgetTester tester, {
      VoidCallback? aoDitar,
    }) {
      return tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: RemoteKeyboard(
            onText: (_) {},
            onKey: (_) {},
            onCombo: (_, __) {},
            onDitar: aoDitar,
          ),
        ),
      ));
    }

    testWidgets('sem callback de ditado, a tecla não existe', (tester) async {
      await montarTeclado(tester);
      expect(find.byIcon(Icons.mic_none), findsNothing);
    });

    testWidgets('a tecla chama quem abre o ditado', (tester) async {
      var chamou = false;
      await montarTeclado(tester, aoDitar: () => chamou = true);
      expect(find.byIcon(Icons.mic_none), findsOneWidget);
      await tester.tap(find.byIcon(Icons.mic_none));
      await tester.pump();
      expect(chamou, isTrue);
    });
  });
}
