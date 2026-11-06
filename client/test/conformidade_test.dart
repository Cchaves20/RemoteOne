import 'dart:convert';

import 'package:deskside_client/config.dart';
import 'package:deskside_client/l10n/strings.dart';
import 'package:deskside_client/models/conta.dart';
import 'package:deskside_client/services/api_client.dart';
import 'package:deskside_client/services/token_store.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

/// Aceite dos termos e cópia dos próprios dados (LGPD), do lado do app.
void main() {
  group('Conta.termosPendentes', () {
    test('conta que aceitou a versão em vigor não é incomodada', () {
      final c = Conta.fromJson(
          {'id': 1, 'termos_versao': '2026-11', 'termos_atual': '2026-11'});
      expect(c.termosPendentes, isFalse);
    });

    test('conta de antes do aceite, ou de uma versão antiga, é pedida', () {
      expect(
          Conta.fromJson(
                  {'id': 1, 'termos_versao': '', 'termos_atual': '2026-11'})
              .termosPendentes,
          isTrue);
      expect(
          Conta.fromJson({
            'id': 1,
            'termos_versao': '2026-01',
            'termos_atual': '2026-11'
          }).termosPendentes,
          isTrue);
    });

    test('servidor antigo, sem o campo, não trava o app num pedido sem saída',
        () {
      expect(Conta.fromJson({'id': 1}).termosPendentes, isFalse);
    });
  });

  test('o cadastro manda a versão dos termos que o app mostra', () async {
    Map<String, dynamic>? corpo;
    final api = ApiClient(
      baseUrl: 'http://test',
      tokenStore: InMemoryTokenStore(),
      httpClient: MockClient((req) async {
        corpo = jsonDecode(req.body) as Map<String, dynamic>;
        return http.Response(
          jsonEncode({
            'destination': 'a@b.com',
            'channel': 'email',
            'resend_in_seconds': 60,
            'delivered': true,
          }),
          201,
        );
      }),
    );
    await api.signupStart(
      firstName: 'Ana',
      lastName: 'Souza',
      birthDate: DateTime(1998, 4, 20),
      email: 'a@b.com',
      password: 'Senha-Segura1',
      passwordConfirm: 'Senha-Segura1',
    );
    expect(corpo!['terms_version'], versaoDosTermos);
  });

  test('aceitar e exportar chamam as rotas certas', () async {
    final caminhos = <String>[];
    final api = ApiClient(
      baseUrl: 'http://test',
      tokenStore: InMemoryTokenStore(),
      httpClient: MockClient((req) async {
        caminhos.add('${req.method} ${req.url.path}');
        if (req.url.path.endsWith('/me/terms')) {
          expect(jsonDecode(req.body), {'version': versaoDosTermos});
          return http.Response('', 204);
        }
        return http.Response(
            jsonEncode({
              'conta': {'email': 'a@b.com'}
            }),
            200);
      }),
    );
    await api.acceptTerms();
    final json = await api.exportMyData();
    expect(jsonDecode(json)['conta']['email'], 'a@b.com');
    expect(
        caminhos, ['POST /api/v1/auth/me/terms', 'GET /api/v1/auth/me/export']);
  });

  test('os textos novos existem nos cinco idiomas', () {
    for (final lang in AppLanguage.values) {
      final t = Strings(lang);
      expect(t.termosAceitoPrefixo, isNotEmpty, reason: '$lang');
      expect(t.exportarDados, isNotEmpty, reason: '$lang');
      expect(t.gerenciarAssinatura, isNotEmpty, reason: '$lang');
      expect(t.telaDoComputadorRotulo, isNotEmpty, reason: '$lang');
    }
  });
}
