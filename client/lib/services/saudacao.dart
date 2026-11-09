import '../l10n/strings.dart';
import '../models/conta.dart';

/// A frase do topo do início: "Bom dia, Caio", ou "Feliz aniversário, Caio!".
///
/// Pelo relógio **do celular**, e não do servidor: é a hora de quem está
/// olhando para a tela, onde quer que esteja. No idioma escolhido no app.
///
/// - 5h às 11h59: bom dia;
/// - 12h às 17h59: boa tarde;
/// - 18h às 4h59: boa noite (de madrugada ainda é noite para quem está
///   acordado, e "bom dia" às 2h soa estranho).
///
/// No dia do aniversário, o dia inteiro, o parabéns toma o lugar da saudação.
String saudacao(Strings t, Conta? conta, DateTime agora) {
  final nome = conta?.firstName.trim() ?? '';
  if (conta != null && conta.ehAniversarioEm(agora)) {
    return t.felizAniversario(nome);
  }
  final hora = agora.hour;
  if (hora >= 5 && hora < 12) return t.bomDia(nome);
  if (hora >= 12 && hora < 18) return t.boaTarde(nome);
  return t.boaNoite(nome);
}

/// Se a saudação de agora é o parabéns (o início desenha o bolo e o confete).
bool ehAniversario(Conta? conta, DateTime agora) =>
    conta != null && conta.ehAniversarioEm(agora);
