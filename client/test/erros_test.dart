import 'dart:convert';

import 'package:deskside_client/l10n/strings.dart';
import 'package:deskside_client/services/erros.dart';
import 'package:flutter_test/flutter_test.dart';

/// A tradução do corpo de erro do servidor.
///
/// O teste que dá razão a este arquivo é o primeiro: o despejo que apareceu de
/// verdade numa tela, palavra por palavra.
void main() {
  const pt = Strings(AppLanguage.ptBr);
  const en = Strings(AppLanguage.en);

  group('o 422 que apareceu na tela', () {
    test('o passo que o servidor não conhecia vira o diagnóstico certo', () {
      // O corpo real: o app mandou um passo `close_all` para um servidor que
      // ainda não tinha esse valor no `Literal`. Antes, isto ia inteiro para o
      // aviso vermelho — e a causa (servidor desatualizado) ficava escondida no
      // meio do despejo.
      final corpo = jsonDecode('''
        {"detail": [{
          "type": "literal_error",
          "loc": ["body", "steps", 0, "kind"],
          "msg": "Input should be 'launch', 'close', 'input', 'media', 'brightness' or 'power'",
          "input": "close_all",
          "ctx": {"expected": "'launch', 'close', 'input', 'media', 'brightness' or 'power'"}
        }]}
      ''') as Map<String, dynamic>;

      final frase = traduzirErro(422, corpo['detail'], pt);

      expect(frase, contains('desatualizado'));
      expect(frase, contains('kind'));
      // E nada do despejo sobrou.
      expect(frase, isNot(contains('literal_error')));
      expect(frase, isNot(contains('loc')));
      expect(frase, isNot(contains('ctx')));
    });
  });

  group('os tipos de erro do Pydantic', () {
    String traduz(String tipo, {List<Object>? loc, String msg = ''}) =>
        traduzirErro(422, [
          {'type': tipo, 'loc': loc ?? ['body', 'email'], 'msg': msg}
        ], pt);

    test('campo que falta é nomeado', () {
      expect(traduz('missing'), contains('e-mail'));
      expect(traduz('missing'), contains('Falta'));
    });

    test('curto, longo e fora do intervalo têm frases próprias', () {
      expect(traduz('string_too_short'), contains('curto'));
      expect(traduz('string_too_long'), contains('longo'));
      expect(traduz('greater_than_equal'), contains('fora'));
    });

    test('tipo desconhecido guarda a mensagem do servidor', () {
      // A mensagem é técnica e em inglês, e é a única pista que resta. Escondê-la
      // deixaria a investigação sem nada.
      final frase = traduz('uuid_parsing', msg: 'Input should be a valid UUID');
      expect(frase, contains('e-mail'));
      expect(frase, contains('valid UUID'));
    });

    test('sem `loc` reconhecível, ainda sai uma frase', () {
      // Um `loc` só com "body" acontece nos validadores de modelo inteiro.
      final frase = traduz('missing', loc: ['body']);
      expect(frase, contains('um dos campos'));
    });
  });

  group('as regras que nós mesmos escrevemos', () {
    test('a frase do validador passa direto, sem o prefixo do Pydantic', () {
      // "Value error, " não interessa a ninguém, e a frase depois dele é a que
      // resolve o problema — trocá-la por "dados inválidos" apagaria a única
      // informação útil da resposta.
      final frase = traduzirErro(422, [
        {
          'type': 'value_error',
          'loc': ['body'],
          'msg': 'Value error, agendamento precisa de um computador escolhido',
        }
      ], pt);
      expect(frase, 'agendamento precisa de um computador escolhido');
    });
  });

  group('o resto das respostas', () {
    test('`detail` de texto já é uma frase e não se mexe', () {
      // É assim que vêm os erros que o servidor levanta de propósito.
      expect(traduzirErro(503, 'agente offline', pt), 'agente offline');
    });

    test('sem `detail` sobra o código, e ele aparece', () {
      final frase = traduzirErro(500, null, pt);
      expect(frase, contains('500'));
    });

    test('`detail` vazio não vira frase vazia', () {
      // Uma mensagem em branco é pior que "erro 400": o aviso aparece sem nada
      // escrito, e parece defeito do app.
      expect(traduzirErro(400, '  ', pt), contains('400'));
      expect(traduzirErro(400, const [], pt), contains('400'));
    });

    test('o idioma vem de quem chama', () {
      final frase = traduzirErro(422, [
        {'type': 'missing', 'loc': ['body', 'password'], 'msg': ''}
      ], en);
      expect(frase, contains('Missing'));
    });
  });

  test('dois campos errados dão duas frases', () {
    // O cadastro pode errar dois campos de uma vez. Mostrar só o primeiro faria
    // a pessoa corrigir, tentar de novo e receber o segundo — parecendo que o
    // app inventa exigências a cada tentativa.
    final frase = traduzirErro(422, [
      {'type': 'missing', 'loc': ['body', 'email'], 'msg': ''},
      {'type': 'missing', 'loc': ['body', 'password'], 'msg': ''},
    ], pt);
    expect(frase.split('\n').length, 2);
    expect(frase, contains('e-mail'));
    expect(frase, contains('senha'));
  });
}
