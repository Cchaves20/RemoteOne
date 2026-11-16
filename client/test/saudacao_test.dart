import 'package:deskside_client/l10n/strings.dart';
import 'package:deskside_client/models/conta.dart';
import 'package:deskside_client/services/saudacao.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const pt = Strings(AppLanguage.ptBr);
  const caio = Conta(id: 1, firstName: 'Caio', aniversario: '04-20');

  test('a saudação segue o relógio do celular', () {
    expect(saudacao(pt, caio, DateTime(2026, 11, 9, 5)), 'Bom dia, Caio');
    expect(saudacao(pt, caio, DateTime(2026, 11, 9, 11, 59)), 'Bom dia, Caio');
    expect(saudacao(pt, caio, DateTime(2026, 11, 9, 12)), 'Boa tarde, Caio');
    expect(saudacao(pt, caio, DateTime(2026, 11, 9, 17, 59)), 'Boa tarde, Caio');
    expect(saudacao(pt, caio, DateTime(2026, 11, 9, 18)), 'Boa noite, Caio');
    expect(saudacao(pt, caio, DateTime(2026, 11, 9, 2)), 'Boa noite, Caio');
    expect(saudacao(pt, caio, DateTime(2026, 11, 9, 4, 59)), 'Boa noite, Caio');
  });

  test('no aniversário, o dia inteiro, é parabéns', () {
    expect(saudacao(pt, caio, DateTime(2026, 4, 20, 0, 5)), 'Feliz aniversário, Caio!');
    expect(saudacao(pt, caio, DateTime(2026, 4, 20, 23, 59)), 'Feliz aniversário, Caio!');
    expect(saudacao(pt, caio, DateTime(2026, 4, 21, 9)), 'Bom dia, Caio');
    expect(ehAniversario(caio, DateTime(2026, 4, 20)), isTrue);
  });

  test('cada idioma tem a sua frase', () {
    final noite = DateTime(2026, 11, 9, 21);
    final festa = DateTime(2026, 4, 20, 10);
    expect(saudacao(const Strings(AppLanguage.en), caio, noite), 'Good evening, Caio');
    expect(saudacao(const Strings(AppLanguage.es), caio, noite), 'Buenas noches, Caio');
    expect(saudacao(const Strings(AppLanguage.fr), caio, noite), 'Bonsoir, Caio');
    expect(saudacao(const Strings(AppLanguage.zh), caio, noite), '晚上好，Caio');
    expect(saudacao(const Strings(AppLanguage.en), caio, festa), 'Happy birthday, Caio!');
    expect(saudacao(const Strings(AppLanguage.es), caio, festa), '¡Feliz cumpleaños, Caio!');
  });

  test('29 de fevereiro faz aniversário no dia 28 dos anos comuns', () {
    const bissexto = Conta(id: 2, firstName: 'Ana', aniversario: '02-29');
    expect(bissexto.ehAniversarioEm(DateTime(2027, 2, 28)), isTrue);
    expect(bissexto.ehAniversarioEm(DateTime(2027, 3, 1)), isFalse);
    expect(bissexto.ehAniversarioEm(DateTime(2028, 2, 28)), isFalse);
    expect(bissexto.ehAniversarioEm(DateTime(2028, 2, 29)), isTrue);
  });

  test('sem nome, sem aniversário ou com o campo torto, só o horário', () {
    expect(saudacao(pt, const Conta(id: 3), DateTime(2026, 1, 1, 8)), 'Bom dia');
    expect(saudacao(pt, null, DateTime(2026, 1, 1, 15)), 'Boa tarde');
    const torto = Conta(id: 4, firstName: 'Bia', aniversario: '2026-04-20');
    expect(saudacao(pt, torto, DateTime(2026, 4, 20, 8)), 'Bom dia, Bia');
  });

  test('o aniversário vem do /me', () {
    final c = Conta.fromJson({'id': 1, 'first_name': 'Caio', 'aniversario': '04-20'});
    expect(c.mesEDia, (4, 20));
    expect(Conta.fromJson({'id': 1}).aniversario, isNull);
  });
}
