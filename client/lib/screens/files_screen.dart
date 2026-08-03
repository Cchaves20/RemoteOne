import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';

import '../l10n/strings.dart';
import '../models/device.dart';
import '../models/remote_file.dart';
import '../services/app_state.dart';
import '../theme.dart';

/// Arquivos do computador: navegar, trazer para o celular e mandar para lá.
///
/// A navegação começa na pasta do usuário e não sai dela — é o limite que o
/// agente impõe, e a tela reflete isso não oferecendo "voltar" na raiz.
class FilesScreen extends StatefulWidget {
  const FilesScreen({super.key, required this.state, required this.device});

  final AppState state;
  final Device device;

  @override
  State<FilesScreen> createState() => _FilesScreenState();
}

class _FilesScreenState extends State<FilesScreen> {
  RemoteListing? _listing;
  String? _error;
  bool _loading = false;

  /// Nome do arquivo em transferência, ou `null` se nada está em curso.
  ///
  /// Um de cada vez: são operações caras e o celular não ganha nada iniciando
  /// três ao mesmo tempo numa conexão só.
  String? _busy;

  @override
  void initState() {
    super.initState();
    _open('');
  }

  Future<void> _open(String path) async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final listing = await widget.state.listFiles(widget.device, path: path);
      if (!mounted) return;
      setState(() => _listing = listing);
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = e.toString());
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  /// Traz um arquivo e abre a folha de compartilhamento do iOS, onde a pessoa
  /// escolhe "Salvar em Arquivos".
  ///
  /// O app não escreve direto na pasta do usuário porque o iPhone não tem
  /// pasta do usuário: o único caminho para o arquivo sair da caixa do app é a
  /// folha de compartilhamento.
  Future<void> _download(RemoteFile file) async {
    if (_busy != null) return;
    final messenger = ScaffoldMessenger.of(context);
    final t = widget.state.t;
    // De onde a folha de compartilhamento sai. No iPad ela é um balão preso a
    // um ponto da tela; sem isso ele nasce no meio, longe do que foi tocado.
    final origem = _shareOrigin();
    setState(() => _busy = file.name);
    try {
      final bytes = await widget.state.downloadFile(widget.device, file.path);
      final dir = await getTemporaryDirectory();
      final local = File('${dir.path}/${file.name}');
      await local.writeAsBytes(bytes);
      if (!mounted) return;
      await SharePlus.instance.share(
        ShareParams(
          files: [XFile(local.path)],
          title: file.name,
          sharePositionOrigin: origem,
        ),
      );
    } catch (e) {
      messenger.showSnackBar(
        SnackBar(content: Text('${t.fileDownloadFailed}: $e')),
      );
    } finally {
      if (mounted) setState(() => _busy = null);
    }
  }

  /// Escolhe um arquivo no iPhone e o manda para a pasta do computador.
  Future<void> _upload() async {
    if (_busy != null) return;
    final messenger = ScaffoldMessenger.of(context);
    final t = widget.state.t;
    // `withData` traz o conteúdo junto: sem ele viria só um caminho, e no
    // iPhone esse caminho aponta para uma cópia temporária que o sistema pode
    // recolher antes do envio terminar.
    final escolha = await FilePicker.pickFiles(withData: true);
    if (escolha == null || escolha.files.isEmpty) return; // cancelou
    final arquivo = escolha.files.first;
    final bytes = arquivo.bytes;
    if (bytes == null) return;

    setState(() => _busy = arquivo.name);
    try {
      final destino =
          await widget.state.uploadFile(widget.device, arquivo.name, bytes);
      messenger.showSnackBar(
        SnackBar(content: Text(t.fileSentTo(destino))),
      );
    } catch (e) {
      messenger.showSnackBar(
        SnackBar(content: Text('${t.fileUploadFailed}: $e')),
      );
    } finally {
      if (mounted) setState(() => _busy = null);
    }
  }

  /// Retângulo desta tela, para ancorar o balão de compartilhamento no iPad.
  Rect? _shareOrigin() {
    final box = context.findRenderObject();
    if (box is! RenderBox || !box.hasSize) return null;
    return box.localToGlobal(Offset.zero) & box.size;
  }

  /// Tamanho legível. Base 1024, como o Windows mostra.
  static String _size(int bytes) {
    const kb = 1024;
    const mb = kb * 1024;
    const gb = mb * 1024;
    if (bytes >= gb) return '${(bytes / gb).toStringAsFixed(1)} GB';
    if (bytes >= mb) return '${(bytes / mb).toStringAsFixed(1)} MB';
    if (bytes >= kb) return '${(bytes / kb).toStringAsFixed(0)} KB';
    return '$bytes B';
  }

  @override
  Widget build(BuildContext context) {
    final t = widget.state.t;
    final listing = _listing;
    return Scaffold(
      appBar: AppBar(
        title: Text(listing == null || listing.path.isEmpty
            ? t.files
            : listing.name),
        actions: [
          IconButton(
            tooltip: t.refresh,
            icon: const Icon(Icons.refresh),
            onPressed: _loading ? null : () => _open(listing?.path ?? ''),
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _busy == null ? _upload : null,
        icon: const Icon(Icons.upload_file),
        label: Text(t.fileSend),
      ),
      body: Column(
        children: [
          // Faixa de progresso: sem ela, uma transferência longa parece a tela
          // travada. Não dá para mostrar porcentagem — a requisição é uma só,
          // e quem sabe o quanto já passou é o sistema, não o app.
          if (_busy != null)
            Material(
              color: Theme.of(context).colorScheme.surfaceContainerHighest,
              child: ListTile(
                leading: const SizedBox(
                  width: 20,
                  height: 20,
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
                title: Text(_busy!),
                subtitle: Text(t.fileTransferring),
              ),
            ),
          if (_loading) const LinearProgressIndicator(),
          Expanded(child: _body(listing)),
        ],
      ),
    );
  }

  Widget _body(RemoteListing? listing) {
    final t = widget.state.t;
    if (_error != null) {
      return _centered(
        icon: Icons.folder_off,
        title: _error!,
        action: TextButton(
          onPressed: () => _open(''),
          child: Text(t.filesBackToHome),
        ),
      );
    }
    if (listing == null) {
      return const SizedBox.shrink(); // a barra de progresso já diz o que houve
    }
    if (listing.entries.isEmpty && listing.parent == null) {
      return _centered(icon: Icons.folder_open, title: t.filesEmpty);
    }

    // O "voltar" é uma linha da lista, e não um botão da barra, porque é
    // navegação de pasta — o mesmo gesto de entrar numa.
    final subir = listing.parent;
    // Atalhos só existem na raiz, e viram uma faixa acima da lista: são a
    // resposta para "onde eu ponho as coisas", que quase nunca é a pasta do
    // usuário em si.
    final atalhos = listing.shortcuts;
    final extras = (subir == null ? 0 : 1) + (atalhos.isEmpty ? 0 : 1);
    return RefreshIndicator(
      onRefresh: () => _open(listing.path),
      child: ListView.separated(
        itemCount: listing.entries.length + extras,
        separatorBuilder: (_, __) => const Divider(height: 1),
        itemBuilder: (context, i) {
          if (atalhos.isNotEmpty && i == 0) return _shortcutStrip(atalhos, t);
          final deslocado = i - (atalhos.isEmpty ? 0 : 1);
          if (subir != null && deslocado == 0) {
            return ListTile(
              leading: const Icon(Icons.drive_file_move_rtl),
              title: Text(t.filesUp),
              onTap: _loading ? null : () => _open(subir),
            );
          }
          final item = listing.entries[deslocado - (subir == null ? 0 : 1)];
          return ListTile(
            leading: Icon(item.isDir ? Icons.folder : Icons.insert_drive_file),
            title: Text(item.name, overflow: TextOverflow.ellipsis),
            subtitle: item.isDir ? null : Text(_size(item.size)),
            trailing: item.isDir
                ? const Icon(Icons.chevron_right)
                : IconButton(
                    tooltip: t.fileBring,
                    icon: const Icon(Icons.download),
                    onPressed: _busy == null ? () => _download(item) : null,
                  ),
            onTap: item.isDir
                ? (_loading ? null : () => _open(item.path))
                : (_busy == null ? () => _download(item) : null),
          );
        },
      ),
    );
  }

  /// Faixa de atalhos para as pastas conhecidas do computador.
  ///
  /// Rolagem horizontal: são poucas e o que se quer é chegar a elas num toque,
  /// sem empurrar a lista de arquivos para fora da tela.
  Widget _shortcutStrip(List<RemoteFile> atalhos, Strings t) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            t.filesShortcuts,
            style: const TextStyle(color: Colors.white54, fontSize: 12),
          ),
          const SizedBox(height: 8),
          SizedBox(
            height: 84,
            child: ListView.separated(
              scrollDirection: Axis.horizontal,
              itemCount: atalhos.length,
              separatorBuilder: (_, __) => const SizedBox(width: 10),
              itemBuilder: (context, i) {
                final atalho = atalhos[i];
                return InkWell(
                  borderRadius: BorderRadius.circular(14),
                  onTap: _loading ? null : () => _open(atalho.path),
                  child: Container(
                    width: 92,
                    padding: const EdgeInsets.all(10),
                    decoration: BoxDecoration(
                      color: Colors.white10,
                      borderRadius: BorderRadius.circular(14),
                    ),
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Icon(_shortcutIcon(atalho.name),
                            color: auroraCyan, size: 26),
                        const SizedBox(height: 6),
                        Text(
                          atalho.name,
                          maxLines: 2,
                          textAlign: TextAlign.center,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(fontSize: 11),
                        ),
                      ],
                    ),
                  ),
                );
              },
            ),
          ),
        ],
      ),
    );
  }

  /// Ícone de cada pasta conhecida.
  ///
  /// A comparação é pelo começo do nome e sem acento: o computador responde no
  /// idioma dele ("Área de Trabalho", "Desktop", "Escritorio"), e um `switch`
  /// por igualdade exata só acertaria em português.
  static IconData _shortcutIcon(String nome) {
    final n = nome.toLowerCase();
    if (n.contains('trabalho') || n.contains('desktop')) {
      return Icons.desktop_windows;
    }
    if (n.contains('download')) return Icons.download;
    if (n.contains('document')) return Icons.description;
    if (n.contains('imagem') || n.contains('picture') || n.contains('foto')) {
      return Icons.image;
    }
    if (n.contains('music') || n.contains('músic')) return Icons.music_note;
    if (n.contains('vídeo') || n.contains('video')) return Icons.movie;
    return Icons.folder;
  }

  Widget _centered({
    required IconData icon,
    required String title,
    Widget? action,
  }) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 48, color: Colors.white24),
            const SizedBox(height: 12),
            Text(title, textAlign: TextAlign.center),
            if (action != null) ...[const SizedBox(height: 12), action],
          ],
        ),
      ),
    );
  }
}
