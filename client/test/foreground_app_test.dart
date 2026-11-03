import 'package:deskside_client/l10n/strings.dart';
import 'package:deskside_client/models/foreground_app.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('ForegroundApp.hidden', () {
    test('app de banco que se esconde da captura chega marcado', () {
      final app = ForegroundApp.fromJson({
        'app': {'name': 'Itaú', 'exe': 'itau.exe', 'hidden': true},
      })!;
      expect(app.hidden, isTrue);
      expect(app.name, 'Itaú');
    });

    test('agente antigo, sem o campo, vale como visível', () {
      final app = ForegroundApp.fromJson({
        'app': {'name': 'Bloco de Notas', 'exe': 'notepad.exe'},
      })!;
      expect(app.hidden, isFalse);
    });

    test('valor estranho no campo não liga o aviso', () {
      final app = ForegroundApp.fromJson({
        'app': {'exe': 'x.exe', 'hidden': 'sim'},
      })!;
      expect(app.hidden, isFalse);
    });
  });

  test('o aviso diz o nome do programa em todos os idiomas', () {
    for (final lang in AppLanguage.values) {
      final texto = Strings(lang).hiddenWindowWarning('Itaú');
      expect(texto, contains('Itaú'), reason: '$lang');
    }
  });
}
