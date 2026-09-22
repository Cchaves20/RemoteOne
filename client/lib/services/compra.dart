/// O que fazer com cada atualização de compra que a loja entrega.
///
/// ## Por que isto é um arquivo separado, e sem widget
///
/// A loja não devolve "comprou / não comprou". Ela devolve um fluxo de
/// atualizações que chegam a qualquer momento — inclusive **antes** de o app
/// abrir a tela de compra, e inclusive de compras feitas noutro aparelho. Cada
/// uma exige uma decisão, e as decisões são regra, não desenho de tela.
///
/// Separando, dá para exercitar cada caso sem StoreKit, sem loja e sem
/// aparelho — o que importa aqui, porque **compra é o caminho que não dá para
/// testar à toa**: cada tentativa de verdade envolve conta de sandbox, build
/// pelo TestFlight e um minuto de espera.
///
/// ## O defeito que este arquivo existe para impedir
///
/// A loja guarda a transação até o app dizer que terminou de entregar o que
/// foi comprado. Esquecer de avisar tem dois efeitos, e os dois são ruins:
///
/// - a mesma compra é reentregue a cada abertura do app, para sempre;
/// - no iOS, a App Store pode considerar que a entrega falhou e **devolver o
///   dinheiro** ao comprador.
///
/// Por isso a regra é "sempre encerrar", e não "encerrar quando deu certo".
/// Compra cancelada encerra. Compra com erro encerra. Compra que o nosso
/// servidor recusou encerra — a loja não tem nada com isso; quem decide o
/// plano é o servidor, e ele já sabe da recusa.
library;

import 'package:in_app_purchase/in_app_purchase.dart';

/// O que o app faz com uma atualização.
enum AcaoDaCompra {
  /// Nada ainda: a loja está processando (aprovação de responsável, boleto,
  /// pagamento que demora). A tela espera, e **não** trata como erro.
  esperar,

  /// Mandar o comprovante ao servidor, que pergunta à loja se é verdadeiro.
  ///
  /// Vale também para `restored`: restaurar é revalidar, e ter dois caminhos
  /// para a mesma decisão é ter duas chances de eles discordarem.
  validar,

  /// A loja falhou. Tem texto para mostrar.
  avisarErro,

  /// A pessoa desistiu. Fecha sem alarde — desistir não é erro, e uma
  /// mensagem vermelha depois de um "cancelar" é o app brigando com quem usa.
  encerrarEmSilencio,
}

/// A decisão para uma atualização da loja.
AcaoDaCompra acaoPara(PurchaseStatus status) => switch (status) {
      PurchaseStatus.pending => AcaoDaCompra.esperar,
      PurchaseStatus.purchased => AcaoDaCompra.validar,
      PurchaseStatus.restored => AcaoDaCompra.validar,
      PurchaseStatus.error => AcaoDaCompra.avisarErro,
      PurchaseStatus.canceled => AcaoDaCompra.encerrarEmSilencio,
    };

/// Se esta atualização ainda precisa ser encerrada junto à loja.
///
/// Uma função de uma linha, e ela existe por um motivo: o `switch` acima
/// convida a pendurar o encerramento em cada ramo, e aí o ramo que alguém
/// acrescentar amanhã nasce esquecendo. Aqui a pergunta é feita **fora** da
/// decisão, para todas as atualizações, sempre.
bool precisaEncerrar(PurchaseDetails compra) => compra.pendingCompletePurchase;

/// O produto que este app vende.
///
/// Precisa ser igual, caractere por caractere, ao identificador cadastrado na
/// App Store Connect **e** ao que o servidor reconhece em `PRODUTOS_PAGOS`
/// (`backend/app/assinatura.py`). São três lugares, e os três têm que
/// concordar: se divergirem, a loja cobra e o servidor não libera nada.
const produtoPro = 'com.deskside.pro.mensal';

/// Se vale a pena oferecer a compra.
///
/// Loja indisponível e catálogo vazio são coisas diferentes para quem
/// programa, e a mesma para quem usa: não há o que comprar. O que muda é o
/// texto, e por isso os dois casos chegam aqui separados.
bool podeComprar({required bool lojaDisponivel, required int produtos}) =>
    lojaDisponivel && produtos > 0;

/// Em que situação a conta está em relação ao Pro.
///
/// Quatro, e não duas, porque `plano == 'pago'` sozinho abrange coisas que
/// precisam de telas diferentes.
enum SituacaoDoPlano {
  /// No grátis. O caso mais simples: oferecer a compra.
  gratis,

  /// **Nos 30 dias iniciais.** Toda conta nasce paga e cai para o grátis
  /// depois (`backend/app/plano.py`), então durante um mês inteiro o plano
  /// efetivo é `pago` sem ninguém ter comprado nada.
  ///
  /// É o caso que uma leitura ingênua de `plano == 'pago'` esconde — e ele
  /// esconde justamente **quem está mais perto de assinar**: alguém que já
  /// usou o produto inteiro e está a poucos dias de perdê-lo.
  teste,

  /// Já assina pela loja. Não há o que vender de novo.
  assinante,

  /// Liberada à mão, sem prazo. A conta do dono do produto, e as cortesias
  /// dadas por `python -m app.conta pago <email>`.
  semPrazo,
}

/// A situação, a partir do que o servidor respondeu em `GET /api/v1/assinatura`.
///
/// A distinção entre teste e assinatura vem de `loja`: ela só tem valor quando
/// existe uma compra registrada. Deduzir pela data não daria — teste e
/// assinatura mensal têm os dois um prazo de trinta dias, e são indistinguíveis
/// pelo calendário.
SituacaoDoPlano situacaoDoPlano({
  required String plano,
  required String? loja,
  required String? expiraEm,
}) {
  if (plano != 'pago') return SituacaoDoPlano.gratis;
  if (loja != null && loja.isNotEmpty) return SituacaoDoPlano.assinante;
  if (expiraEm == null || expiraEm.isEmpty) return SituacaoDoPlano.semPrazo;
  return SituacaoDoPlano.teste;
}

/// A mesma situação, a partir do que `GET /api/v1/auth/me` devolve.
///
/// Duas portas de entrada para a mesma decisão, e **uma decisão só**. As duas
/// existem porque as duas respostas do servidor carregam a informação de
/// formas diferentes — uma traz `loja`, a outra traz `em_teste` já mastigado —
/// e obrigar a tela de ajustes a pedir a assinatura inteira só para desenhar
/// um botão seria uma chamada de rede por cartão exibido.
///
/// O que **não** pode existir é uma segunda regra. Uma tela que ofereça
/// assinar e outra que não, para a mesma conta, é pior do que as duas erradas
/// do mesmo jeito: quem usa conclui que o app está quebrado.
SituacaoDoPlano situacaoDaConta({
  required String plano,
  required bool emTeste,
  required DateTime? planoAte,
}) {
  if (plano != 'pago') return SituacaoDoPlano.gratis;
  if (emTeste) return SituacaoDoPlano.teste;
  if (planoAte == null) return SituacaoDoPlano.semPrazo;
  return SituacaoDoPlano.assinante;
}

/// Quantos dias inteiros faltam até a data que o servidor mandou.
///
/// Devolve `null` quando a data não dá para ler — e não zero. Zero é "acaba
/// hoje", uma frase urgente; mostrá-la por causa de um texto malformado seria
/// assustar sem motivo.
///
/// Arredonda para cima por um motivo prático: faltando 30 horas, "faltam 2
/// dias" é mais fiel ao que a pessoa vai viver do que "falta 1 dia", e o
/// contrário faria a contagem pular de 1 para "acaba hoje" com um dia inteiro
/// ainda pela frente.
int? diasAte(String iso, {DateTime? agora}) {
  final quando = DateTime.tryParse(iso);
  if (quando == null) return null;
  final daqui = quando.toUtc().difference((agora ?? DateTime.now()).toUtc());
  if (daqui.isNegative) return 0;
  return (daqui.inMinutes / (60 * 24)).ceil();
}

/// Se a tela deve mostrar o botão de assinar.
///
/// Quem está no teste **precisa** poder assinar antes de o teste acabar; a
/// alternativa é pedir que a pessoa espere perder o produto para poder pagar.
bool ofereceAssinar(SituacaoDoPlano situacao) =>
    situacao == SituacaoDoPlano.gratis || situacao == SituacaoDoPlano.teste;
