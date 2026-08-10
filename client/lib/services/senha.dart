import '../l10n/strings.dart';

/// As cinco regras da senha, do lado do app.
///
/// **A mesma política existe no servidor** (`backend/app/senha.py`), e as duas
/// cópias têm papéis diferentes: a do servidor é a que **decide** (o app pode
/// estar velho, ou ter sido adulterado), a daqui é a que **explica** — porque a
/// pessoa precisa ver o que falta enquanto digita. Mandar ao servidor para
/// descobrir que faltava um número seria uma viagem para dizer o óbvio.
///
/// Se as duas divergirem, o servidor recusa e a tela mostra o motivo que veio
/// de lá.
enum RegraDeSenha {
  tamanho,
  maiuscula,
  minuscula,
  numero,
  especial;

  /// Se esta regra já está cumprida.
  bool cumprida(String senha) {
    switch (this) {
      case RegraDeSenha.tamanho:
        return senha.length >= tamanhoMinimo;
      // Por comparação de caixa, e não por faixa de caracteres. Uma faixa como
      // `[A-ZÀ-Þ]` parece certa e engole o `×` (que mora no meio dela), além de
      // deixar de fora tudo que não é latino. Isto aqui pergunta o que
      // interessa — "existe alguma letra que muda ao virar minúscula?" — e
      // combina exatamente com o `isupper()` do servidor, que é Unicode.
      case RegraDeSenha.maiuscula:
        return senha.toLowerCase() != senha;
      case RegraDeSenha.minuscula:
        return senha.toUpperCase() != senha;
      case RegraDeSenha.numero:
        return senha.contains(RegExp(r'[0-9]'));
      case RegraDeSenha.especial:
        // Por exclusão, e não por uma lista de símbolos: evita a pergunta "o
        // `ç` conta?" e aceita o que qualquer teclado do mundo produz.
        return senha.contains(RegExp(r'[^A-Za-z0-9]'));
    }
  }

  String rotulo(Strings t) {
    switch (this) {
      case RegraDeSenha.tamanho:
        return t.regraTamanho(tamanhoMinimo);
      case RegraDeSenha.maiuscula:
        return t.regraMaiuscula;
      case RegraDeSenha.minuscula:
        return t.regraMinuscula;
      case RegraDeSenha.numero:
        return t.regraNumero;
      case RegraDeSenha.especial:
        return t.regraEspecial;
    }
  }
}

const int tamanhoMinimo = 8;

/// O teto do bcrypt, contado em **bytes**. Uma senha maior seria truncada em
/// silêncio no servidor, e duas senhas diferentes passariam a abrir a mesma
/// conta. Aqui só serve para o campo avisar antes.
const int tamanhoMaximoBytes = 72;

/// Se a senha cumpre as cinco.
bool senhaValida(String senha) =>
    RegraDeSenha.values.every((r) => r.cumprida(senha));

/// Quantas regras faltam — para a barrinha de força da tela.
int regrasCumpridas(String senha) =>
    RegraDeSenha.values.where((r) => r.cumprida(senha)).length;
