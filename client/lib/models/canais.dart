/// Por quais caminhos o servidor consegue mandar o código de verificação.
///
/// ## O que isto conserta
///
/// O servidor **já dizia** isto no `/health`, desde que o cadastro em duas
/// etapas existe:
///
///     "delivery": {"email": true, "sms": false}
///
/// O app nunca leu. Então ele oferecia "telefone" com a mesma naturalidade que
/// "e-mail", a pessoa preenchia o formulário inteiro, escolhia o país, digitava
/// o número — e só depois de tudo enviado aparecia um aviso vermelho dizendo
/// que o código tinha ido para o registro do servidor, não para ela.
///
/// Um caminho que não funciona não deve ser oferecido. O aviso continua
/// existindo como última rede (o servidor pode perder a credencial entre a
/// pergunta e o envio), mas deixa de ser a primeira notícia.
///
/// ## Ausente significa "não sei", nunca "não"
///
/// A regra que decide o formato: uma chave que falta vale `true`.
///
/// Parece o contrário do seguro, e é o contrário mesmo — de propósito. Se
/// ausente valesse `false`, um servidor mais antigo (que não manda o bloco) ou
/// um `/health` que mudou de forma deixariam o app **sem nenhum caminho de
/// cadastro**, e ninguém conseguiria criar conta. O prejuízo de mostrar um
/// caminho que talvez não funcione é o aviso vermelho de antes; o de esconder
/// os dois é um app que não deixa entrar.
library;

class CanaisDeEntrega {
  const CanaisDeEntrega({required this.email, required this.sms});

  final bool email;
  final bool sms;

  /// Quando não deu para perguntar — servidor fora do ar, rede ruim, resposta
  /// estranha. Assume os dois, que é exatamente o que o app fazia antes: nunca
  /// fica pior do que era.
  static const desconhecido = CanaisDeEntrega(email: true, sms: true);

  /// Lê o corpo do `/health`.
  ///
  /// Tolerante de propósito: o bloco pode faltar, vir vazio, ou trazer algo que
  /// não é booleano. Nenhum desses casos deve derrubar a tela de cadastro.
  factory CanaisDeEntrega.doHealth(Object? corpo) {
    if (corpo is! Map) return desconhecido;
    final bloco = corpo['delivery'];
    if (bloco is! Map) return desconhecido;
    bool ler(String chave) {
      final valor = bloco[chave];
      return valor is bool ? valor : true;
    }

    return CanaisDeEntrega(email: ler('email'), sms: ler('sms'));
  }

  /// Se há escolha a fazer.
  ///
  /// Com um caminho só, o seletor entre e-mail e telefone não deve aparecer:
  /// um botão de duas opções em que uma não serve é pior do que nenhum botão.
  bool get haEscolha => email && sms;

  /// O caminho a usar quando não há escolha.
  ///
  /// `false` = e-mail. Quando os dois estão desligados cai aqui também, e aí o
  /// e-mail é a aposta certa: é o que mais provavelmente foi configurado e
  /// esquecido no `/health`, e é o que não custa dinheiro por mensagem.
  bool get unicoPorTelefone => sms && !email;

  @override
  String toString() => 'CanaisDeEntrega(email: $email, sms: $sms)';
}
