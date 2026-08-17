import 'package:deskside_client/config.dart';
import 'package:flutter_test/flutter_test.dart';

/// Guarda contra a volta de `localhost` como padrão de fábrica.
///
/// O defeito que este teste existe para impedir é do pior tipo: **não aparece
/// para quem desenvolve.** Quem escreve o app digitou o endereço do servidor uma
/// vez na tela de login, ele ficou salvo, e nunca mais apareceu. O padrão só é
/// usado numa instalação nova — o telefone de outra pessoa, que é exatamente
/// onde ninguém está olhando.
///
/// E foi assim que aconteceu: o app passou meses apontando para
/// `http://localhost:8000`, que num celular é o próprio celular. Uma instalação
/// nova não alcançava nem a tela de login.
///
/// O agente tem o teste gêmeo em Rust (`o_padrao_nao_pode_ser_a_propria_maquina`,
/// em `agent/src/lib.rs`), pelo mesmo motivo.
void main() {
  test('o padrão de fábrica não pode ser a própria máquina', () {
    // Compilar apontando para a rede local é legítimo para desenvolver, e é o
    // que o `--dart-define` faz. O que não pode é ser o valor embutido.
    const doBuild = bool.hasEnvironment('DESKSIDE_BACKEND');
    if (doBuild) return;

    expect(
      ehEnderecoLocal(backendPadrao),
      isFalse,
      reason: 'padrão de fábrica não pode ser a própria máquina: $backendPadrao',
    );
  });

  test('o padrão fala HTTPS', () {
    // Sem TLS, a senha e o token viajam em texto claro pelo Wi-Fi de qualquer
    // café. `http://` é aceitável só quando alguém escolheu apontar para a
    // própria rede — nunca como padrão de fábrica.
    if (bool.hasEnvironment('DESKSIDE_BACKEND')) return;
    expect(backendPadrao.startsWith('https://'), isTrue, reason: backendPadrao);
  });

  test('reconhece as formas de dizer "esta máquina"', () {
    expect(ehEnderecoLocal('http://localhost:8000'), isTrue);
    expect(ehEnderecoLocal('http://127.0.0.1:8000'), isTrue);
    expect(ehEnderecoLocal('http://0.0.0.0:8000'), isTrue);
    // O endereço que o emulador do Android usa para dizer "o computador que me
    // hospeda". Serve para desenvolver e não serve para ninguém mais.
    expect(ehEnderecoLocal('http://10.0.2.2:8000'), isTrue);
    // E não pode acusar um endereço legítimo.
    expect(ehEnderecoLocal('https://deskside.com.br'), isFalse);
    expect(ehEnderecoLocal('http://192.168.0.10:8000'), isFalse);
  });
}
