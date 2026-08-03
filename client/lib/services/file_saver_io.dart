import 'dart:io';
import 'dart:typed_data';

import 'package:path_provider/path_provider.dart';

/// Telefone e desktop: grava num arquivo temporário e devolve o caminho, para
/// a tela abrir a folha de compartilhamento com ele.
///
/// Temporário de propósito: o destino final quem escolhe é o usuário, na folha.
/// Guardar numa pasta nossa criaria um segundo lugar onde arquivos se acumulam
/// sem ninguém saber.
Future<String?> saveFileImpl(Uint8List bytes, String name) async {
  final dir = await getTemporaryDirectory();
  final local = File('${dir.path}/$name');
  await local.writeAsBytes(bytes);
  return local.path;
}
