import 'package:flutter_test/flutter_test.dart';
import 'package:deskside_client/l10n/strings.dart';
import 'package:deskside_client/models/automation.dart';
import 'package:deskside_client/models/window_zone.dart';

/// Automações: a sequência de passos que um toque executa.
///
/// Dois exemplos guiam a suíte, porque foram eles que motivaram o recurso:
/// **modo reunião** (abrir o Teams à esquerda, o OneNote à direita, silenciar,
/// brilho em 80%) e **fim do expediente** (fechar o Slack, fechar o Outlook,
/// brilho no mínimo, suspender).
///
/// O que se protege aqui é o que atravessa a rede — os nomes dos campos, a
/// ordem, e a ausência dos campos que não são do tipo do passo. Nada disso
/// falha de forma visível: um campo com o nome errado vira um passo que o
/// computador simplesmente não executa.
void main() {
  const t = Strings(AppLanguage.ptBr);

  const esquerda = WindowZone(cols: 2, rows: 1, col: 0, row: 0);
  const direita = WindowZone(cols: 2, rows: 1, col: 1, row: 0);

  List<AutomationStep> reuniao() => [
        AutomationStep.launch(
            appName: 'Teams', path: r'C:\atalhos\Teams.lnk', zone: esquerda),
        AutomationStep.launch(
            appName: 'OneNote', path: r'C:\atalhos\OneNote.lnk', zone: direita),
        AutomationStep.media(action: 'mute'),
        AutomationStep.brightness(level: 80),
      ];

  List<AutomationStep> fimDoExpediente() => [
        AutomationStep.close(processName: 'slack'),
        AutomationStep.close(processName: 'outlook'),
        AutomationStep.brightness(level: 0),
        AutomationStep.power(action: 'suspend'),
      ];

  group('o que atravessa a rede', () {
    test('um passo só leva os campos do próprio tipo', () {
      // Um `level: null` num passo de mídia não é inofensivo: o agente é escrito
      // em Rust, e o `serde` recusa a mensagem inteira por causa dele. O passo
      // falharia sem motivo aparente, e o motivo estaria aqui.
      expect(
        AutomationStep.media(action: 'mute').toJson(),
        {'kind': 'media', 'action': 'mute'},
      );
      expect(
        AutomationStep.close(processName: 'slack').toJson(),
        {'kind': 'close', 'name': 'slack'},
      );
      expect(
        AutomationStep.brightness(level: 80).toJson(),
        {'kind': 'brightness', 'level': 80},
      );
      expect(
        AutomationStep.power(action: 'suspend').toJson(),
        {'kind': 'power', 'action': 'suspend'},
      );
    });

    test('abrir um programa manda o caminho, a zona e a espera', () {
      final json = AutomationStep.launch(
        appName: 'Teams',
        path: r'C:\atalhos\Teams.lnk',
        zone: esquerda,
      ).toJson();

      // `id` e não `path`: é o nome do campo no servidor e no agente, e o app é
      // o único lugar onde ele se chama outra coisa.
      expect(json['id'], r'C:\atalhos\Teams.lnk');
      expect(json['zone'], esquerda.toJson());
      // A espera vem por padrão: abrir e mandar a próxima coisa no instante
      // seguinte é o defeito clássico deste recurso.
      expect(json['wait_ms'], 1500);
      // O nome fica no app: quem abre o programa é o caminho.
      expect(json.containsKey('appName'), isFalse);
    });

    test('espera zero não vira campo', () {
      // Pedir ao computador uma pausa de duração nenhuma é pedir nada, com
      // peso. `comEspera(null)` é como o editor grava "sem espera".
      final passo =
          AutomationStep.media(action: 'mute').comEspera(null).toJson();
      expect(passo.containsKey('wait_ms'), isFalse);
    });

    test('a automação inteira preserva a ordem na ida e na volta', () {
      // Numa automação a ordem *é* o recurso: fechar o Outlook depois de
      // suspender não fecha coisa nenhuma.
      final original = Automation(
        id: 'u-1',
        name: 'Fim do expediente',
        icon: 'bedtime',
        steps: fimDoExpediente(),
        deviceId: 'dev-1',
      );
      final volta =
          Automation.fromJson({...original.toJson(), 'id': original.id});

      expect(volta.name, 'Fim do expediente');
      expect(volta.icon, 'bedtime');
      expect(volta.deviceId, 'dev-1');
      expect(
        volta.steps.map((s) => s.kind).toList(),
        ['close', 'close', 'brightness', 'power'],
      );
      expect(volta.steps[0].processName, 'slack');
      expect(volta.steps[1].processName, 'outlook');
      expect(volta.steps[3].action, 'suspend');
    });

    test('o modo reunião volta do servidor com as zonas intactas', () {
      // Zonas trocadas de lugar abrem tudo, posicionam tudo, e deixam o Teams
      // onde deveria estar o OneNote — um defeito que não parece defeito.
      final volta = Automation.fromJson({
        ...Automation(id: '', name: 'Modo reunião', steps: reuniao()).toJson(),
        'id': 'u-2',
      });
      expect(volta.steps[0].zone, esquerda);
      expect(volta.steps[1].zone, direita);
      expect(volta.steps[0].waitMs, 1500);
    });

    test('o identificador não viaja no corpo', () {
      // Quem gera o `id` é o servidor, e ele nunca muda. Mandá-lo de volta
      // abriria a porta para o app tentar escolher o próprio identificador.
      final json = Automation(id: 'u-3', name: 'X', steps: reuniao()).toJson();
      expect(json.containsKey('id'), isFalse);
    });
  });

  group('o que a tela precisa saber', () {
    test('fechar programa e mexer na energia pedem confirmação', () {
      // Fechar pode perder o que não foi salvo; suspender tira a máquina do ar.
      // Nenhum dos dois tem "voltar atrás" a um toque de distância.
      expect(
        Automation(id: '', name: 'Fim', steps: fimDoExpediente()).hasDestructive,
        isTrue,
      );
      // E o resto não pede: confirmar toda automação faria o recurso de um
      // toque custar dois, que é o oposto do que ele existe para fazer.
      expect(
        Automation(id: '', name: 'Reunião', steps: reuniao()).hasDestructive,
        isFalse,
      );
    });

    test('a barra só mostra as automações deste computador', () {
      // A barra flutua sobre a imagem de uma máquina. Um botão ali que agisse
      // noutra seria pior que botão nenhum: nada do que a pessoa está vendo
      // mudaria, e não haveria como saber por quê.
      final solta = Automation(id: '', name: 'Vale em todos', steps: reuniao());
      expect(solta.appliesTo('dev-a'), isTrue);
      expect(solta.appliesTo('dev-b'), isTrue);

      final presa = Automation(
        id: '',
        name: 'Só no A',
        steps: reuniao(),
        deviceId: 'dev-a',
      );
      expect(presa.appliesTo('dev-a'), isTrue);
      expect(presa.appliesTo('dev-b'), isFalse);
    });

    test('cada passo se lê sem consultar o servidor', () {
      final passos = reuniao();
      expect(passos[0].describe(t), 'Abrir Teams');
      expect(passos[2].describe(t), 'Silenciar');
      expect(passos[3].describe(t), 'Brilho em 80%');
      expect(fimDoExpediente()[0].describe(t), 'Fechar slack');
    });

    test('um passo que voltou do servidor ainda mostra o nome do programa', () {
      // O nome não é gravado: seria uma segunda cópia de algo que já está no
      // caminho, e as duas poderiam discordar. Ele é recomposto na leitura —
      // sem isso, reabrir o app trocaria a lista por uma coluna de caminhos do
      // Windows.
      final passo = AutomationStep.fromJson({
        'kind': 'launch',
        'id': r'C:\Program Files\Microsoft Teams.lnk',
      });
      expect(passo.appName, 'Microsoft Teams');
      expect(passo.describe(t), 'Abrir Microsoft Teams');
    });

    test('um atalho de teclado se lê a partir das próprias teclas', () {
      final passo = AutomationStep.input(
        keys: const <String, dynamic>{
          'kind': 'key_combo',
          'modifiers': ['ctrl'],
          'key': 's',
        },
      );
      expect(passo.describe(t), 'Teclas: Ctrl+S');
    });

    test('dois passos iguais são objetos distintos', () {
      // A lista do editor se arrasta, e a chave de cada linha é a identidade do
      // objeto. Com construtores `const`, "baixar o volume duas vezes" viraria
      // o mesmo objeto duas vezes — duas chaves iguais na mesma lista derrubam
      // a tela.
      final a = AutomationStep.media(action: 'volume_down');
      final b = AutomationStep.media(action: 'volume_down');
      expect(identical(a, b), isFalse);
    });
  });

  group('resultado de uma execução', () {
    test('um aviso vem com o passo tendo dado certo', () {
      // "A janela abriu mas não foi para o lugar pedido" não é falha. Esconder
      // não ajudaria: a pessoa vê o Teams no meio da tela e precisa saber que
      // isso foi o esperado dado o que aconteceu.
      final r = StepResult.fromJson({
        'index': 0,
        'ok': true,
        'error': 'não achei a janela para posicionar',
      });
      expect(r.ok, isTrue);
      expect(r.error, isNotNull);
    });

    test('o passo é identificado pelo índice', () {
      // Dois passos podem ser idênticos, e dizer "baixar o volume falhou" não
      // diria qual dos dois.
      final r = StepResult.fromJson({'index': 3, 'ok': false, 'error': 'x'});
      expect(r.index, 3);
      expect(r.ok, isFalse);
    });

    test('um passo sem `error` é aceito', () {
      // O agente omite o campo quando não há motivo. Exigi-lo faria a resposta
      // inteira falhar numa automação que rodou e deu certo.
      final r = StepResult.fromJson({'index': 1, 'ok': true});
      expect(r.error, isNull);
    });
  });

  group('os comandos que o computador conhece', () {
    test('energia usa `suspend`, e não `sleep`', () {
      // `sleep` é o nome corrente em inglês, e é o errado: o agente chama de
      // `suspend`. Escrever o outro faria o passo falhar só no computador, no
      // fim da sequência.
      expect(AutomationStep.powerActions, contains('suspend'));
      expect(AutomationStep.powerActions, isNot(contains('sleep')));
    });

    test('todo comando de mídia e de energia tem rótulo', () {
      // Um comando sem tradução apareceria na tela com o nome do protocolo.
      for (final a in AutomationStep.mediaActions) {
        expect(t.mediaLabel(a), isNot(a), reason: a);
      }
      for (final a in AutomationStep.powerActions) {
        expect(t.powerLabel(a), isNot(a), reason: a);
      }
    });
  });
}
