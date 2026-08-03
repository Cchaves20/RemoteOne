import 'dart:typed_data';

// A implementação certa é escolhida na compilação. É a forma de o app existir
// no navegador **e** no telefone sem `if` espalhado pelas telas — e sem que o
// `dart:io`, que não existe na web, apareça no caminho do compilador.
import 'file_saver_stub.dart'
    if (dart.library.io) 'file_saver_io.dart'
    if (dart.library.js_interop) 'file_saver_web.dart';

/// Entrega um arquivo baixado do computador ao usuário.
///
/// Os dois mundos querem coisas diferentes, e forçar um só seria pior nos dois:
///
/// - **No telefone**, o certo é gravar num arquivo temporário e abrir a folha
///   de compartilhamento, onde a pessoa escolhe "Salvar em Arquivos", mandar
///   por WhatsApp, abrir num app. Por isso volta um **caminho**.
/// - **No navegador**, quem decide onde salvar é o próprio navegador, e a folha
///   de compartilhamento ou não existe ou é pior que o download comum. Por isso
///   o arquivo já desce e volta `null`: não há caminho, e não há o que a tela
///   deva fazer depois.
///
/// `null` significa "já entreguei, siga em frente", e não "falhei" — falha vem
/// como exceção.
Future<String?> saveDownloadedFile(Uint8List bytes, String name) =>
    saveFileImpl(bytes, name);
