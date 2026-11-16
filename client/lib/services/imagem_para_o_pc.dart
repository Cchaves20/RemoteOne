/// Prepara uma imagem do celular para ir à área de transferência do computador.
///
/// ## Por que nem sempre a imagem vai como veio
///
/// O agente lê PNG e JPEG, e o servidor aceita até 8 MB por imagem. Quase
/// sempre o que o celular tem já cabe nisso — uma captura de tela é um PNG de
/// um ou dois megabytes, uma foto da galeria é um JPEG de três ou quatro —, e
/// aí a imagem vai **exatamente** como está, sem perder nada.
///
/// O resto é convertido aqui, no celular:
///
/// - formato que o agente não lê (o HEIC das fotos do iPhone, por exemplo);
/// - imagem grande demais (a imagem copiada no iPhone chega como PNG sem
///   compressão de perdas, e uma foto de 12 MP em PNG passa de 20 MB).
///
/// A conversão reduz o maior lado e codifica em PNG, que é o que o `dart:ui`
/// sabe gravar. Se ainda não couber, reduz mais, até três vezes.
library;

import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

/// O teto do servidor (`MAX_CLIPBOARD_IMAGE_BYTES`, em `devices.py`).
const limiteDaImagemParaOPc = 8 * 1024 * 1024;

/// Maior lado depois de uma conversão. Uma tela de computador comum tem 1920
/// ou 2560 px de largura: mais que isso não aparece ao colar.
const ladoMaximoParaOPc = 2560;

/// O formato, pelos primeiros bytes — e não pela extensão, que a imagem
/// copiada nem tem.
enum FormatoDaImagem { png, jpeg, outro }

FormatoDaImagem formatoDe(Uint8List bytes) {
  if (bytes.length >= 8 &&
      bytes[0] == 0x89 &&
      bytes[1] == 0x50 &&
      bytes[2] == 0x4E &&
      bytes[3] == 0x47) {
    return FormatoDaImagem.png;
  }
  if (bytes.length >= 3 &&
      bytes[0] == 0xFF &&
      bytes[1] == 0xD8 &&
      bytes[2] == 0xFF) {
    return FormatoDaImagem.jpeg;
  }
  return FormatoDaImagem.outro;
}

/// Se a imagem pode ir como está, sem conversão nenhuma.
bool podeIrComoEsta(Uint8List bytes, {int limite = limiteDaImagemParaOPc}) =>
    bytes.isNotEmpty &&
    bytes.length <= limite &&
    formatoDe(bytes) != FormatoDaImagem.outro;

/// A imagem não coube no teto nem depois de reduzida.
class ImagemGrandeDemais implements Exception {
  const ImagemGrandeDemais();
}

/// A imagem pronta para mandar. Lança [ImagemGrandeDemais] se não couber, e
/// qualquer outro erro se o celular não conseguir lê-la.
Future<Uint8List> prepararImagemParaOPc(
  Uint8List bruta, {
  int limite = limiteDaImagemParaOPc,
  int ladoMaximo = ladoMaximoParaOPc,
}) async {
  if (podeIrComoEsta(bruta, limite: limite)) return bruta;
  var lado = ladoMaximo;
  for (var tentativa = 0; tentativa < 4; tentativa++) {
    final png = await _reduzirParaPng(bruta, lado);
    if (png.length <= limite) return png;
    lado = (lado * 0.7).round();
  }
  throw const ImagemGrandeDemais();
}

Future<Uint8List> _reduzirParaPng(Uint8List bruta, int lado) async {
  final buffer = await ui.ImmutableBuffer.fromUint8List(bruta);
  final descritor = await ui.ImageDescriptor.encoded(buffer);
  try {
    final maior = math.max(descritor.width, descritor.height);
    final escala = maior > lado ? lado / maior : 1.0;
    final codec = await descritor.instantiateCodec(
      targetWidth: math.max(1, (descritor.width * escala).round()),
      targetHeight: math.max(1, (descritor.height * escala).round()),
    );
    try {
      final quadro = await codec.getNextFrame();
      try {
        final dados =
            await quadro.image.toByteData(format: ui.ImageByteFormat.png);
        if (dados == null) {
          throw const FormatException('não consegui converter a imagem');
        }
        return dados.buffer.asUint8List(dados.offsetInBytes, dados.lengthInBytes);
      } finally {
        quadro.image.dispose();
      }
    } finally {
      codec.dispose();
    }
  } finally {
    descritor.dispose();
    buffer.dispose();
  }
}
