import 'package:flutter_test/flutter_test.dart';
import 'package:deskside_client/l10n/strings.dart';
import 'package:deskside_client/services/diagnostico_video.dart';

/// Cada caso aqui é uma contagem que um aparelho de verdade produziu, ou
/// produziria. O primeiro é literalmente o da tela que motivou esta mudança.
void main() {
  group('diagnosticar', () {
    test('computador só com host = bloqueio na máquina dele', () {
      // A captura que motivou tudo isto: um firewall no PC bloqueando o acesso
      // ao servidor de conexão. A mensagem antiga dizia "1 host"; esta função
      // diz "o computador não conseguiu falar com o servidor" — que é a mesma
      // coisa, para alguém que possa agir.
      expect(
        diagnosticar(
          celular: {'host': 24, 'srflx': 3, 'relay': 6},
          computador: {'host': 1},
        ),
        CausaDaFalha.computadorBloqueado,
      );
    });

    test('computador sem candidato nenhum = ele não respondeu', () {
      // Diferente do anterior, e a diferença importa: aqui não é rede, é o
      // agente que não falou. Mandar a pessoa mexer no firewall seria mandá-la
      // para o lugar errado.
      expect(
        diagnosticar(celular: {'host': 20, 'relay': 4}, computador: {}),
        CausaDaFalha.computadorNaoRespondeu,
      );
    });

    test('celular só com host = bloqueio do lado de cá', () {
      expect(
        diagnosticar(
          celular: {'host': 3},
          computador: {'host': 5, 'srflx': 1, 'relay': 2},
        ),
        CausaDaFalha.celularBloqueado,
      );
    });

    test('os dois com repasse e mesmo assim falhou = a rede no meio', () {
      // O caso do Wi-Fi corporativo e do hotel: há por onde tentar dos dois
      // lados, e alguém no caminho derruba assim mesmo.
      expect(
        diagnosticar(
          celular: {'host': 10, 'srflx': 2, 'relay': 4},
          computador: {'host': 6, 'srflx': 1, 'relay': 3},
        ),
        CausaDaFalha.redeBloqueia,
      );
    });

    test('nenhum dos dois com repasse = faltou o relay', () {
      // Duas redes que não se enxergam precisam de repasse. Sem ele, ter
      // srflx dos dois lados não basta.
      expect(
        diagnosticar(
          celular: {'host': 10, 'srflx': 2},
          computador: {'host': 6, 'srflx': 1},
        ),
        CausaDaFalha.semRepasse,
      );
    });

    test('quando não dá para afirmar, não afirma', () {
      // Um lado com repasse e o outro não é ambíguo: pode ser a rede, pode ser
      // credencial de TURN vencida de um lado só. Um palpite errado manda a
      // pessoa mexer no firewall dela à toa, e ela não vai desfazer depois.
      expect(
        diagnosticar(
          celular: {'host': 10, 'srflx': 2, 'relay': 3},
          computador: {'host': 6, 'srflx': 1},
        ),
        CausaDaFalha.indefinida,
      );
    });

    test('host junto de srflx não é "só host"', () {
      // A armadilha da implementação: quem conseguiu falar com o STUN **não**
      // está bloqueado, mesmo tendo host na lista. Tratar isso como bloqueio
      // acusaria firewall em quase toda falha.
      final causa = diagnosticar(
        celular: {'host': 24, 'srflx': 3, 'relay': 6},
        computador: {'host': 4, 'srflx': 1},
      );
      expect(causa, isNot(CausaDaFalha.computadorBloqueado));
    });

    test('contagem zero não conta como presente', () {
      // Um mapa pode carregar a chave com zero se alguém mudar o contador.
      // `{'relay': 0}` não é ter repasse.
      expect(
        diagnosticar(
          celular: {'host': 5, 'srflx': 1, 'relay': 0},
          computador: {'host': 5, 'srflx': 1, 'relay': 0},
        ),
        CausaDaFalha.semRepasse,
      );
    });
  });

  group('textoDaCausa', () {
    test('toda causa tem um texto próprio, em todos os idiomas', () {
      // O `switch` exaustivo já obriga a escrever *algum* texto para uma causa
      // nova. O que ele não pega é o copiar-e-colar: duas causas apontando
      // para a mesma frase deixariam a mensagem dizendo a coisa errada com
      // toda a confiança do mundo.
      for (final lang in AppLanguage.values) {
        final t = Strings(lang);
        final textos = CausaDaFalha.values.map((c) => textoDaCausa(t, c));
        expect(textos.any((s) => s.trim().isEmpty), isFalse,
            reason: 'texto vazio em $lang');
        expect(textos.toSet().length, CausaDaFalha.values.length,
            reason: 'texto repetido entre causas em $lang');
      }
    });

    test('a causa acionável diz onde mexer', () {
      // Não basta ser uma frase qualquer: a de firewall existe para mandar a
      // pessoa ao lugar certo. Se alguém suavizar isso para um "não foi
      // possível conectar", a mensagem volta a ser inútil.
      final texto = textoDaCausa(
        const Strings(AppLanguage.ptBr),
        CausaDaFalha.computadorBloqueado,
      );
      expect(texto.toLowerCase(), contains('firewall'));
    });
  });
}
