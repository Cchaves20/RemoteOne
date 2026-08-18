/// Para onde o app fala quando ninguém disse o contrário.
///
/// Existe como arquivo próprio, e não como constante escondida no `main.dart`,
/// por um motivo só: para poder ser **testado**. O valor errado aqui não quebra
/// nada visível no desenvolvimento — quem desenvolve digitou a URL do servidor
/// uma vez na tela de login, ela ficou salva, e nunca mais apareceu. Quebra na
/// instalação nova, no telefone de outra pessoa, que é onde ninguém está olhando.
///
/// ## O que estava errado
///
/// O padrão era `http://localhost:8000`. Num celular, `localhost` é o próprio
/// celular: uma instalação nova não alcançava nem a tela de login. O produto
/// funcionava só para quem já tinha configurado o endereço à mão.
///
/// ## Como se troca
///
/// O `--dart-define` do build vence este padrão, e é assim que se aponta o
/// celular a um backend na mesma rede:
///
/// ```text
/// flutter build apk --dart-define=DESKSIDE_BACKEND=http://192.168.0.10:8000
/// ```
///
/// A tela de login também continua editável, porque apontar para outro servidor
/// é caso legítimo — o que deixou de ser é **obrigatório**.
library;

const backendPadrao = String.fromEnvironment(
  'DESKSIDE_BACKEND',
  defaultValue: 'https://deskside.com.br',
);

/// O endereço da página onde se baixa o programa do computador.
///
/// **Separado do `backendPadrao` de propósito**, mesmo que hoje os dois sejam o
/// mesmo texto. São coisas diferentes: o backend é editável na tela de login
/// (apontar o celular a um servidor na mesma rede é caso legítimo), e o site é
/// sempre o mesmo. Se fossem um só, quem apontasse o app para
/// `http://192.168.0.10:8000` veria a tela de primeiro uso mandando baixar o
/// programa daquele endereço — que não serve página nenhuma.
const siteDeskside = 'deskside.com.br';

/// Se este endereço só funcionaria na máquina de quem compilou.
///
/// A regra que o teste cobra. Espelha a que o agente já tem em Rust
/// (`o_padrao_nao_pode_ser_a_propria_maquina`, em `agent/src/lib.rs`) — e pelo
/// mesmo motivo: é um defeito que passa por "funciona aqui".
bool ehEnderecoLocal(String url) {
  final u = url.toLowerCase();
  return u.contains('localhost') ||
      u.contains('127.0.0.1') ||
      u.contains('0.0.0.0') ||
      u.contains('10.0.2.2'); // o "localhost do computador" do emulador Android
}
