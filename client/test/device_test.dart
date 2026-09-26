import 'package:deskside_client/models/device.dart';
import 'package:flutter_test/flutter_test.dart';

/// O aviso de "teste encerrado" chega na resposta do pareamento.
///
/// É o único jeito de a pessoa saber por que os recursos pagos sumiram logo
/// depois de parear — e ausente num servidor antigo tem de valer `false`, que
/// no pior caso só deixa de mostrar um aviso.
void main() {
  Map<String, dynamic> resposta({bool? encerrado}) => {
        'device_id': 'dev-1',
        'name': 'PC da sala',
        'os': 'windows',
        'hostname': 'SALA',
        if (encerrado != null) 'teste_encerrado': encerrado,
      };

  test('o servidor avisa que o teste acabou', () {
    expect(Device.fromJson(resposta(encerrado: true)).testeEncerrado, isTrue);
  });

  test('pareamento comum não avisa nada', () {
    expect(Device.fromJson(resposta(encerrado: false)).testeEncerrado, isFalse);
  });

  test('servidor antigo, sem o campo, não inventa aviso', () {
    expect(Device.fromJson(resposta()).testeEncerrado, isFalse);
  });
}
