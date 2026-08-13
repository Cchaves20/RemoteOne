import 'package:deskside_client/models/remote_app.dart';
import 'package:flutter_test/flutter_test.dart';

/// O casamento entre um atalho da área de trabalho e um processo aberto.
///
/// É o que decide se o anel branco aparece na dock. Um erro aqui não quebra
/// nada — só mente sobre o estado do computador, que é o pior tipo de erro para
/// um indicador: quem olha confia.
void main() {
  group('matchName', () {
    test('tira a extensão e o caso', () {
      // O caso real: o atalho é "Spotify.lnk", o processo é "Spotify".
      expect(RemoteApp.matchName('Spotify.lnk'), 'spotify');
      expect(RemoteApp.matchName('Spotify'), 'spotify');
      expect(RemoteApp.matchName(r'C:\Users\eu\Desktop\Spotify.lnk'), 'spotify');
    });

    test('nome com ponto no meio não perde o pedaço certo', () {
      // Só a **última** extensão sai: "Visual Studio Code.lnk" não pode virar
      // "visual studio".
      expect(RemoteApp.matchName('Visual Studio Code.lnk'), 'visual studio code');
      expect(RemoteApp.matchName('node.js.exe'), 'node.js');
    });

    test('nome sem extensão fica inteiro', () {
      expect(RemoteApp.matchName('WindowsTerminal'), 'windowsterminal');
      // Ponto na primeira posição não é extensão: o nome inteiro sobrevive.
      expect(RemoteApp.matchName('.gitconfig'), '.gitconfig');
    });

    test('programas de nomes parecidos NÃO se confundem', () {
      // O motivo de a comparação ser exata em vez de por prefixo. Um casamento
      // frouxo diria que o Word está aberto quando quem está é o WordPad — e
      // dizer que um programa está aberto quando não está é pior do que não
      // dizer nada.
      expect(
        RemoteApp.matchName('Word.lnk') == RemoteApp.matchName('WordPad.exe'),
        isFalse,
      );
    });

    test('o limite conhecido: atalho e processo de nomes diferentes', () {
      // "Google Chrome.lnk" abre o processo "chrome". Este par **não** casa, e
      // está registrado aqui de propósito: é o preço da comparação exata, e o
      // efeito é o anel não aparecer — nunca um anel errado.
      //
      // Se um dia isto incomodar, o conserto é o agente devolver o executável
      // junto do atalho, e não afrouxar a comparação aqui.
      expect(
        RemoteApp.matchName('Google Chrome.lnk') == RemoteApp.matchName('chrome'),
        isFalse,
      );
    });
  });
}
