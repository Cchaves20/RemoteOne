import 'dart:async';

import 'package:flutter/material.dart';
import 'package:in_app_purchase/in_app_purchase.dart';
import 'package:url_launcher/url_launcher.dart';

import '../config.dart';
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

  /// A situação do plano, **segundo o servidor**.
  ///
  /// Não sai de `conta.plano`: durante os 30 dias iniciais esse campo vale
  /// `pago` sem ninguém ter comprado nada, e usá-lo aqui esconderia o botão de
  /// assinar justamente de quem está mais perto de assinar.
  SituacaoDoPlano _situacao = SituacaoDoPlano.gratis;

  /// Quantos dias faltam do teste. Nulo fora do teste.
  int? _diasDeTeste;

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
    final situacao = await _perguntarAoServidor();

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
      // Quem já assina ou tem a conta sem prazo não precisa saber que o
      // catálogo da loja veio vazio: não há nada que essa pessoa queira
      // comprar, e o aviso só assustaria.
      if (ofereceAssinar(situacao) &&
          !podeComprar(
              lojaDisponivel: disponivel, produtos: encontrados.length)) {
        _erro = widget.state.t.assinaturaIndisponivel;
      }
    });
  }

  /// Pergunta ao servidor em que situação a conta está.
  ///
  /// Uma chamada a mais, de propósito. O `conta.plano` que o app já tem não
  /// distingue teste de assinatura — os dois chegam como `pago` — e essa
  /// distinção é a que decide se existe algo para vender nesta tela.
  ///
  /// Falhar aqui não pode fechar a tela: sem rede, o certo é oferecer a compra
  /// (o pior caso é a loja recusar uma compra repetida, e ela sabe fazer isso)
  /// em vez de esconder o botão e deixar a pessoa sem caminho nenhum.
  Future<SituacaoDoPlano> _perguntarAoServidor() async {
    var situacao = SituacaoDoPlano.gratis;
    int? dias;
    try {
      final resposta = await widget.state.api.minhaAssinatura();
      final expiraEm = resposta['expira_em'] as String?;
      situacao = situacaoDoPlano(
        plano: '${resposta['plano'] ?? 'gratis'}',
        loja: resposta['loja'] as String?,
        expiraEm: expiraEm,
      );
      if (situacao == SituacaoDoPlano.teste && expiraEm != null) {
        dias = diasAte(expiraEm);
      }
    } catch (_) {
      // Segue como `gratis`: a tela oferece a compra, que é o caminho que não
      // deixa ninguém preso.
    }
    if (mounted) {
      setState(() {
        _situacao = situacao;
        _diasDeTeste = dias;
      });
    }
    return situacao;
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

  /// Quantas atualizações chegaram desde o último toque em Restaurar.
  ///
  /// Existe por um motivo só, e ele é o defeito descrito em `_restaurar`.
  int _chegaramDesdeORestaurar = 0;

  /// Quanto esperar pelo fluxo depois que o `restorePurchases` retorna.
  ///
  /// Um número escolhido, e vale dizer por quê: o `in_app_purchase` **não**
  /// avisa "terminei de restaurar, foram N". O `await` volta quando o pedido
  /// foi feito, e as compras (se houver) chegam depois, pelo `purchaseStream`.
  /// Não há sinal melhor disponível na API.
  ///
  /// Três segundos erram para o lado certo dos dois jeitos: se a compra
  /// demorar mais, ela ainda chega e a tela se corrige sozinha — o aviso de
  /// "nada a restaurar" é substituído pelo plano liberado; e se não houver
  /// nada, a pessoa espera três segundos em vez de para sempre.
  static const _esperaDoRestaurar = Duration(seconds: 3);

  Future<void> _restaurar() async {
    _chegaramDesdeORestaurar = 0;
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
      return;
    }

    // O defeito que estas linhas existem para impedir:
    //
    // quem **não tem** nada a restaurar — que é a maioria de quem toca no
    // botão por curiosidade, e todo testador que ainda não comprou — não
    // recebe atualização nenhuma. A loja simplesmente não fala. Sem isto, o
    // `_ocupado` fica ligado para sempre: roda-roda girando, os dois botões
    // desabilitados, e nenhuma explicação. A tela não trava por erro; ela
    // trava por sucesso silencioso, que é a pior forma de travar porque não
    // deixa nada no log para alguém investigar depois.
    await Future<void>.delayed(_esperaDoRestaurar);
    if (!mounted || _chegaramDesdeORestaurar > 0) return;
    setState(() {
      _ocupado = false;
      _aviso = widget.state.t.assinaturaNadaARestaurar;
    });
  }

  /// Chegou algo da loja. Uma atualização por compra, a qualquer momento.
  Future<void> _chegouDaLoja(List<PurchaseDetails> compras) async {
    // Contado **antes** do laço e para toda atualização, não só as restauradas:
    // se a loja falou, ela não ficou em silêncio, e é o silêncio que o aviso de
    // "nada a restaurar" descreve. Contar só `restored` faria a mensagem
    // aparecer por cima de um erro que a loja acabou de explicar.
    _chegaramDesdeORestaurar += compras.length;

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
      // E reler **esta** tela também, senão o botão de assinar continua ali
      // depois da compra, convidando a comprar de novo o que já foi comprado.
      await _perguntarAoServidor();
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

  /// Abre um dos dois documentos no navegador.
  ///
  /// `externalApplication` e não a visualização de dentro do app: a Apple pede
  /// que os documentos estejam **acessíveis**, e o navegador do sistema é o
  /// que tem voltar, compartilhar e aumentar a letra. Uma janela embutida que
  /// falha ao carregar deixa a pessoa presa numa tela branca.
  Future<void> _abrir(String caminho) async {
    final endereco = Uri.parse('https://$siteDeskside$caminho');
    var abriu = false;
    try {
      abriu = await launchUrl(endereco, mode: LaunchMode.externalApplication);
    } catch (_) {
      abriu = false;
    }
    // O `launchUrl` devolve `false` em vez de lançar quando não há navegador,
    // então checar só o `try` deixaria o toque sem resposta — que é como um
    // app parece quebrado sem estar.
    if (!abriu && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(widget.state.t.assinaturaLinkFalhou)),
      );
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
    final oferecer = ofereceAssinar(_situacao);

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
                    else if (_situacao == SituacaoDoPlano.semPrazo)
                      Text(
                        t.assinaturaSemPrazo,
                        textAlign: TextAlign.center,
                        style: theme.textTheme.bodyLarge,
                      )
                    else if (_situacao == SituacaoDoPlano.assinante)
                      Text(
                        t.assinaturaJaTem,
                        textAlign: TextAlign.center,
                        style: theme.textTheme.bodyLarge,
                      )
                    else if (oferecer && _produto != null) ...[
                      // Quem está no teste vê quanto falta **antes** do preço.
                      // É a informação que torna o preço uma decisão em vez de
                      // uma cobrança do nada.
                      if (_diasDeTeste != null) ...[
                        Text(
                          t.assinaturaTesteAcaba(_diasDeTeste!),
                          key: const Key('assinatura-teste'),
                          textAlign: TextAlign.center,
                          style: theme.textTheme.titleSmall,
                        ),
                        const SizedBox(height: 4),
                        Text(
                          t.assinaturaDepoisDoTeste,
                          textAlign: TextAlign.center,
                          style: theme.textTheme.bodySmall,
                        ),
                        const SizedBox(height: 20),
                      ],
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
                    // Os dois documentos, **sempre visíveis** e fora de todo
                    // `if` acima. A diretriz 3.1.2 da Apple os exige na tela
                    // de compra, e é a rejeição mais comum em app de
                    // assinatura. Pendurá-los num ramo — só quando há produto,
                    // por exemplo — faria a tela cumprir a regra na máquina de
                    // quem escreveu e falhar na do revisor, que abre o app sem
                    // catálogo com mais frequência do que se imagina.
                    const SizedBox(height: 28),
                    Wrap(
                      alignment: WrapAlignment.center,
                      spacing: 4,
                      children: [
                        TextButton(
                          key: const Key('assinatura-termos'),
                          onPressed: () => _abrir('/termos'),
                          child: Text(t.assinaturaTermos),
                        ),
                        TextButton(
                          key: const Key('assinatura-privacidade'),
                          onPressed: () => _abrir('/privacidade'),
                          child: Text(t.assinaturaPrivacidade),
                        ),
                      ],
                    ),
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
