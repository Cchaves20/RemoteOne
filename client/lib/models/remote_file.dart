/// Um item de uma pasta do computador, como vem de GET /devices/{id}/files.
class RemoteFile {
  const RemoteFile({
    required this.name,
    required this.path,
    required this.isDir,
    required this.size,
  });

  final String name;

  /// Caminho absoluto no computador — é o que volta ao agente para navegar ou
  /// baixar. O app nunca monta caminho por conta própria.
  final String path;
  final bool isDir;
  final int size;

  factory RemoteFile.fromJson(Map<String, dynamic> json) {
    return RemoteFile(
      name: json['name'] as String,
      path: json['path'] as String,
      isDir: json['is_dir'] as bool? ?? false,
      size: (json['size'] as num?)?.toInt() ?? 0,
    );
  }
}

/// O conteúdo de uma pasta.
class RemoteListing {
  const RemoteListing({
    required this.path,
    required this.parent,
    required this.entries,
    this.shortcuts = const [],
  });

  final String path;

  /// Pasta acima, ou `null` quando já se está na raiz permitida (a pasta do
  /// usuário). O app usa isso para saber se mostra o "voltar" — oferecer um
  /// que sempre dá erro seria um beco sem saída visível.
  final String? parent;
  final List<RemoteFile> entries;

  /// Atalhos para as pastas conhecidas do computador (Área de Trabalho,
  /// Downloads...). Só vêm na raiz — é onde eles servem para alguma coisa.
  final List<RemoteFile> shortcuts;

  factory RemoteListing.fromJson(Map<String, dynamic> json) {
    final entries = (json['entries'] as List<dynamic>? ?? [])
        .map((e) => RemoteFile.fromJson(e as Map<String, dynamic>))
        .toList();
    return RemoteListing(
      path: json['path'] as String? ?? '',
      parent: json['parent'] as String?,
      entries: entries,
      shortcuts: (json['shortcuts'] as List<dynamic>? ?? [])
          .map((e) => RemoteFile.fromJson(e as Map<String, dynamic>))
          .toList(),
    );
  }

  /// Só o nome da pasta atual, para o título — o caminho inteiro não cabe.
  String get name {
    final limpo = path.replaceAll('\\', '/');
    final partes = limpo.split('/').where((p) => p.isNotEmpty).toList();
    return partes.isEmpty ? limpo : partes.last;
  }
}


/// O que está na área de transferência do computador.
///
/// `files` são os arquivos **copiados** por lá. Copiar um vídeo no Explorer não
/// põe o vídeo na área de transferência: põe o caminho dele. Por isso baixar é
/// com a transferência de arquivos, que já sabe buscar por caminho.
class RemoteClipboard {
  const RemoteClipboard({this.text = '', this.files = const []});

  final String text;
  final List<RemoteFile> files;

  factory RemoteClipboard.fromJson(Map<String, dynamic> json) {
    return RemoteClipboard(
      text: (json['text'] as String?) ?? '',
      files: ((json['files'] as List?) ?? [])
          .map((e) => RemoteFile.fromJson(e as Map<String, dynamic>))
          .toList(),
    );
  }
}
