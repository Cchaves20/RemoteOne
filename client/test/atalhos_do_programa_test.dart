import 'package:deskside_client/l10n/strings.dart';
import 'package:deskside_client/models/atalhos_do_programa.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const t = Strings(AppLanguage.ptBr);

  test('cada programa tem os seus atalhos', () {
    expect(atalhosPara(t, 'code.exe').first.combinacao, 'Ctrl S');
    expect(atalhosPara(t, 'chrome.exe').first.rotulo, 'Nova aba');
    expect(atalhosPara(t, 'msedge.exe').last.combinacao, 'Alt ←');
    expect(atalhosPara(t, 'explorer.exe').first.combinacao, 'F2');
    expect(atalhosPara(t, 'explorer.exe')[1].combinacao, 'Ctrl Shift N');
  });

  test('programa desconhecido fica com os de sempre', () {
    final a = atalhosPara(t, 'qualquer.exe');
    expect(a.map((x) => x.rotulo), ['Copiar', 'Colar', 'Desfazer', 'Selecionar tudo']);
    expect(atalhosPara(t, null), hasLength(4));
  });

  test('no Mac, Ctrl vira Command', () {
    expect(atalhosPara(t, 'code', mac: true).first.modificadores, ['meta']);
    expect(atalhosPara(t, 'code', mac: true).first.combinacao, '⌘ S');
  });

  test('nome curto para o rótulo da linha', () {
    expect(nomeCurtoDoPrograma('code.exe'), 'VS Code');
    expect(nomeCurtoDoPrograma('notepad.exe'), isNull);
  });
}
