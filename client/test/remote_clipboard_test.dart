import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:deskside_client/models/remote_file.dart';

/// A área de transferência do computador, como o app a lê.
///
/// A imagem é o caso novo, e ela é diferente dos arquivos por um detalhe do
/// Windows: copiar um vídeo no Explorer guarda o **caminho** dele, mas uma
/// imagem copiada (um Print Screen, um recorte) não existe em disco — ela só
/// existe na área de transferência. Ou vêm os bytes, ou não vem nada.
void main() {
  // Um PNG mínimo de 1×1, o menor arquivo que uma decodificação aceita.
  const pngBase64 =
      'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==';

  group('imagem copiada', () {
    test('chega decodificada, com tipo e tamanho', () {
      final c = RemoteClipboard.fromJson({
        'text': '',
        'files': [],
        'ignored': 0,
        'image': pngBase64,
        'image_mime': 'image/png',
        'image_width': 1920,
        'image_height': 1080,
      });
      expect(c.hasImage, isTrue);
      expect(c.image, base64Decode(pngBase64));
      expect(c.imageMime, 'image/png');
      expect(c.imageWidth, 1920);
      expect(c.imageHeight, 1080);
    });

    test('a extensão acompanha o tipo', () {
      // Um `.png` que na verdade é JPEG confunde outros aplicativos: o iOS
      // decide por extensão o que oferecer na folha de compartilhar.
      RemoteClipboard comTipo(String? mime) => RemoteClipboard.fromJson({
            'image': pngBase64,
            'image_mime': mime,
          });
      expect(comTipo('image/jpeg').imageExtension, 'jpg');
      expect(comTipo('image/png').imageExtension, 'png');
      // Sem tipo, PNG: é o formato que o agente prefere.
      expect(comTipo(null).imageExtension, 'png');
    });

    test('sem imagem copiada, hasImage é falso', () {
      final c = RemoteClipboard.fromJson({'text': 'só texto', 'files': []});
      expect(c.hasImage, isFalse);
      expect(c.image, isNull);
      expect(c.text, 'só texto');
    });

    test('agente antigo não manda os campos, e nada quebra', () {
      // O caso que acontece de verdade: o app atualiza e o agente do
      // computador não. O texto e os arquivos têm que continuar chegando.
      final c = RemoteClipboard.fromJson({
        'text': 'do computador',
        'files': [
          {'name': 'a.txt', 'path': 'C:\\a.txt', 'is_dir': false, 'size': 10},
        ],
        'ignored': 2,
      });
      expect(c.text, 'do computador');
      expect(c.files, hasLength(1));
      expect(c.ignored, 2);
      expect(c.hasImage, isFalse);
    });

    test('base64 corrompido não derruba o resto', () {
      // A imagem some, mas o texto e os arquivos continuam valendo. Uma
      // exceção aqui esvaziaria a folha inteira por causa de um campo.
      final c = RemoteClipboard.fromJson({
        'text': 'importante',
        'files': [],
        'image': 'isto não é base64 %%%',
        'image_mime': 'image/png',
      });
      expect(c.hasImage, isFalse);
      expect(c.text, 'importante');
    });

    test('imagem vazia é ausência, não imagem de zero byte', () {
      final c = RemoteClipboard.fromJson({'image': ''});
      expect(c.hasImage, isFalse);
    });
  });
}
