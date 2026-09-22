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
