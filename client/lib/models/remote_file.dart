import 'dart:convert';
import 'dart:typed_data';

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
  const RemoteClipboard({
    this.text = '',
    this.files = const [],
    this.ignored = 0,
    this.image,
    this.imageMime,
    this.imageWidth,
    this.imageHeight,
  });

  final String text;
  final List<RemoteFile> files;

  /// Quantos arquivos copiados o computador recusou por estarem fora da pasta
  /// do usuário. Sem este número, copiar de `D:\` e não copiar nada dão a
  /// mesma tela vazia — e são coisas bem diferentes para quem está olhando.
  final int ignored;

  /// A imagem copiada no computador, já decodificada.
  ///
  /// Diferente dos arquivos, e a diferença é do Windows: copiar um vídeo no
  /// Explorer guarda o **caminho** dele, mas uma imagem copiada (um Print
  /// Screen, um recorte) não existe em disco — ela só existe na área de
  /// transferência. Ou vêm os bytes, ou não vem nada.
  final Uint8List? image;

  /// `image/png` ou `image/jpeg`. Decide a extensão do arquivo na hora de
  /// compartilhar: um `.png` que na verdade é JPEG confunde outros aplicativos.
  final String? imageMime;
  final int? imageWidth;
  final int? imageHeight;

  bool get hasImage => image != null;

  /// A extensão que corresponde ao tipo. `.png` como padrão porque é o formato
  /// que o agente prefere, e o único que sobra quando o tipo não veio.
  String get imageExtension => imageMime == 'image/jpeg' ? 'jpg' : 'png';

  factory RemoteClipboard.fromJson(Map<String, dynamic> json) {
    final b64 = json['image'] as String?;
    return RemoteClipboard(
      text: (json['text'] as String?) ?? '',
      files: ((json['files'] as List?) ?? [])
          .map((e) => RemoteFile.fromJson(e as Map<String, dynamic>))
          .toList(),
      ignored: (json['ignored'] as num?)?.toInt() ?? 0,
      // Base64 corrompido não pode derrubar a folha inteira: o texto e os
      // arquivos continuam valendo, e a imagem simplesmente não aparece.
      image: (b64 == null || b64.isEmpty) ? null : _decodificar(b64),
      imageMime: json['image_mime'] as String?,
      imageWidth: (json['image_width'] as num?)?.toInt(),
      imageHeight: (json['image_height'] as num?)?.toInt(),
    );
  }

  static Uint8List? _decodificar(String b64) {
    try {
      return base64Decode(b64);
    } catch (_) {
      return null;
    }
  }
}


/// Uma tela do computador.
class RemoteMonitor {
  const RemoteMonitor({
    required this.id,
    required this.name,
    this.width = 0,
    this.height = 0,
    this.primary = false,
  });

  /// Identificador do sistema. É por ele que se escolhe, e não pela posição na
  /// lista: a ordem muda quando alguém liga ou desliga um monitor, e uma
  /// posição guardada passaria a apontar para outra tela.
  final int id;
  final String name;
  final int width;
  final int height;
  final bool primary;

  String get resolution => width > 0 && height > 0 ? '$width × $height' : '';

  factory RemoteMonitor.fromJson(Map<String, dynamic> json) => RemoteMonitor(
        id: (json['id'] as num).toInt(),
        name: (json['name'] as String?) ?? '',
        width: (json['width'] as num?)?.toInt() ?? 0,
        height: (json['height'] as num?)?.toInt() ?? 0,
        primary: (json['primary'] as bool?) ?? false,
      );
}

/// As telas do computador e qual está sendo capturada.
class RemoteMonitors {
  const RemoteMonitors({this.monitors = const [], this.selected});

  final List<RemoteMonitor> monitors;

  /// `null` = ninguém escolheu, e vale o principal.
  final int? selected;

  factory RemoteMonitors.fromJson(Map<String, dynamic> json) => RemoteMonitors(
        monitors: ((json['monitors'] as List?) ?? [])
            .map((e) => RemoteMonitor.fromJson(e as Map<String, dynamic>))
            .toList(),
        selected: (json['selected'] as num?)?.toInt(),
      );
}
