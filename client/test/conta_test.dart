import 'package:deskside_client/models/conta.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('plano da conta', () {
    test('lê o plano e o prazo que o servidor mandou', () {
      final conta = Conta.fromJson({
        'id': 1,
        'email': 'a@b.com',
        'plano': 'pago',
        'plano_ate': '2026-09-30T12:00:00Z',
      });

      expect(conta.ehPago, isTrue);
      expect(conta.planoAte, isNotNull);
    });

    test('backend antigo, sem os campos, cai no grátis em vez de quebrar', () {
      // O app novo pode falar com um servidor velho por alguns minutos durante
      // o deploy. Cair no grátis é o único padrão seguro: o contrário mostraria
      // recursos que a chamada seguinte recusaria.
      final conta = Conta.fromJson({'id': 1, 'email': 'a@b.com'});

      expect(conta.ehPago, isFalse);
      expect(conta.planoAte, isNull);
      expect(conta.diasRestantes, isNull);
    });

    test('data em formato inesperado não derruba a tela da conta', () {
      // `tryParse` e não `parse`. Uma data estranha vinda do servidor não pode
      // custar a tela inteira — o pior aceitável é não saber o prazo.
      final conta = Conta.fromJson({
        'id': 1,
        'email': 'a@b.com',
        'plano': 'pago',
        'plano_ate': 'ontem de manhã',
      });

      expect(conta.ehPago, isTrue);
      expect(conta.planoAte, isNull);
    });

    test('os dias arredondam para cima, como uma pessoa conta', () {
      // Faltando 6 horas, ninguém diz "faltam zero dias" — diz "termina
      // amanhã". Arredondar para baixo faria o app dizer que já acabou.
      final seisHoras = Conta.fromJson({
        'id': 1,
        'plano': 'pago',
        'plano_ate': DateTime.now().add(const Duration(hours: 6)).toIso8601String(),
      });
      expect(seisHoras.diasRestantes, 1);

      final doisDias = Conta.fromJson({
        'id': 1,
        'plano': 'pago',
        'plano_ate': DateTime.now().add(const Duration(hours: 36)).toIso8601String(),
      });
      expect(doisDias.diasRestantes, 2);
    });

    test('prazo vencido é zero, e não um número negativo', () {
      final vencida = Conta.fromJson({
        'id': 1,
        'plano': 'pago',
        'plano_ate': DateTime.now().subtract(const Duration(days: 3)).toIso8601String(),
      });

      expect(vencida.diasRestantes, 0);
    });
  });

  group('em teste', () {
    test('o servidor diz, e o app não deduz', () {
      // Teste e assinatura chegam os dois como `pago` com trinta dias. Quem
      // enxerga a diferença é o servidor, que vê a tabela de assinaturas.
      final conta = Conta.fromJson({
        'id': 1,
        'plano': 'pago',
        'plano_ate': DateTime.now().add(const Duration(days: 30)).toIso8601String(),
        'em_teste': true,
      });

      expect(conta.emTeste, isTrue);
      expect(conta.ehPago, isTrue);
    });

    test('servidor que não manda o campo vira falso', () {
      // Errar dizendo "não é teste" apenas omite um selo. Errar ao contrário
      // poria "Teste grátis" no cartão de quem paga.
      final conta = Conta.fromJson({'id': 1, 'plano': 'pago'});

      expect(conta.emTeste, isFalse);
    });

    test('quem comprou não aparece como teste', () {
      final conta = Conta.fromJson({
        'id': 1,
        'plano': 'pago',
        'plano_ate': DateTime.now().add(const Duration(days: 12)).toIso8601String(),
        'em_teste': false,
      });

      expect(conta.emTeste, isFalse);
    });
  });
}
