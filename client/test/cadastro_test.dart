import 'package:flutter_test/flutter_test.dart';
import 'package:deskside_client/models/cadastro.dart';
import 'package:deskside_client/models/pais.dart';
import 'package:deskside_client/services/senha.dart';

/// Criação de conta: a política de senha e a limpeza do telefone.
///
/// **As duas existem também no servidor**, e a duplicação é deliberada — a
/// daqui explica enquanto a pessoa digita, a de lá decide. O que estes testes
/// protegem é que as duas continuem dizendo a mesma coisa: uma senha que o app
/// aceita e o servidor recusa é um formulário que trava sem explicar, e um
/// número que o app normaliza diferente vira uma conta que não dá para acessar.
void main() {
  group('política de senha', () {
    test('as cinco regras, uma faltando de cada vez', () {
      // Cada uma destas cumpre quatro das cinco. É o teste que pega uma regra
      // trocada por outra — algo que "senha boa passa, senha ruim não" não pega.
      const casos = {
        'semmaiuscula1!': RegraDeSenha.maiuscula,
        'SEMMINUSCULA1!': RegraDeSenha.minuscula,
        'SemNumero!!': RegraDeSenha.numero,
        'SemEspecial123': RegraDeSenha.especial,
        'Ab1!': RegraDeSenha.tamanho,
      };
      casos.forEach((senha, faltando) {
        expect(senhaValida(senha), isFalse, reason: senha);
        expect(faltando.cumprida(senha), isFalse, reason: senha);
        expect(regrasCumpridas(senha), 4, reason: senha);
      });
    });

    test('uma senha que cumpre as cinco passa', () {
      expect(senhaValida('senhaSegura123!'), isTrue);
      expect(regrasCumpridas('senhaSegura123!'), 5);
    });

    test('letra acentuada conta como letra', () {
      // Uma faixa de caracteres tipo `[A-ZÀ-Þ]` parece certa e engole o `×`,
      // que mora no meio dela. A comparação de caixa não tem esse problema, e
      // vale para qualquer alfabeto — não só o latino.
      expect(RegraDeSenha.maiuscula.cumprida('Ç'), isTrue);
      expect(RegraDeSenha.minuscula.cumprida('ç'), isTrue);
      expect(RegraDeSenha.maiuscula.cumprida('ç'), isFalse);
      expect(RegraDeSenha.maiuscula.cumprida('×'), isFalse);
      expect(RegraDeSenha.maiuscula.cumprida('123!'), isFalse);
    });

    test('acentuada também conta como "especial", nos dois lados', () {
      // Vale registrar porque surpreende: "especial" é definido por exclusão
      // (tudo que não é `A-Za-z0-9`), então `ç` cumpre a regra. É leniente, e
      // não é problema — as cinco regras são um piso, não um teto. O que
      // importaria seria o app e o servidor **discordarem**, e eles não
      // discordam: o `[^A-Za-z0-9]` daqui é o mesmo de lá.
      expect(RegraDeSenha.especial.cumprida('ç'), isTrue);
      expect(RegraDeSenha.especial.cumprida('@'), isTrue);
      expect(RegraDeSenha.especial.cumprida('abcDEF123'), isFalse);
    });

    test('espaço conta como caractere especial', () {
      // Frase-senha é um jeito legítimo e forte de escolher senha; recusá-la
      // por não ter símbolo seria empurrar para senhas piores.
      expect(RegraDeSenha.especial.cumprida('duas palavras'), isTrue);
    });
  });

  group('telefone', () {
    const br = Pais.padrao;

    test('a pontuação é enfeite de leitura', () {
      // Quem digita "(11) 98765-4321" quer o mesmo número de quem digita
      // "11987654321". Recusar um dos dois seria recusar por causa do hífen.
      for (final escrito in [
        '11987654321',
        '(11) 98765-4321',
        '11 98765 4321',
        ' 11987654321 ',
        '11.98765.4321',
      ]) {
        expect(normalizarTelefone(escrito, br), '+5511987654321', reason: escrito);
      }
    });

    test('o zero de tronco sai', () {
      // Dentro do Brasil se disca `0` antes do DDD, e muita gente escreve
      // assim. Esse zero não existe no número internacional.
      expect(normalizarTelefone('011987654321', br), '+5511987654321');
    });

    test('o código do país digitado junto não vira +55 55', () {
      expect(normalizarTelefone('+55 11 98765-4321', br), '+5511987654321');
      expect(normalizarTelefone('5511987654321', br), '+5511987654321');
    });

    test('mas um DDD que começa com 55 continua intacto', () {
      // 55 é o DDD de Santa Maria. Tirar o "55" sem conferir o que sobra
      // mutilaria um número legítimo — e o dono dele nunca conseguiria
      // se cadastrar, sem entender por quê.
      expect(normalizarTelefone('55987654321', br), '+5555987654321');
    });

    test('tamanhos impossíveis são recusados', () {
      expect(normalizarTelefone('1198765', br), isNull);
      expect(normalizarTelefone('119876543210000', br), isNull);
      expect(normalizarTelefone('', br), isNull);
      expect(normalizarTelefone('abc', br), isNull);
    });

    test('fixo de 10 dígitos vale tanto quanto celular de 11', () {
      // Um cadastro que só aceitasse 11 recusaria um telefone fixo legítimo.
      expect(normalizarTelefone('1133334444', br), '+551133334444');
    });

    test('cada país da tabela tem intervalo coerente e bandeira', () {
      // Um intervalo invertido recusaria todo número daquele país, e só se
      // descobriria quando alguém de lá tentasse se cadastrar.
      for (final p in Pais.todos) {
        expect(p.minimo <= p.maximo, isTrue, reason: p.iso);
        expect(p.minimo >= 4 && p.maximo <= 15, isTrue, reason: p.iso);
        expect(p.iso.length, 2, reason: p.iso);
        expect(int.tryParse(p.ddi), isNotNull, reason: p.iso);
        // A bandeira é derivada do ISO: dois indicadores regionais.
        expect(p.bandeira.runes.length, 2, reason: p.iso);
      }
    });

    test('a bandeira sai do ISO', () {
      expect(Pais.padrao.bandeira, '🇧🇷');
      expect(Pais.porIso('PT')!.bandeira, '🇵🇹');
      expect(Pais.porIso('zz'), isNull);
    });
  });

  group('destino mascarado', () {
    test('telefone mostra só os quatro últimos', () {
      // A tela de verificação pode estar sendo vista por outra pessoa, e quatro
      // dígitos bastam para reconhecer o próprio número.
      final mascarado = mascararDestino('+5511987654321');
      expect(mascarado.endsWith('4321'), isTrue);
      expect(mascarado.contains('98765'), isFalse);
    });

    test('e-mail mostra as duas primeiras letras e o domínio', () {
      expect(mascararDestino('caio@example.com'), 'ca••@example.com');
    });
  });

  group('cadastro pendente', () {
    test('o destino vem do servidor, já normalizado', () {
      final p = SignupPending.fromJson({
        'destination': '+5511987654321',
        'channel': 'phone',
        'resend_in_seconds': 60,
        'delivered': true,
      });
      expect(p.destination, '+5511987654321');
      expect(p.porEmail, isFalse);
      expect(p.resendInSeconds, 60);
    });

    test('`delivered` falso é o servidor avisando que ninguém recebeu nada', () {
      // Sem este campo, a pessoa esperaria um SMS que nunca vai chegar e
      // concluiria que o app quebrou.
      final p = SignupPending.fromJson({
        'destination': 'a@b.com',
        'channel': 'email',
        'delivered': false,
      });
      expect(p.delivered, isFalse);
      expect(p.porEmail, isTrue);
    });
  });
}
