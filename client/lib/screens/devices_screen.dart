import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../config.dart';
import '../models/automation.dart';
import '../models/device.dart';
import '../services/app_state.dart';
import '../services/atalhos_do_icone.dart';
import '../services/saudacao.dart';
import '../theme.dart';
import '../widgets/campo_de_codigo.dart';
import '../widgets/identidade.dart';
import '../widgets/links_legais.dart';
import '../widgets/plano.dart';
import '../widgets/pulse.dart';
import '../widgets/transitions.dart';
import 'apps_screen.dart';
import 'automations_screen.dart' show runAutomationFlow;
import 'files_screen.dart';
import 'keep_awake_screen.dart';
import 'remote_screen.dart';
import 'settings_screen.dart';

/// Lista os computadores pareados e permite parear um novo pelo código.
class DevicesScreen extends StatefulWidget {
  const DevicesScreen({super.key, required this.state});

  final AppState state;

  @override
  State<DevicesScreen> createState() => _DevicesScreenState();
}

class _DevicesScreenState extends State<DevicesScreen>
    with WidgetsBindingObserver {
  bool _loading = true;

  /// Um atalho do ícone está rodando: o segundo toque espera este terminar.
  bool _rodandoAtalho = false;

  /// O pedido de aceite dos termos está na tela: não abre outro por cima.
  bool _pedindoTermos = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    widget.state.addListener(_talvezRodarAtalho);
    widget.state.addListener(_talvezPedirTermos);
    WidgetsBinding.instance.addPostFrameCallback((_) => _talvezPedirTermos());
    // O app pode ter aberto **pelo** atalho: o pedido já está lá esperando.
    WidgetsBinding.instance.addPostFrameCallback((_) => _talvezRodarAtalho());
    // Atualiza a lista ao abrir. `recarregar` não lança: sem rede, marca
    // `semConexao` e tenta de novo sozinho.
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      await widget.state.recarregar();
      if (mounted) setState(() => _loading = false);
    });
  }

  @override
  void dispose() {
    widget.state.removeListener(_talvezRodarAtalho);
    widget.state.removeListener(_talvezPedirTermos);
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  /// Pede o aceite quando a conta ainda não aceitou a versão em vigor dos
  /// termos (conta de antes do aceite, ou termos que mudaram).
  ///
  /// Depois do desbloqueio, pelo mesmo motivo do atalho: esta tela fica montada
  /// por baixo do bloqueio, e o pedido apareceria antes de a pessoa entrar.
  void _talvezPedirTermos() {
    final state = widget.state;
    if (_pedindoTermos || !mounted || state.bloqueado) return;
    if (!(state.conta?.termosPendentes ?? false)) return;
    _pedindoTermos = true;
    pedirAceiteDosTermos(context, state).whenComplete(() => _pedindoTermos = false);
  }

  /// Roda a automação que um atalho do ícone pediu, quando der.
  ///
  /// "Quando der" é: com sessão, e com o app **desbloqueado** — esta tela
  /// fica montada por baixo do bloqueio, e rodar antes do desbloqueio seria
  /// deixar o ícone de um celular perdido mexer no computador.
  void _talvezRodarAtalho() {
    final state = widget.state;
    if (_rodandoAtalho ||
        state.atalhoPendente == null ||
        state.bloqueado ||
        !state.isAuthenticated) {
      return;
    }
    final id = automacaoDoAtalho(state.tomarAtalho()!);
    if (id == null) return;
    _rodandoAtalho = true;
    // Depois do quadro: este método é chamado de dentro de um
    // `notifyListeners`, e abrir diálogo ali seria mexer na árvore no meio
    // de uma reconstrução.
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      try {
        Automation? achar() =>
            state.automations.where((a) => a.id == id).firstOrNull;
        var automacao = achar();
        if (automacao == null) {
          await state.loadAutomations();
          automacao = achar();
        }
        if (!mounted) return;
        if (automacao == null) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text(state.t.atalhoSemAutomacao)),
          );
          return;
        }
        await runAutomationFlow(context, state, automacao);
      } finally {
        _rodandoAtalho = false;
      }
    });
  }

  /// Volta do segundo plano: relê na hora.
  ///
  /// É o momento em que a internet costuma ter voltado (saiu do modo avião,
  /// trocou de rede), e esperar a próxima tentativa agendada deixaria a lista
  /// velha por até um minuto na frente de quem acabou de abrir o app.
  @override
  void didChangeAppLifecycleState(AppLifecycleState estado) {
    if (estado == AppLifecycleState.resumed) widget.state.recarregar();
  }


  /// O código vem numa folha de baixo, em nove caixas como o computador mostra,
  /// e não num diálogo com um campo solto.
  Future<void> _showPairDialog() async {
    final t = widget.state.t;
    final controller = TextEditingController();
    final code = await showModalBottomSheet<String>(
      context: context,
      isScrollControlled: true,
      builder: (folha) => Padding(
        padding: EdgeInsets.fromLTRB(
            24, 0, 24, 24 + MediaQuery.viewInsetsOf(folha).bottom),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(t.pairComputer, style: Theme.of(folha).textTheme.headlineSmall),
            const SizedBox(height: 6),
            Text(t.digiteOCodigo,
                style: TextStyle(color: folha.cores.texto2, fontSize: 15)),
            const SizedBox(height: 18),
            CampoDeCodigo(
              controller: controller,
              rotulo: t.codeShownOnComputer,
              onCompleto: (c) => Navigator.pop(folha, c),
            ),
            const SizedBox(height: 18),
            BotaoDeskside(
              rotulo: t.pair,
              largo: true,
              onPressed: () => Navigator.pop(folha, controller.text.trim()),
            ),
          ],
        ),
      ),
    );
    if (code == null || code.isEmpty) return;
    try {
      final device = await widget.state.pair(code);
      if (!mounted) return;
      if (device.testeEncerrado) {
        // Diálogo, e não o aviso de rodapé de sempre: o plano da pessoa
        // acabou de mudar, e isso não pode sumir sozinho em quatro segundos.
        await showDialog<void>(
          context: context,
          builder: (dialogo) => AlertDialog(
            icon: const Icon(Icons.workspace_premium_outlined),
            title: Text(t.testeEncerradoTitulo),
            content: Text(t.testeEncerradoTexto),
            actions: [
              FilledButton(
                onPressed: () => Navigator.of(dialogo).pop(),
                child: Text(t.planoEntendi),
              ),
            ],
          ),
        );
        return;
      }
      Vibracao.conectou();
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(t.computerPaired)),
      );
    } catch (e) {
      if (!mounted) return;
      // O limite de plano sai do aviso vermelho e vira conversa. É o caminho
      // mais provável de esbarrar nele: a pessoa gostou e foi instalar no
      // segundo computador.
      if (ehLimiteDePlano(e)) {
        await mostrarLimiteDePlano(context, t, e.toString());
        return;
      }
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(e.toString())));
    }
  }

  /// Tocar num computador: abre a tela remota se ele está online; se não,
  /// diz o que fazer, em vez de abrir uma tela que só fica esperando.
  void _tocar(Device d) {
    if (d.online) {
      _openControl(d);
      return;
    }
    final t = widget.state.t;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(t.estaOffline(d.name)),
      action: SnackBarAction(label: t.control, onPressed: () => _openControl(d)),
    ));
  }

  void _openControl(Device device) {
    widget.state.selectDevice(device);
    Navigator.of(context).push(
      // A tela remota é sempre escura, como uma cabine, qualquer que seja o
      // tema do app. O tema vai na **rota**, e não dentro da tela: as folhas e
      // os diálogos que ela abre herdam o tema de quem os abriu, e precisam
      // sair escuros também.
      fadeThroughRoute(Theme(
        data: temaDaCabine,
        child: RemoteScreen(state: widget.state, device: device),
      )),
    );
  }

  Future<void> _runDeviceAction(
      Future<void> Function() action, String success) async {
    final messenger = ScaffoldMessenger.of(context);
    try {
      await action();
      if (mounted) {
        messenger.showSnackBar(SnackBar(content: Text(success)));
      }
    } catch (e) {
      if (mounted) {
        messenger.showSnackBar(SnackBar(content: Text(e.toString())));
      }
    }
  }

  Future<void> _showRenameDialog(Device device) async {
    final t = widget.state.t;
    final controller = TextEditingController(text: device.name);
    final name = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(t.renameComputer),
        content: TextField(
          controller: controller,
          autofocus: true,
          decoration: InputDecoration(labelText: t.name),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: Text(t.cancel),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, controller.text.trim()),
            child: Text(t.save),
          ),
        ],
      ),
    );
    if (name == null || name.isEmpty) return;
    await _runDeviceAction(
      () => widget.state.renameDevice(device, name),
      t.nameUpdated,
    );
  }

  Future<void> _confirmRemove(Device device) async {
    final t = widget.state.t;
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(t.removeComputer),
        content: Text(t.unlinkConfirm(device.name)),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: Text(t.cancel),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: Text(t.remove),
          ),
        ],
      ),
    );
    if (ok != true) return;
    await _runDeviceAction(
      () => widget.state.removeDevice(device),
      t.computerRemoved,
    );
  }

  Future<void> _confirmPower(Device device, String action) async {
    final t = widget.state.t;
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(t.powerLabel(action)),
        content: Text(t.powerConfirm(action, device.name)),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: Text(t.cancel),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: Text(t.powerLabel(action)),
          ),
        ],
      ),
    );
    if (ok != true) return;
    await _runDeviceAction(
      () => widget.state.powerDevice(device, action),
      t.powerSent(action),
    );
  }

  /// As ações de um computador, numa folha de baixo: segurar o monitor (ou o
  /// "⋯") abre. As automações daquele computador vêm primeiro — é o atalho
  /// que mais se usa —, depois o que antes ficava no menu de três pontos.
  Future<void> _acoes(Device d) async {
    final t = widget.state.t;
    Vibracao.tecla();
    final automacoes = widget.state.automations
        .where((a) => a.deviceId.isEmpty || a.deviceId == d.deviceId)
        .take(4)
        .toList();
    final escolha = await showModalBottomSheet<String>(
      context: context,
      isScrollControlled: true,
      builder: (folha) {
        final c = folha.cores;
        Widget item(String valor, IconData icone, String rotulo,
                {bool ativo = true, Widget? desenho}) =>
            ListTile(
              enabled: ativo,
              leading: desenho ?? Icon(icone),
              title: Text(rotulo),
              onTap: () => Navigator.pop(folha, valor),
            );
        return SafeArea(
          child: SingleChildScrollView(
            padding: const EdgeInsets.only(bottom: 12),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(20, 0, 20, 12),
                  child: Row(
                    children: [
                      MonitorDeskside(ligado: d.online, largura: 52),
                      const SizedBox(width: 14),
                      Expanded(
                        child: Text(d.name,
                            style: Theme.of(folha).textTheme.titleLarge,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis),
                      ),
                    ],
                  ),
                ),
                if (automacoes.isNotEmpty)
                  SizedBox(
                    height: 84,
                    child: ListView.separated(
                      scrollDirection: Axis.horizontal,
                      padding: const EdgeInsets.symmetric(horizontal: 16),
                      itemCount: automacoes.length,
                      separatorBuilder: (_, __) => const SizedBox(width: 8),
                      itemBuilder: (_, i) {
                        final a = automacoes[i];
                        return _TeclaDeAtalho(
                          icone: a.iconData,
                          rotulo: a.name,
                          ativo: d.online,
                          onTap: () => Navigator.pop(folha, 'auto:${a.id}'),
                        );
                      },
                    ),
                  ),
                if (automacoes.isNotEmpty) Divider(color: c.linha, height: 20),
                item('open', Icons.play_arrow_rounded, t.control),
                item('apps', Icons.apps, t.apps,
                    ativo: d.online,
                    desenho: const IconeDaMarca(IconeDeskside.programas)),
                item('files', Icons.folder, t.files,
                    ativo: d.online,
                    desenho: const IconeDaMarca(IconeDeskside.arquivos)),
                item('ready', Icons.bedtime_off, t.keepAwakeTitle, ativo: d.online),
                item('rename', Icons.edit_outlined, t.rename),
                Divider(color: c.linha, height: 12),
                item('shutdown', Icons.power_settings_new, t.shutdown,
                    ativo: d.online,
                    desenho: const IconeDaMarca(IconeDeskside.energia)),
                item('restart', Icons.restart_alt, t.restart, ativo: d.online),
                item('suspend', Icons.bedtime_outlined, t.suspend, ativo: d.online),
                Divider(color: c.linha, height: 12),
                ListTile(
                  leading: Icon(Icons.link_off, color: c.perigo),
                  title: Text(t.remove, style: TextStyle(color: c.perigo)),
                  onTap: () => Navigator.pop(folha, 'remove'),
                ),
              ],
            ),
          ),
        );
      },
    );
    if (escolha == null || !mounted) return;
    if (escolha.startsWith('auto:')) {
      final id = escolha.substring(5);
      final a = widget.state.automations.where((x) => x.id == id).firstOrNull;
      if (a != null) await runAutomationFlow(context, widget.state, a);
      return;
    }
    switch (escolha) {
      case 'open':
        _openControl(d);
      case 'apps':
        Navigator.of(context).push(
          fadeThroughRoute(AppsScreen(state: widget.state, device: d)),
        );
      case 'files':
        Navigator.of(context).push(
          fadeThroughRoute(FilesScreen(state: widget.state, device: d)),
        );
      case 'ready':
        Navigator.of(context).push(
          fadeThroughRoute(KeepAwakeScreen(state: widget.state, device: d)),
        );
      case 'rename':
        _showRenameDialog(d);
      case 'shutdown':
      case 'restart':
      case 'suspend':
        _confirmPower(d, escolha);
      case 'remove':
        _confirmRemove(d);
    }
  }

  /// A lista não veio porque o celular está sem internet.
  Widget _semConexao(BuildContext context) {
    final theme = Theme.of(context);
    final t = widget.state.t;
    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(28, 48, 28, 120),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const Center(child: MonitorDeskside(ligado: false, largura: 150)),
          const SizedBox(height: 24),
          Text(t.semConexaoTitulo,
              textAlign: TextAlign.center, style: theme.textTheme.titleLarge),
          const SizedBox(height: 12),
          Text(t.semConexaoTexto,
              textAlign: TextAlign.center,
              style: TextStyle(color: context.cores.texto2, fontSize: 15)),
          const SizedBox(height: 24),
          Center(
            child: OutlinedButton.icon(
              onPressed: widget.state.recarregar,
              icon: const Icon(Icons.refresh),
              label: Text(t.retry),
            ),
          ),
        ],
      ),
    );
  }

  /// Faixa acima da lista quando ela já existia e a conexão caiu: a lista
  /// fica, mas o "online" de cada computador é de antes da queda.
  Widget _avisoSemConexao(BuildContext context) {
    final c = context.cores;
    return Container(
      margin: const EdgeInsets.fromLTRB(20, 0, 20, 12),
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      decoration: BoxDecoration(
        color: c.superficie,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: c.linha),
      ),
      child: Row(
        children: [
          Icon(Icons.cloud_off, size: 18, color: c.texto2),
          const SizedBox(width: 10),
          Expanded(
            child: Text(widget.state.t.semConexaoAviso,
                style: TextStyle(color: c.texto2, fontSize: 13)),
          ),
        ],
      ),
    );
  }

  /// A tela de primeiro uso.
  ///
  /// Era um ícone e uma frase: "Nenhum computador pareado. Toque em + e informe
  /// o código exibido pelo agente." Um beco sem saída para quem chega aqui pela
  /// primeira vez, porque supunha duas coisas que essa pessoa não tem — saber o
  /// que é "o agente", e tê-lo já instalado. **Nunca dizia que existe um
  /// programa a instalar no computador**, que é justamente o passo que falta.
  ///
  /// A cena de cima (o monitor e o celular ligados por uma linha tracejada)
  /// mostra o que vai acontecer antes de qualquer texto.
  ///
  /// Rolável de propósito: num telefone pequeno com a fonte do sistema
  /// aumentada isso não cabe na altura da tela, e um `Center` fixo cortaria
  /// justamente o botão.
  Widget _emptyState(BuildContext context) {
    final theme = Theme.of(context);
    final c = context.cores;
    final t = widget.state.t;
    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(24, 8, 24, 120),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const _CenaDoPareamento(),
          const SizedBox(height: 20),
          Text(t.noComputers, style: theme.textTheme.headlineSmall),
          const SizedBox(height: 20),
          _passo(1, Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(t.primeiroPassoBaixar(siteDeskside),
                  style: const TextStyle(fontSize: 15)),
              const SizedBox(height: 6),
              // Copiar em vez de abrir: o endereço tem que ser digitado no
              // **computador**, não aberto no celular.
              Align(
                alignment: Alignment.centerLeft,
                child: TextButton.icon(
                  onPressed: _copiarEndereco,
                  icon: const Icon(Icons.copy, size: 16),
                  label: Text(siteDeskside,
                      style: context.numeros.copyWith(fontSize: 14)),
                ),
              ),
            ],
          )),
          _passo(2, Text(t.primeiroPassoCodigo, style: const TextStyle(fontSize: 15))),
          _passo(3, Text(t.primeiroPassoDigitar, style: const TextStyle(fontSize: 15))),
          const SizedBox(height: 8),
          // O botão grande **além** do flutuante, e não em vez dele: quem nunca
          // pareou nada não lê "Parear" como "é aqui que eu começo".
          BotaoDeskside(
            rotulo: t.tenhoUmCodigo,
            icone: Icons.dialpad,
            largo: true,
            onPressed: _showPairDialog,
          ),
          const SizedBox(height: 20),
          Text(
            t.ondeAchoOCodigo,
            textAlign: TextAlign.center,
            style: TextStyle(color: c.texto3, fontSize: 12),
          ),
        ],
      ),
    );
  }

  /// Um passo numerado: o círculo com o número e o conteúdo ao lado.
  Widget _passo(int numero, Widget conteudo) {
    final c = context.cores;
    return Padding(
      padding: const EdgeInsets.only(bottom: 16),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: 28,
            height: 28,
            alignment: Alignment.center,
            decoration: BoxDecoration(color: c.superficieAlta, shape: BoxShape.circle),
            child: Text('$numero',
                style: context.numeros.copyWith(fontSize: 13, color: c.texto)),
          ),
          const SizedBox(width: 14),
          Expanded(child: Padding(padding: const EdgeInsets.only(top: 4), child: conteudo)),
        ],
      ),
    );
  }

  Future<void> _copiarEndereco() async {
    await Clipboard.setData(const ClipboardData(text: siteDeskside));
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(widget.state.t.enderecoCopiado)),
    );
  }

  /// O que vai abaixo do nome: o sistema, a máquina (só quando o nome que a
  /// pessoa deu é outro — "PC-Caio · PC-Caio" é ruído) e o online/offline.
  String _detalhe(Device d) {
    final t = widget.state.t;
    final partes = <String>[d.nomeDoSistema];
    final host = d.hostname.trim();
    if (host.isNotEmpty && host.toLowerCase() != d.name.trim().toLowerCase()) {
      partes.add(host);
    }
    partes.add(d.online ? t.online : t.offline);
    return partes.join(' · ');
  }

  /// O programa em primeiro plano de cada computador em destaque, para a
  /// tela acesa do monitor grande. Pedido uma vez por abertura do início.
  final Map<String, String?> _primeiroPlano = {};

  void _talvezBuscarPrimeiroPlano(Device d) {
    if (!d.online || _primeiroPlano.containsKey(d.deviceId)) return;
    _primeiroPlano[d.deviceId] = null;
    widget.state.foregroundApp(d).then((app) {
      if (!mounted || app == null || app.hidden || app.name.isEmpty) return;
      setState(() => _primeiroPlano[d.deviceId] = app.name);
    }).catchError((_) {});
  }

  Widget _destaque(Device d) {
    final t = widget.state.t;
    final c = context.cores;
    _talvezBuscarPrimeiroPlano(d);
    final programa = _primeiroPlano[d.deviceId];
    return LayoutBuilder(builder: (context, limites) {
      final largura = limites.maxWidth;
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Semantics(
            button: true,
            label: '${d.name}, ${d.online ? t.online : t.offline}',
            onLongPressHint: t.acoesDoComputador,
            child: GestureDetector(
              onTap: () => _tocar(d),
              onLongPress: () => _acoes(d),
              child: MonitorDeskside(
                ligado: d.online,
                largura: largura,
                heroTag: 'monitor-${d.deviceId}',
                conteudo: _TelaAcesa(programa: programa),
              ),
            ),
          ),
          const SizedBox(height: 16),
          Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(d.name,
                        style: Theme.of(context).textTheme.titleLarge,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis),
                    const SizedBox(height: 4),
                    Text(_detalhe(d),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                            fontSize: 13, color: d.online ? c.led : c.texto3)),
                  ],
                ),
              ),
              IconButton(
                tooltip: t.acoesDoComputador,
                icon: Icon(Icons.more_horiz, color: c.texto2),
                onPressed: () => _acoes(d),
              ),
              const SizedBox(width: 4),
              BotaoDeskside(
                rotulo: t.continueButton,
                icone: Icons.arrow_forward_rounded,
                iconeDepois: true,
                altura: 50,
                onPressed: () => _tocar(d),
              ),
            ],
          ),
        ],
      );
    });
  }

  Widget _linha(Device d) {
    final c = context.cores;
    final t = widget.state.t;
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Material(
        color: c.superficie,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(16),
          side: BorderSide(color: c.linha),
        ),
        child: InkWell(
          borderRadius: BorderRadius.circular(16),
          onTap: () => _tocar(d),
          onLongPress: () => _acoes(d),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(14, 12, 4, 12),
            child: Row(
              children: [
                MonitorDeskside(ligado: d.online, largura: 58),
                const SizedBox(width: 14),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(d.name,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                              fontWeight: FontWeight.w600,
                              fontSize: 16,
                              color: d.online ? c.texto : c.texto2)),
                      const SizedBox(height: 3),
                      Text(_detalhe(d),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                              fontSize: 13, color: d.online ? c.led : c.texto3)),
                    ],
                  ),
                ),
                IconButton(
                  tooltip: t.acoesDoComputador,
                  icon: Icon(Icons.more_horiz, color: c.texto3),
                  onPressed: () => _acoes(d),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _cabecalho() {
    final state = widget.state;
    final t = state.t;
    final c = context.cores;
    final agora = DateTime.now();
    final festa = ehAniversario(state.conta, agora);
    final online = state.devices.where((d) => d.online).length;
    final total = state.devices.length;
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 12, 12, 20),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Flexible(
                      child: Text(
                        saudacao(t, state.conta, agora),
                        style: Theme.of(context)
                            .textTheme
                            .headlineMedium
                            ?.copyWith(fontSize: 28),
                      ),
                    ),
                    if (festa) ...[
                      const SizedBox(width: 10),
                      const Icon(Icons.cake_outlined, color: auroraCyan, size: 26),
                    ],
                  ],
                ),
                if (total > 0) ...[
                  const SizedBox(height: 6),
                  Row(
                    children: [
                      Container(
                        width: 8,
                        height: 8,
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          color: online > 0 ? c.led : c.bordaApagada,
                          boxShadow: online > 0
                              ? [BoxShadow(color: c.led, blurRadius: 8)]
                              : null,
                        ),
                      ),
                      const SizedBox(width: 8),
                      Flexible(
                        child: Text(t.computadoresOnline(online, total),
                            style: TextStyle(color: c.texto2, fontSize: 14)),
                      ),
                    ],
                  ),
                ],
              ],
            ),
          ),
          Material(
            color: c.superficie,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(14),
              side: BorderSide(color: c.linha),
            ),
            child: IconButton(
              tooltip: t.settings,
              icon: Icon(Icons.settings_outlined, color: c.texto),
              onPressed: () => Navigator.of(context).push(
                fadeThroughRoute(SettingsScreen(state: widget.state)),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _lista() {
    final state = widget.state;
    final t = state.t;
    final c = context.cores;
    final destaque = state.computadorEmDestaque!;
    // Os outros: online primeiro, depois pelo nome.
    final outros = state.devices.where((d) => d.deviceId != destaque.deviceId).toList()
      ..sort((a, b) {
        if (a.online != b.online) return a.online ? -1 : 1;
        return a.name.toLowerCase().compareTo(b.name.toLowerCase());
      });
    return RefreshIndicator(
      onRefresh: state.recarregar,
      child: ListView(
        padding: const EdgeInsets.fromLTRB(20, 0, 20, 120),
        children: [
          FadeSlideIn(child: _destaque(destaque)),
          if (outros.isNotEmpty) ...[
            const SizedBox(height: 28),
            Text(t.outrosComputadores.toUpperCase(),
                style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                    letterSpacing: 0.8,
                    color: c.texto3)),
            const SizedBox(height: 10),
            for (var i = 0; i < outros.length; i++)
              FadeSlideIn(
                delay: Duration(milliseconds: 50 * (i + 1)),
                child: _linha(outros[i]),
              ),
          ],
          const SizedBox(height: 8),
          Text(t.segureParaAcoes, style: TextStyle(fontSize: 12, color: c.texto3)),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final t = widget.state.t;
    return Scaffold(
      body: ListenableBuilder(
        listenable: widget.state,
        builder: (context, _) {
          final state = widget.state;
          final devices = state.devices;
          final semConexao = state.semConexao;
          final festa = ehAniversario(state.conta, DateTime.now());
          Widget corpo;
          if (devices.isEmpty && _loading) {
            corpo = const _SkeletonList();
          } else if (devices.isEmpty && semConexao) {
            // Sem conexão **antes** de "nenhum computador": a lista vazia aqui
            // é "não consegui perguntar", e o convite para parear mandaria a
            // pessoa parear de novo um computador que já está na conta.
            corpo = _semConexao(context);
          } else if (devices.isEmpty) {
            corpo = _emptyState(context);
          } else {
            corpo = _lista();
          }
          return Stack(
            children: [
              if (festa) const Positioned.fill(child: IgnorePointer(child: _Confete())),
              SafeArea(
                bottom: false,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    _cabecalho(),
                    if (semConexao && devices.isNotEmpty) _avisoSemConexao(context),
                    Expanded(child: corpo),
                  ],
                ),
              ),
              Positioned(
                left: 0,
                right: 0,
                bottom: 24 + MediaQuery.paddingOf(context).bottom,
                child: Center(
                  child: BotaoDeskside(
                    rotulo: t.pairComputer,
                    icone: Icons.add_rounded,
                    redondo: true,
                    onPressed: _showPairDialog,
                  ),
                ),
              ),
            ],
          );
        },
      ),
    );
  }
}

/// O que aparece dentro da tela acesa do monitor grande: o programa em
/// primeiro plano, quando se sabe, e o cursor da marca.
class _TelaAcesa extends StatelessWidget {
  const _TelaAcesa({this.programa});

  final String? programa;

  @override
  Widget build(BuildContext context) {
    return Stack(
      children: [
        const Align(
          alignment: Alignment(0.25, -0.1),
          child: CursorDaMarca(tamanho: 34),
        ),
        if (programa != null)
          Positioned(
            left: 12,
            bottom: 12,
            right: 12,
            child: Align(
              alignment: Alignment.centerLeft,
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
                decoration: BoxDecoration(
                  color: const Color(0xB30B0D1A),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Text(
                  programa!,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: context.numeros
                      .copyWith(fontSize: 12, color: const Color(0xFFC9CEEA)),
                ),
              ),
            ),
          ),
      ],
    );
  }
}

/// Uma tecla de atalho (as automações na folha de ações): o mesmo material
/// com relevo do teclado remoto.
class _TeclaDeAtalho extends StatelessWidget {
  const _TeclaDeAtalho({
    required this.icone,
    required this.rotulo,
    required this.onTap,
    this.ativo = true,
  });

  final IconData icone;
  final String rotulo;
  final VoidCallback onTap;
  final bool ativo;

  @override
  Widget build(BuildContext context) {
    final c = context.cores;
    return Opacity(
      opacity: ativo ? 1 : 0.45,
      child: Material(
        color: c.tecla,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
        child: InkWell(
          borderRadius: BorderRadius.circular(14),
          onTap: ativo ? onTap : null,
          child: Container(
            width: 104,
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 10),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(14),
              border: Border(bottom: BorderSide(color: c.teclaSombra, width: 3)),
            ),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(icone, color: c.aoVivo, size: 22),
                const SizedBox(height: 6),
                Text(rotulo,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(fontSize: 12, color: c.texto)),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// O desenho da tela vazia: o monitor e o celular ligados por uma linha
/// tracejada, com o código no monitor.
class _CenaDoPareamento extends StatelessWidget {
  const _CenaDoPareamento();

  @override
  Widget build(BuildContext context) {
    final c = context.cores;
    return ExcludeSemantics(
      child: SizedBox(
        height: 150,
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            MonitorDeskside(
              ligado: true,
              largura: 150,
              proporcao: 1.6,
              conteudo: Center(
                child: Text('K7Q 4ZP 9M2',
                    style: context.numeros.copyWith(
                        fontSize: 14,
                        letterSpacing: 1.5,
                        color: const Color(0xFFC9CEEA))),
              ),
            ),
            SizedBox(
              width: 64,
              child: CustomPaint(
                size: const Size(64, 12),
                painter: _Tracejado(c.aoVivo),
              ),
            ),
            Container(
              width: 56,
              height: 104,
              padding: const EdgeInsets.all(2.5),
              decoration: BoxDecoration(
                gradient: auroraGradient,
                borderRadius: BorderRadius.circular(14),
              ),
              child: Container(
                decoration: BoxDecoration(
                  color: const Color(0xFF0F1330),
                  borderRadius: BorderRadius.circular(11.5),
                ),
                alignment: Alignment.center,
                child: Container(
                  width: 28,
                  height: 18,
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(4),
                    border: Border.all(color: auroraBlue, width: 1.5),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _Tracejado extends CustomPainter {
  _Tracejado(this.cor);

  final Color cor;

  @override
  void paint(Canvas canvas, Size size) {
    final p = Paint()
      ..color = cor.withAlpha(160)
      ..strokeWidth = 2
      ..strokeCap = StrokeCap.round;
    final y = size.height / 2;
    for (double x = 4; x < size.width - 4; x += 8) {
      canvas.drawLine(Offset(x, y), Offset(x + 3, y), p);
    }
    canvas.drawCircle(
      Offset(size.width / 2, y),
      5,
      Paint()
        ..color = cor
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 2),
    );
  }

  @override
  bool shouldRepaint(_Tracejado old) => old.cor != cor;
}

/// O confete discreto do dia do aniversário, atrás do cabeçalho.
class _Confete extends StatelessWidget {
  const _Confete();

  @override
  Widget build(BuildContext context) =>
      CustomPaint(painter: _PintorDeConfete(MediaQuery.paddingOf(context).top + 6));
}

class _PintorDeConfete extends CustomPainter {
  const _PintorDeConfete(this.topo);

  final double topo;

  // Em volta do cabeçalho, e não em cima dele: confete por cima das letras
  // atrapalha justamente a frase que ele celebra. (x, y em pixels a partir do
  // topo da área segura; x em fração da largura.)
  static const _pecas = [
    (0.06, 4.0, Color(0xFFA78BFA), 20.0),
    (0.34, 0.0, auroraCyan, 0.0),
    (0.62, 6.0, Color(0xFF6D8BFF), -30.0),
    (0.74, 120.0, Color(0xFFFCD34D), 0.0),
    (0.93, 132.0, auroraCyan, 40.0),
    (0.56, 126.0, Color(0xFFA78BFA), 0.0),
    (0.40, 134.0, Color(0xFFFCD34D), -15.0),
  ];

  @override
  void paint(Canvas canvas, Size size) {
    for (final (x, y, cor, giro) in _pecas) {
      canvas.save();
      canvas.translate(x * size.width, y + topo);
      canvas.rotate(giro * 3.14159 / 180);
      final p = Paint()..color = cor.withAlpha(200);
      if (giro == 0) {
        canvas.drawCircle(Offset.zero, 3, p);
      } else {
        canvas.drawRRect(
          RRect.fromRectAndRadius(
              const Rect.fromLTWH(-3, -5, 6, 10), const Radius.circular(2)),
          p,
        );
      }
      canvas.restore();
    }
  }

  @override
  bool shouldRepaint(_PintorDeConfete old) => old.topo != topo;
}

/// Placeholder animado enquanto a lista de computadores carrega: o monitor
/// grande e duas linhas, no lugar onde eles vão aparecer.
class _SkeletonList extends StatelessWidget {
  const _SkeletonList();

  @override
  Widget build(BuildContext context) {
    return Pulse(
      child: ListView(
        physics: const NeverScrollableScrollPhysics(),
        padding: const EdgeInsets.fromLTRB(20, 0, 20, 12),
        children: [
          LayoutBuilder(
            builder: (context, l) => SkeletonBox(
              width: l.maxWidth,
              height: l.maxWidth / (16 / 9),
              radius: 18,
            ),
          ),
          const SizedBox(height: 18),
          const SkeletonBox(width: 160, height: 18),
          const SizedBox(height: 8),
          const SkeletonBox(width: 110, height: 12),
          const SizedBox(height: 30),
          for (var i = 0; i < 2; i++)
            const Padding(
              padding: EdgeInsets.only(bottom: 10),
              child: Row(
                children: [
                  SkeletonBox(width: 58, height: 36, radius: 7),
                  SizedBox(width: 14),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        SkeletonBox(width: 140, height: 14),
                        SizedBox(height: 8),
                        SkeletonBox(width: 90, height: 12),
                      ],
                    ),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }
}
