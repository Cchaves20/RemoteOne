import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:deskside_client/config.dart';
import 'package:deskside_client/l10n/strings.dart';
import 'package:deskside_client/main.dart';
import 'package:deskside_client/services/api_client.dart';
import 'package:deskside_client/services/app_state.dart';
import 'package:deskside_client/services/token_store.dart';

/// Constrói um AppState com um http.Client falso, roteado por [handler]. Fixa o
/// idioma em pt-BR para as asserções de texto serem determinísticas.
///
/// O endereço padrão é o **de verdade**, e não um `http://test`, porque desde
/// que o campo de servidor passou a se abrir sozinho fora do padrão, o endereço
/// deixou de ser detalhe: com um endereço estranho, a tela de login é outra.
/// O `MockClient` intercepta tudo de qualquer jeito — a URL nunca é buscada —,
/// então usar a real não custa nada e faz o teste ver a tela que o usuário vê.
AppState _stateWith(
  Future<http.Response> Function(http.Request) handler, {
  String baseUrl = backendPadrao,
}) {
  final mock = MockClient((req) => handler(req));
  return AppState(ApiClient(
    baseUrl: baseUrl,
    httpClient: mock,
    tokenStore: InMemoryTokenStore(),
  ))
    ..language = AppLanguage.ptBr;
}

/// Preenche o login e toca em Entrar, **rolando até o botão antes de tocar**.
///
/// O `ensureVisible` não é zelo: o formulário mora num `SingleChildScrollView`,
/// a janela de teste tem 600 px de altura, e o botão fica perto desse limite.
/// Um campo a mais na tela empurra o "Entrar" para fora da área visível, e aí
/// o `tap` erra o alvo — foi assim que estes dois testes quebraram quando o
/// botão "voltar ao servidor padrão" nasceu, sem que nada do produto estivesse
/// errado. Rolar até o botão é o que uma pessoa faria, então é o que o teste faz.
Future<void> _entrar(
  WidgetTester tester, {
  String contato = 'caio@example.com',
  String senha = 'senhaSegura123',
}) async {
  await tester.enterText(find.byType(TextField).at(0), contato);
  await tester.enterText(find.byType(TextField).at(1), senha);
  final botao = find.widgetWithText(FilledButton, 'Entrar');
  await tester.ensureVisible(botao);
  await tester.pumpAndSettle();
  await tester.tap(botao);
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('mostra a tela de login quando não autenticado', (tester) async {
    final state = _stateWith((_) async => http.Response('{}', 200));
    await tester.pumpWidget(DesksideApp(state: state));

    expect(find.text('Deskside'), findsOneWidget);
    expect(find.text('Entrar'), findsWidgets);
    expect(find.text('Criar uma conta'), findsOneWidget);
  });

  testWidgets('no servidor padrão, o endereço não aparece na tela', (tester) async {
    // Enquanto o padrão embutido era `localhost`, este campo era obrigatório.
    // Agora ele é ruído: um campo de URL na entrada de um produto para o público
    // diz "isto é ferramenta de programador", e é mais uma coisa para preencher
    // errado.
    final state = _stateWith(
      (_) async => http.Response('{}', 200),
      baseUrl: backendPadrao,
    );
    await tester.pumpWidget(DesksideApp(state: state));

    expect(find.text('Servidor'), findsNothing);
    expect(find.text('Usar outro servidor'), findsOneWidget);
  });

  testWidgets('com endereço fora do padrão, ele aparece já aberto', (tester) async {
    // O caso que a escolha precisa cobrir: quem apontou o app para a própria
    // rede, ou ficou com um endereço que parou de responder. Escondido, o login
    // falharia e nada na tela explicaria por quê — e o único conserto seria
    // reinstalar o app.
    final state = _stateWith((_) async => http.Response('{}', 200),
        baseUrl: 'http://192.168.0.10:8000');
    await tester.pumpWidget(DesksideApp(state: state));

    expect(find.text('Servidor'), findsOneWidget);
    expect(find.text('Voltar ao servidor padrão'), findsOneWidget);
  });

  testWidgets('login bem-sucedido leva à lista de dispositivos', (tester) async {
    final state = _stateWith((req) async {
      if (req.url.path == '/api/v1/auth/login') {
        return http.Response(
          jsonEncode({'access_token': 'a', 'refresh_token': 'r'}),
          200,
        );
      }
      if (req.url.path == '/api/v1/devices') {
        return http.Response(jsonEncode([]), 200);
      }
      return http.Response('{}', 404);
    });

    await tester.pumpWidget(DesksideApp(state: state));
    await _entrar(tester);

    expect(find.text('Meus computadores'), findsOneWidget);
    // A tela de primeiro uso, e não só o título dela: o que importa é que ela
    // diga **o que fazer**. O texto anterior ("toque em + e informe o código
    // exibido pelo agente") supunha um programa já instalado no computador e
    // nunca mencionava que havia algo a instalar — era um beco sem saída, e
    // este teste passava do mesmo jeito.
    expect(find.textContaining('Nenhum computador'), findsOneWidget);
    expect(find.textContaining('baixe o Deskside'), findsOneWidget);
    expect(find.widgetWithText(FilledButton, 'Tenho um código'), findsOneWidget);
  });

  testWidgets('erro de login exibe mensagem', (tester) async {
    final state = _stateWith((req) async {
      return http.Response(jsonEncode({'detail': 'e-mail ou senha inválidos'}), 401);
    });

    await tester.pumpWidget(DesksideApp(state: state));
    await _entrar(tester, contato: 'x@y.com');

    expect(find.text('e-mail ou senha inválidos'), findsOneWidget);
    expect(find.text('Meus computadores'), findsNothing);
  });
}
