import 'dart:js_interop';
import 'dart:typed_data';

import 'package:web/web.dart' as web;

/// Navegador: dispara o download e devolve `null`.
///
/// O caminho é o de sempre na web: um `Blob` com os bytes, uma URL temporária
/// para ele e um link que se clica sozinho. Feio de descrever, mas é a única
/// forma de um site entregar um arquivo sem pedir permissão nenhuma - e é
/// exatamente o que o usuário espera de "baixar" num navegador.
///
/// A URL é revogada logo em seguida: ela segura o arquivo inteiro na memória da
/// aba, e um vídeo de 100 MB baixado três vezes seriam 300 MB presos até
/// alguém fechar a página.
Future<String?> saveFileImpl(Uint8List bytes, String name) async {
  final blob = web.Blob(
    [bytes.toJS].toJS,
    web.BlobPropertyBag(type: 'application/octet-stream'),
  );
  final url = web.URL.createObjectURL(blob);
  final link = web.document.createElement('a') as web.HTMLAnchorElement
    ..href = url
    ..download = name;
  link.click();
  web.URL.revokeObjectURL(url);
  return null;
}
