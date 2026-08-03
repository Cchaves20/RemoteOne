import 'dart:typed_data';

/// Só existe para o `import` condicional ter um alvo padrão. Nenhuma
/// plataforma de verdade cai aqui: ou tem `dart:io`, ou tem o navegador.
Future<String?> saveFileImpl(Uint8List bytes, String name) {
  throw UnsupportedError('salvar arquivo não é suportado nesta plataforma');
}
