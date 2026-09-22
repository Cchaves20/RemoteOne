import 'dart:async';

import 'package:flutter/material.dart';
import 'package:in_app_purchase/in_app_purchase.dart';

import '../services/api_client.dart';
import '../services/app_state.dart';
import '../services/compra.dart';
import '../widgets/brand.dart';

/// A tela de assinar o Deskside Pro.
///
/// ## O caminho que o dinheiro faz
///
/// 1. A pessoa toca em Assinar; o app pede a compra **à loja**, não a nós.
/// 2. A loja cobra, e devolve um comprovante assinado por ela.
/// 3. O app manda esse comprovante ao **nosso servidor**.
/// 4. O servidor confere a assinatura criptográfica da Apple e só então
///    libera o plano.
///
/// O app não decide nada nesse caminho, e isso é deliberado: ele roda no
/// aparelho de outra pessoa. O que ele faz é transportar um comprovante que
/// ele próprio não consegue fabricar.
///
/// ## Por que a escuta começa antes da tela
///
/// A loja entrega atualizações de compra a qualquer momento — inclusive de uma
/// compra feita noutro aparelho, ou de uma que ficou pendente e foi aprovada
/// horas depois. Por isso o `listen` é ligado no `initState` e não no toque do
/// botão: uma atualização que chega quando ninguém está ouvindo fica na fila
/// da loja e volta na próxima abertura, e a pessoa vê o plano demorar sem
/// entender por quê.
class AssinaturaScreen extends StatefulWidget {
  const AssinaturaScreen({super.key, required this.state});

  final AppState state;

  @override
  State<AssinaturaScreen> createState() => _AssinaturaScreenState();
}

class _AssinaturaScreenState extends State<AssinaturaScreen> {
  final _loja = InAppPurchase.instance;
  StreamSubscription<List<PurchaseDetails>>? _escuta;

  bool _carregando = true;
  bool _ocupado = false;
  ProductDetails? _produto;
  String? _erro;
  String? _aviso;

  @override
  void initState() {
    super.initState();
    _escuta = _loja.purchaseStream.listen(
      _chegouDaLoja,
      // A loja fechando o fluxo não é erro nosso, mas some com a única fonte
      // de resposta — então a tela precisa parar de prometer que algo vem.
      onError: (e) => _falhar('$e'),
      onDone: () => _escuta?.cancel(),
    );
    _procurarProduto();
  }

  @override
  void dispose() {
    _escuta?.cancel();
    super.dispose();
  }

  Future<void> _procurarProduto() async {
    final disponivel = await _loja.isAvailable();
    var encontrados = <ProductDetails>[];
    if (disponivel) {
      final resposta = await _loja.queryProductDetails({produtoPro});
      encontrados = resposta.productDetails;
    }
    if (!mounted) return;
    setState(() {
      _carregando = false;
      _produto = encontrados.isEmpty ? null : encontrados.first;
      if (!podeComprar(
          lojaDisponivel: disponivel, produtos: encontrados.length)) {
        _erro = widget.state.t.assinaturaIndisponivel;
      }
    });
  }

  Future<void> _comprar() async {
    final produto = _produto;
    if (produto == null || _ocupado) return;
    setState(() {
      _ocupado = true;
      _erro = null;
      _aviso = null;
    });
    try {
      // `buyNonConsumable` também é o certo para assinatura: o que a define é
      // o produto ser renovável na loja, e não o método daqui.
      await _loja.buyNonConsumable(
        purchaseParam: PurchaseParam(productDetails: produto),
      );
    } catch (e) {
      _falhar('$e');
    }
  }

  Future<void> _restaurar() async {
    setState(() {
      _ocupado = true;
      _erro = null;
      _aviso = null;
    });
    try {
      // A Apple exige este caminho, e ele reaparece pelo mesmo fluxo de
      // atualizações — cada compra restaurada chega como `restored`.
      await _loja.restorePurchases();
    } catch (e) {
      _falhar('$e');
    }
  }

  /// Chegou algo da loja. Uma atualização por compra, a qualquer momento.
  Future<void> _chegouDaLoja(List<PurchaseDetails> compras) async {
    for (final compra in compras) {
      switch (acaoPara(compra.status)) {
        case AcaoDaCompra.esperar:
          if (mounted) {
            setState(() {
              _ocupado = true;
              _aviso = widget.state.t.assinaturaVerificando;
            });
          }
        case AcaoDaCompra.validar:
          await _mandarAoServidor(compra);
        case AcaoDaCompra.avisarErro:
          _falhar(compra.error?.message ?? widget.state.t.networkError);
        case AcaoDaCompra.encerrarEmSilencio:
          if (mounted) {
            setState(() {
              _ocupado = false;
              _aviso = widget.state.t.assinaturaCancelada;
            });
          }
      }

      // **Fora do `switch`, e para todas.** A loja guarda a transação até o
      // app avisar que terminou; esquecer reentrega a compra a cada abertura,
      // para sempre, e no iOS pode virar estorno automático. Dentro do
      // `switch`, o ramo que alguém acrescentar amanhã nasceria esquecendo.
      if (precisaEncerrar(compra)) {
        await _loja.completePurchase(compra);
      }
    }
  }

  Future<void> _mandarAoServidor(PurchaseDetails compra) async {
    if (mounted) {
      setState(() {
        _ocupado = true;
        _aviso = widget.state.t.assinaturaVerificando;
      });
    }
    try {
      await widget.state.api.validarCompra(
        loja: 'apple',
        comprovante: compra.verificationData.serverVerificationData,
      );
      // O plano vive no servidor; reler é o que faz o resto do app saber.
      await widget.state.recarregarConta();
      if (!mounted) return;
      setState(() {
        _ocupado = false;
        _erro = null;
        _aviso = widget.state.t.assinaturaPronta;
      });
    } on ApiException catch (e) {
      // A recusa do servidor é a explicação boa: ele diz se o comprovante não
      // vale, se é de outro aplicativo, ou se a loja não está configurada.
      _falhar(e.message);
    } catch (_) {
      _falhar(widget.state.t.networkError);
    }
  }

  void _falhar(String mensagem) {
    if (!mounted) return;
    setState(() {
      _ocupado = false;
      _aviso = null;
      _erro = mensagem;
    });
  }

  @override
  Widget build(BuildContext context) {
    final t = widget.state.t;
    final theme = Theme.of(context);
    final jaAssina = widget.state.conta?.plano == 'pago';

    return Scaffold(
      appBar: AppBar(title: Text(t.assinaturaTitulo)),
      body: AuroraBackground(
        child: SafeArea(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(24),
            child: Center(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 460),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    const SizedBox(height: 8),
                    Text(
                      t.assinaturaChamada,
                      textAlign: TextAlign.center,
                      style: theme.textTheme.titleMedium,
                    ),
                    const SizedBox(height: 24),
                    if (_carregando)
                      const Center(child: CircularProgressIndicator())
                    else if (jaAssina)
                      Text(
                        t.assinaturaJaTem,
                        textAlign: TextAlign.center,
                        style: theme.textTheme.bodyLarge,
                      )
                    else if (_produto != null) ...[
                      // O preço vem **da loja**, e não de um texto nosso: ela
                      // já o traz na moeda e no formato do país de quem olha,
                      // e um valor escrito por nós ficaria errado no dia em
                      // que o preço mudasse — ou em todo país que não o Brasil.
                      Text(
                        _produto!.price,
                        textAlign: TextAlign.center,
                        style: theme.textTheme.headlineMedium,
                      ),
                      const SizedBox(height: 4),
                      Text(
                        t.assinaturaRenova,
                        textAlign: TextAlign.center,
                        style: theme.textTheme.bodySmall,
                      ),
                      const SizedBox(height: 20),
                      FilledButton(
                        key: const Key('assinatura-assinar'),
                        onPressed: _ocupado ? null : _comprar,
                        child: Text(t.assinaturaAssinar),
                      ),
                      TextButton(
                        key: const Key('assinatura-restaurar'),
                        onPressed: _ocupado ? null : _restaurar,
                        child: Text(t.assinaturaRestaurar),
                      ),
                    ],
                    if (_ocupado) ...[
                      const SizedBox(height: 16),
                      const Center(child: CircularProgressIndicator()),
                    ],
                    if (_aviso != null) ...[
                      const SizedBox(height: 14),
                      Text(_aviso!, textAlign: TextAlign.center),
                    ],
                    if (_erro != null) ...[
                      const SizedBox(height: 14),
                      Text(
                        _erro!,
                        textAlign: TextAlign.center,
                        style: TextStyle(color: theme.colorScheme.error),
                      ),
                    ],
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
