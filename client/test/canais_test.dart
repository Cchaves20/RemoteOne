import 'package:flutter_test/flutter_test.dart';
import 'package:deskside_client/models/canais.dart';

/// O que decide se a tela de cadastro oferece "telefone".
///
/// O caso que motivou tudo isto é o primeiro: o servidor de produção responde
/// `sms: false`, e o app oferecia telefone do mesmo jeito.
void main() {
  group('CanaisDeEntrega.doHealth', () {
    test('o servidor de hoje: e-mail sim, SMS não', () {
      final c = CanaisDeEntrega.doHealth({
        'status': 'ok',
        'delivery': {'email': true, 'sms': false},
      });
      expect(c.email, isTrue);
      expect(c.sms, isFalse);
      expect(c.haEscolha, isFalse, reason: 'com um caminho só, sem seletor');
      expect(c.unicoPorTelefone, isFalse, reason: 'o caminho é e-mail');
    });

    test('os dois ligados: a escolha aparece', () {
      final c = CanaisDeEntrega.doHealth({
        'delivery': {'email': true, 'sms': true},
      });
      expect(c.haEscolha, isTrue);
    });

    test('sem o bloco delivery, assume os dois', () {
      // Um servidor mais antigo que este campo. Assumir "nenhum" deixaria o app
      // sem caminho de cadastro nenhum — pior do que o aviso vermelho.
      final c = CanaisDeEntrega.doHealth({'status': 'ok'});
      expect(c.email, isTrue);
      expect(c.sms, isTrue);
    });

    test('bloco vazio também assume os dois', () {
      // A armadilha da implementação: `bloco['sms']` devolve nulo aqui, e
      // tratar nulo como `false` esconderia as duas opções de uma vez.
      final c = CanaisDeEntrega.doHealth({'delivery': {}});
      expect(c.email, isTrue);
      expect(c.sms, isTrue);
      expect(c.haEscolha, isTrue);
    });

    test('valor que não é booleano não derruba a tela', () {
      final c = CanaisDeEntrega.doHealth({
        'delivery': {'email': 'sim', 'sms': 0},
      });
      expect(c.email, isTrue);
      expect(c.sms, isTrue);
    });

    test('corpo que não é mapa', () {
      expect(CanaisDeEntrega.doHealth(null).haEscolha, isTrue);
      expect(CanaisDeEntrega.doHealth('caiu').haEscolha, isTrue);
      expect(CanaisDeEntrega.doHealth(42).haEscolha, isTrue);
    });

    test('só SMS: o caminho único é o telefone', () {
      // Improvável, mas é o único caso em que a tela deve abrir no telefone
      // sem o seletor. Se `unicoPorTelefone` fosse fixo em `false`, este
      // servidor mostraria um campo de e-mail que não entrega nada.
      final c = CanaisDeEntrega.doHealth({
        'delivery': {'email': false, 'sms': true},
      });
      expect(c.haEscolha, isFalse);
      expect(c.unicoPorTelefone, isTrue);
    });

    test('os dois desligados caem no e-mail', () {
      // Servidor sem entrega nenhuma: o cadastro não vai funcionar de qualquer
      // forma, e aí vale mostrar o caminho que não custa por mensagem.
      final c = CanaisDeEntrega.doHealth({
        'delivery': {'email': false, 'sms': false},
      });
      expect(c.haEscolha, isFalse);
      expect(c.unicoPorTelefone, isFalse);
    });
  });

  test('desconhecido é o comportamento antigo', () {
    // Se isto mudar, uma falha de rede passa a esconder opções em vez de
    // manter o que o app sempre fez.
    expect(CanaisDeEntrega.desconhecido.email, isTrue);
    expect(CanaisDeEntrega.desconhecido.sms, isTrue);
    expect(CanaisDeEntrega.desconhecido.haEscolha, isTrue);
  });
}
