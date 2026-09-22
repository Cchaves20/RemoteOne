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

  group('qual loja', () {
    test('compra do Google vai ao servidor como google', () {
      // O defeito que isto conserta mandava `'apple'` fixo: o servidor
      // tentaria conferir uma assinatura JWS da Apple num token do Google e
      // recusaria. O Google cobrando e o plano não liberando é o pior
      // desfecho possível neste caminho.
      expect(lojaDoComprovante('google_play'), LojaDoApp.google);
      expect(lojaDoComprovante('google_play').valor, 'google');
    });

    test('compra da App Store vai como apple', () {
      expect(lojaDoComprovante('app_store'), LojaDoApp.apple);
      expect(lojaDoComprovante('app_store').valor, 'apple');
    });

    test('origem desconhecida não vira google por engano', () {
      // Cair em `apple` é deliberado: é a única loja que o servidor sabe
      // verificar hoje, e uma recusa explicada vale mais que um nome
      // inventado que ninguém reconhece do outro lado.
      expect(lojaDoComprovante(''), LojaDoApp.apple);
      expect(lojaDoComprovante('alguma_loja_nova'), LojaDoApp.apple);
    });

    test('os nomes são exatamente os que o servidor aceita', () {
      // `ValidarIn.loja` é o enum `Loja` do backend: "apple" ou "google".
      // Qualquer outra grafia vira 422 antes de chegar à verificação.
      expect(LojaDoApp.values.map((l) => l.valor).toSet(), {'apple', 'google'});
    });

    test('o texto da tela segue a plataforma, não o comprovante', () {
      // Antes de existir compra não há comprovante nenhum, e a tela precisa
      // dizer "instale pela Play Store" a quem está no Android mesmo assim.
      expect(lojaDaPlataforma(true), LojaDoApp.google);
      expect(lojaDaPlataforma(false), LojaDoApp.apple);
    });
  });

  group('situacaoDoPlano', () {
    test('quem está nos 30 dias iniciais ainda pode assinar', () {
      // O caso que uma leitura ingênua de `plano == "pago"` esconde. Toda conta
      // nasce paga por 30 dias sem ter comprado nada: tratar isso como
      // "já assina" tira o botão de assinar justamente de quem está mais perto
      // de pagar, e devolve o botão só depois que o produto foi perdido.
      final s = situacaoDoPlano(
        plano: 'pago',
        loja: null,
        expiraEm: '2026-11-21T12:00:00Z',
      );
      expect(s, SituacaoDoPlano.teste);
      expect(ofereceAssinar(s), isTrue);
    });

    test('quem já assina pela loja não vê o botão', () {
      final s = situacaoDoPlano(
        plano: 'pago',
        loja: 'apple',
        expiraEm: '2026-11-21T12:00:00Z',
      );
      expect(s, SituacaoDoPlano.assinante);
      expect(ofereceAssinar(s), isFalse);
    });

    test('a conta sem prazo é reconhecida, e não confundida com teste', () {
      // A cortesia dada à mão: plano pago e nenhuma data. Confundi-la com o
      // teste faria a tela oferecer uma assinatura a quem já tem tudo para
      // sempre — e, se a pessoa comprasse, o prazo infinito viraria mensal.
      final s = situacaoDoPlano(plano: 'pago', loja: null, expiraEm: null);
      expect(s, SituacaoDoPlano.semPrazo);
      expect(ofereceAssinar(s), isFalse);
    });

    test('no grátis, o botão aparece', () {
      final s = situacaoDoPlano(plano: 'gratis', loja: null, expiraEm: null);
      expect(s, SituacaoDoPlano.gratis);
      expect(ofereceAssinar(s), isTrue);
    });

    test('string vazia conta como ausente', () {
      // O servidor manda `null`, mas um JSON que perde o tipo pelo caminho
      // manda `""`. Tratar os dois igual evita uma conta sem prazo virar
      // "teste" por causa de uma serialização.
      expect(
        situacaoDoPlano(plano: 'pago', loja: '', expiraEm: ''),
        SituacaoDoPlano.semPrazo,
      );
    });

    test('toda situação tem decisão sobre mostrar o botão', () {
      for (final s in SituacaoDoPlano.values) {
        expect(() => ofereceAssinar(s), returnsNormally, reason: '$s');
      }
    });
  });

  group('situacaoDaConta', () {
    final prazo = DateTime.now().add(const Duration(days: 20));

    test('as duas portas de entrada dão a mesma resposta', () {
      // O teste que existe para o dia em que alguém mexer numa e esquecer a
      // outra. Uma tela oferecendo assinar e outra não, para a mesma conta, é
      // pior do que as duas erradas igual: quem usa conclui que está quebrado.
      void concordam(String nome, SituacaoDoPlano daConta,
          SituacaoDoPlano daAssinatura) {
        expect(daConta, daAssinatura, reason: nome);
        expect(ofereceAssinar(daConta), ofereceAssinar(daAssinatura),
            reason: nome);
      }

      concordam(
        'grátis',
        situacaoDaConta(plano: 'gratis', emTeste: false, planoAte: null),
        situacaoDoPlano(plano: 'gratis', loja: null, expiraEm: null),
      );
      concordam(
        'teste',
        situacaoDaConta(plano: 'pago', emTeste: true, planoAte: prazo),
        situacaoDoPlano(
            plano: 'pago', loja: null, expiraEm: prazo.toIso8601String()),
      );
      concordam(
        'assinante',
        situacaoDaConta(plano: 'pago', emTeste: false, planoAte: prazo),
        situacaoDoPlano(
            plano: 'pago', loja: 'apple', expiraEm: prazo.toIso8601String()),
      );
      concordam(
        'sem prazo',
        situacaoDaConta(plano: 'pago', emTeste: false, planoAte: null),
        situacaoDoPlano(plano: 'pago', loja: null, expiraEm: null),
      );
    });

    test('o botão aparece no grátis e no teste, e só neles', () {
      expect(
        ofereceAssinar(
            situacaoDaConta(plano: 'gratis', emTeste: false, planoAte: null)),
        isTrue,
      );
      expect(
        ofereceAssinar(
            situacaoDaConta(plano: 'pago', emTeste: true, planoAte: prazo)),
        isTrue,
      );
      expect(
        ofereceAssinar(
            situacaoDaConta(plano: 'pago', emTeste: false, planoAte: prazo)),
        isFalse,
      );
      expect(
        ofereceAssinar(
            situacaoDaConta(plano: 'pago', emTeste: false, planoAte: null)),
        isFalse,
      );
    });

    test('em teste vence o prazo nulo', () {
      // Combinação que o servidor não manda, mas que um `em_teste` ligado por
      // engano produziria. Cair em "teste" mostra o botão, que é o erro
      // barato; cair em "sem prazo" o esconderia de quem talvez precise.
      expect(
        situacaoDaConta(plano: 'pago', emTeste: true, planoAte: null),
        SituacaoDoPlano.teste,
      );
    });
  });

  group('diasAte', () {
    final agora = DateTime.utc(2026, 9, 22, 12, 0);

    test('conta os dias que faltam', () {
      expect(diasAte('2026-10-22T12:00:00Z', agora: agora), 30);
      expect(diasAte('2026-09-23T12:00:00Z', agora: agora), 1);
    });

    test('arredonda para cima', () {
      // Faltando 30 horas, "faltam 2 dias" descreve melhor o que a pessoa vai
      // viver; arredondar para baixo faria a contagem pular de 1 para "acaba
      // hoje" com um dia inteiro ainda pela frente.
      expect(diasAte('2026-09-23T18:00:00Z', agora: agora), 2);
    });

    test('data já passada é zero, e não negativo', () {
      expect(diasAte('2026-09-01T12:00:00Z', agora: agora), 0);
    });

    test('faltando horas, ainda é "1 dia"; faltando segundos, é "hoje"', () {
      // O limite entre as duas frases. Cinco horas viram um dia porque
      // "acaba hoje" com cinco horas pela frente é alarme; meio minuto é
      // "acaba hoje" de verdade.
      expect(diasAte('2026-09-22T17:00:00Z', agora: agora), 1);
      expect(diasAte('2026-09-22T12:00:30Z', agora: agora), 0);
    });

    test('texto que não é data devolve nulo, e não zero', () {
      // Zero é "acaba hoje", uma frase urgente. Mostrá-la por causa de um
      // campo malformado seria assustar quem tem 29 dias pela frente.
      expect(diasAte('', agora: agora), isNull);
      expect(diasAte('amanhã', agora: agora), isNull);
    });

    test('fuso não muda a conta', () {
      // O servidor manda ISO com deslocamento; comparar sem normalizar para
      // UTC erraria por horas, e perto do limite erraria o dia.
      expect(diasAte('2026-09-23T09:00:00-03:00', agora: agora), 1);
    });
  });

  test('o identificador do produto é o mesmo dos outros dois lugares', () {
    // Ele vive em três: aqui, na App Store Connect e em `PRODUTOS_PAGOS` no
    // servidor. Os três têm que concordar — se divergirem, a loja cobra e o
    // servidor não libera nada, que é o pior desfecho possível.
    expect(produtoPro, 'com.deskside.pro.mensal');
  });
}
