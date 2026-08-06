import 'package:flutter_test/flutter_test.dart';
import 'package:deskside_client/l10n/strings.dart';
import 'package:deskside_client/services/word_suggester.dart';

void main() {
  group('sugestões', () {
    test('completa a palavra que está sendo digitada', () {
      final s = WordSuggester(seed: ['computador', 'comprar', 'comida']);
      expect(s.suggest('comp'), contains('computador'));
    });

    test('corrige erro de digitação de uma letra', () {
      final s = WordSuggester(seed: ['arquivo', 'senha', 'projeto']);
      // "arqhivo": o h no lugar do u — o erro de dedo que a barra existe para
      // resolver.
      expect(s.suggest('arqhivo'), contains('arquivo'));
    });

    test('acha a palavra acentuada a partir do que se digita sem acento', () {
      final s = WordSuggester(seed: ['você', 'órgão', 'música']);
      expect(s.suggest('voce'), contains('você'));
      expect(s.suggest('musica'), contains('música'));
    });

    test('não sugere a própria palavra já digitada', () {
      final s = WordSuggester(seed: ['arquivo']);
      expect(s.suggest('arquivo'), isNot(contains('arquivo')));
    });

    test('nada a sugerir devolve lista vazia, e a barra some', () {
      final s = WordSuggester(seed: ['arquivo']);
      expect(s.suggest('xy'), isEmpty);
      expect(s.suggest(''), isEmpty);
      // Um caractere só é ambíguo demais para valer sugestão.
      expect(s.suggest('a'), isEmpty);
    });

    test('não sugere sobre número, símbolo ou caminho', () {
      // Justamente onde uma correção seria desastrosa: caminho e comando.
      final s = WordSuggester(seed: ['arquivo', 'usuario']);
      expect(s.suggest('C:\\Users'), isEmpty);
      expect(s.suggest('123'), isEmpty);
      expect(s.suggest('--force'), isEmpty);
    });

    test('devolve no máximo três', () {
      final s = WordSuggester(
        seed: ['casa', 'casaco', 'casal', 'casamento', 'casario'],
      );
      expect(s.suggest('casa').length, lessThanOrEqualTo(3));
    });

    test('mantém a maiúscula de quem digitou', () {
      final s = WordSuggester(seed: ['projeto']);
      expect(s.suggest('Proj'), contains('Projeto'));
      expect(s.suggest('proj'), contains('projeto'));
    });
  });

  group('aprendizado', () {
    test('palavra usada aparece, mesmo fora do dicionário', () {
      final s = WordSuggester(seed: ['arquivo']);
      expect(s.suggest('remo'), isEmpty);
      s.learn('Deskside');
      expect(s.suggest('remo'), contains('deskside'));
    });

    test('a mais usada vem antes', () {
      final s = WordSuggester();
      s.learn('caderno');
      for (var i = 0; i < 5; i++) {
        s.learn('caminho');
      }
      expect(s.suggest('cam').first, 'caminho');
    });

    test('ignora o que não é palavra', () {
      final s = WordSuggester();
      s.learn('ab'); // curta demais
      s.learn('123');
      s.learn('C:\\Users\\caio');
      expect(s.learned, isEmpty);
    });

    test('o histórico atravessa a troca de idioma', () {
      // O que a pessoa digitou não pertence ao idioma da interface.
      final s = WordSuggester.forLanguage(AppLanguage.ptBr);
      s.learn('deskside');
      final outro = WordSuggester.forLanguage(
        AppLanguage.en,
        learned: s.learned,
      );
      expect(outro.suggest('remo'), contains('deskside'));
    });
  });

  group('palavras comuns por idioma', () {
    test('cada idioma latino traz o seu vocabulário', () {
      expect(
        WordSuggester.forLanguage(AppLanguage.ptBr).suggest('arqu'),
        contains('arquivo'),
      );
      expect(
        WordSuggester.forLanguage(AppLanguage.en).suggest('fol'),
        contains('folder'),
      );
      expect(
        WordSuggester.forLanguage(AppLanguage.es).suggest('carp'),
        contains('carpeta'),
      );
      expect(
        WordSuggester.forLanguage(AppLanguage.fr).suggest('doss'),
        contains('dossier'),
      );
    });

    test('chinês não recebe lista: a escrita não funciona assim', () {
      // Barra vazia é mais honesto que sugerir bobagem.
      final s = WordSuggester.forLanguage(AppLanguage.zh);
      expect(s.suggest('arqu'), isEmpty);
    });
  });
}
