import 'package:flutter_test/flutter_test.dart';
import 'package:in_app_purchase/in_app_purchase.dart';
import 'package:deskside_client/services/compra.dart';

/// As decisões sobre compra, sem loja e sem aparelho.
///
/// Este é o caminho que não dá para testar à toa: cada tentativa de verdade
/// custa conta de sandbox, build pelo TestFlight e um minuto de espera. O que
/// dá para fazer é garantir que a regra não mude sem alguém perceber.
void main() {
  group('acaoPara', () {
    test('comprado e restaurado vão os dois para o servidor', () {
      // Restaurar é revalidar. Um caminho separado para "restaurar" seria uma
      // segunda decisão sobre o mesmo assunto, e um dia as duas discordariam.
      expect(acaoPara(PurchaseStatus.purchased), AcaoDaCompra.validar);
      expect(acaoPara(PurchaseStatus.restored), AcaoDaCompra.validar);
    });

    test('pendente é espera, e não erro', () {
      // Pagamento aguardando aprovação de responsável, ou meio de pagamento
      // que demora. Tratar como falha manda a pessoa tentar de novo e pagar
      // duas vezes.
      expect(acaoPara(PurchaseStatus.pending), AcaoDaCompra.esperar);
    });

    test('cancelar não é erro', () {
      // Quem desistiu não precisa de mensagem vermelha.
      expect(
        acaoPara(PurchaseStatus.canceled),
        AcaoDaCompra.encerrarEmSilencio,
      );
    });

    test('erro avisa', () {
      expect(acaoPara(PurchaseStatus.error), AcaoDaCompra.avisarErro);
    });

    test('todo estado da loja tem decisão', () {
      // O teste que pega o dia em que o plugin ganhar um estado novo: sem
      // isto, o `switch` quebraria a compilação no build e não aqui — ou pior,
      // alguém "consertaria" com um `default` que engole o caso novo.
      for (final status in PurchaseStatus.values) {
        expect(() => acaoPara(status), returnsNormally, reason: '$status');
      }
    });
  });

  group('encerrar junto à loja', () {
    test('quando a loja ainda espera, encerra — em qualquer estado', () {
      // A regra que este arquivo existe para proteger. A loja guarda a
      // transação até o app avisar que entregou; esquecer reentrega a compra a
      // cada abertura, para sempre, e no iOS pode virar estorno automático.
      for (final status in PurchaseStatus.values) {
        final compra = PurchaseDetails(
          productID: produtoPro,
          verificationData: PurchaseVerificationData(
            localVerificationData: 'x',
            serverVerificationData: 'x',
            source: 'app_store',
          ),
          transactionDate: null,
          status: status,
        )..pendingCompletePurchase = true;

        expect(precisaEncerrar(compra), isTrue, reason: '$status');
      }
    });

    test('o que a loja já encerrou não é encerrado de novo', () {
      final compra = PurchaseDetails(
        productID: produtoPro,
        verificationData: PurchaseVerificationData(
          localVerificationData: 'x',
          serverVerificationData: 'x',
          source: 'app_store',
        ),
        transactionDate: null,
        status: PurchaseStatus.purchased,
      )..pendingCompletePurchase = false;

      expect(precisaEncerrar(compra), isFalse);
    });
  });

  group('podeComprar', () {
    test('sem loja, não há o que comprar', () {
      expect(podeComprar(lojaDisponivel: false, produtos: 1), isFalse);
    });

    test('loja no ar e catálogo vazio também não', () {
      // É o caso de um app instalado por sideload: a loja responde, o catálogo
      // vem vazio, e **não há erro nenhum**. Sem esta regra a tela ficaria
      // girando para sempre esperando produtos que nunca chegam.
      expect(podeComprar(lojaDisponivel: true, produtos: 0), isFalse);
    });

    test('loja no ar e produto encontrado', () {
      expect(podeComprar(lojaDisponivel: true, produtos: 1), isTrue);
    });
  });

  test('o identificador do produto é o mesmo dos outros dois lugares', () {
    // Ele vive em três: aqui, na App Store Connect e em `PRODUTOS_PAGOS` no
    // servidor. Os três têm que concordar — se divergirem, a loja cobra e o
    // servidor não libera nada, que é o pior desfecho possível.
    expect(produtoPro, 'com.deskside.pro.mensal');
  });
}
