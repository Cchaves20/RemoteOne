import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:deskside_client/l10n/strings.dart';
import 'package:deskside_client/models/control_profile.dart';
import 'package:deskside_client/widgets/profile_bar.dart';

/// Teclas com nome próprio aceitas pelo computador. Esta lista é a mesma de
/// `backend/app/input.py` e `agent/src/input.rs` — está repetida aqui de
/// propósito: é ela que faz um perfil novo com um nome inventado ("ctrl+del")
/// falhar no teste em vez de falhar calado no bolso do usuário.
const _teclasComNome = {
  'enter', 'backspace', 'tab', 'escape', 'space', 'delete',
  'up', 'down', 'left', 'right', 'home', 'end', 'page_up', 'page_down',
  'f1', 'f2', 'f3', 'f4', 'f5', 'f6', 'f7', 'f8', 'f9', 'f10', 'f11', 'f12',
};

const _modificadores = {'ctrl', 'alt', 'shift', 'meta'};

/// PNG de 1x1 transparente: basta para o widget montar uma imagem de verdade.
final Uint8List _png = base64Decode(
  'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==',
);

void main() {
  const t = Strings(AppLanguage.ptBr);

  group('ProfileAction', () {
    test('uma letra vai como texto digitado', () {
      final a = ProfileAction.letter(
        icon: Icons.fullscreen,
        shortcut: 'F',
        label: (t) => t.actionFullscreen,
        text: 'f',
      );
      expect(a.input, {'kind': 'key_text', 'text': 'f'});
    });

    test('tecla com nome vai como key_press', () {
      final a = ProfileAction.special(
        icon: Icons.refresh,
        shortcut: 'F5',
        label: (t) => t.actionReload,
        key: 'f5',
      );
      expect(a.input, {'kind': 'key_press', 'key': 'f5'});
    });

    test('com modificador vira atalho', () {
      final a = ProfileAction.combo(
        icon: Icons.save,
        shortcut: 'Ctrl+S',
        label: (t) => t.save,
        modifiers: ['ctrl'],
        key: 's',
      );
      expect(a.input, {
        'kind': 'key_combo',
        'modifiers': ['ctrl'],
        'key': 's',
      });
    });
  });

  group('perfis que vêm com o app', () {
    test('cada um tem id único, nome e pelo menos um atalho', () {
      final ids = <String>{};
      for (final p in ControlProfile.builtIn) {
        expect(ids.add(p.id), isTrue, reason: 'id repetido: ${p.id}');
        expect(p.name(t), isNotEmpty);
        expect(p.actions, isNotEmpty);
      }
      expect(ControlProfile.builtIn.length, greaterThanOrEqualTo(3));
    });

    test('toda tecla mandada existe do outro lado', () {
      for (final p in ControlProfile.builtIn) {
        for (final a in p.actions) {
          final input = a.input;
          final onde = '${p.id}/${a.shortcut}';
          expect(a.label(t), isNotEmpty, reason: onde);
          final kind = input['kind'];
          if (kind == 'key_text') {
            // Texto digitado é livre, mas o botão manda uma tecla só.
            expect(input['text'], hasLength(1), reason: onde);
          } else if (kind == 'key_press') {
            expect(_teclasComNome, contains(input['key']), reason: onde);
          } else if (kind == 'key_combo') {
            final mods = (input['modifiers'] as List).cast<String>();
            expect(mods, isNotEmpty, reason: onde);
            expect(mods.every(_modificadores.contains), isTrue, reason: onde);
            // O computador resolve um caractere solto como ele mesmo; mais de
            // um só funciona se for um nome que ele conheça.
            final key = input['key'] as String;
            expect(key.length == 1 || _teclasComNome.contains(key), isTrue,
                reason: '$onde: tecla "$key" não existe no computador');
          } else {
            fail('$onde: tipo de ação desconhecido ($kind)');
          }
        }
      }
    });

    test('cada programa pertence a um perfil só', () {
      // Dois perfis reivindicando o mesmo executável fariam o ícone real
      // aparecer num lugar imprevisível - o primeiro da lista venceria.
      final vistos = <String, String>{};
      for (final p in ControlProfile.builtIn) {
        for (final exe in p.executables) {
          expect(exe, exe.toLowerCase(), reason: 'executável em maiúsculas');
          expect(exe, contains('.'), reason: '$exe: falta a extensão');
          final dono = vistos[exe];
          expect(dono, isNull, reason: '$exe está em $dono e em ${p.id}');
          vistos[exe] = p.id;
        }
      }
    });

    test('acha o perfil pelo programa, sem ligar para a caixa', () {
      expect(ControlProfile.forExecutable('POWERPNT.EXE')?.id, 'apresentacao');
      expect(ControlProfile.forExecutable('applemusic.exe')?.id, 'video');
      expect(ControlProfile.forExecutable('chrome.exe')?.id, 'navegador');
      expect(ControlProfile.forExecutable('winword.exe')?.id, 'trabalho');
      expect(ControlProfile.forExecutable('explorer.exe')?.id, 'sistema');
    });

    test('programa desconhecido não vira perfil nenhum', () {
      // Sem isto, um jogo em primeiro plano trocaria o ícone de algum perfil.
      expect(ControlProfile.forExecutable('jogo-qualquer.exe'), isNull);
      expect(ControlProfile.forExecutable(''), isNull);
    });

    test('esquece um perfil que não existe mais', () {
      expect(ControlProfile.byId('perfil-de-uma-versao-antiga'), isNull);
      expect(ControlProfile.byId(null), isNull);
      expect(ControlProfile.byId('sistema')?.id, 'sistema');
    });
  });

  group('ProfileBar', () {
    /// Um perfil pequeno e previsível: o teste é sobre a barra, não sobre
    /// quais atalhos vêm com o app.
    final perfis = [
      ControlProfile(
        id: 'a',
        icon: Icons.movie,
        name: (t) => 'Perfil A',
        actions: [
          ProfileAction.special(
            icon: Icons.play_arrow,
            shortcut: 'Space',
            label: (t) => 'Tocar',
            key: 'space',
          ),
        ],
      ),
      ControlProfile(
        id: 'b',
        icon: Icons.public,
        name: (t) => 'Perfil B',
        actions: [
          ProfileAction.combo(
            icon: Icons.refresh,
            shortcut: 'Ctrl+R',
            label: (t) => 'Atualizar',
            modifiers: ['ctrl'],
            key: 'r',
          ),
        ],
      ),
    ];

    Widget montar({
      required bool vertical,
      ControlProfile? selected,
      ValueChanged<ControlProfile?>? onSelect,
      ValueChanged<ProfileAction>? onAction,
      Map<String, Uint8List> icones = const {},
    }) {
      return MaterialApp(
        home: Scaffold(
          body: SizedBox(
            width: vertical ? 800 : 400,
            height: vertical ? 400 : 800,
            child: Stack(
              children: [
                ProfileBar(
                  vertical: vertical,
                  area: vertical
                      ? const Size(800, 400)
                      : const Size(400, 800),
                  profiles: perfis,
                  selected: selected,
                  appIcons: icones,
                  strings: t,
                  onSelect: onSelect ?? (_) {},
                  onAction: onAction ?? (_) {},
                ),
              ],
            ),
          ),
        ),
      );
    }

    testWidgets('fechada, mostra só os perfis', (tester) async {
      await tester.pumpWidget(montar(vertical: false));
      await tester.pumpAndSettle();

      expect(find.byIcon(Icons.movie), findsOneWidget);
      expect(find.byIcon(Icons.public), findsOneWidget);
      // Nenhum atalho à vista enquanto não se escolhe um perfil.
      expect(find.text('Space'), findsNothing);
    });

    testWidgets('tocar num perfil avisa quem escolheu', (tester) async {
      ControlProfile? escolhido;
      await tester.pumpWidget(
        montar(vertical: false, onSelect: (p) => escolhido = p),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.byIcon(Icons.movie));
      expect(escolhido?.id, 'a');
    });

    testWidgets('tocar no perfil aceso fecha a pista de atalhos',
        (tester) async {
      ControlProfile? escolhido = perfis[0];
      await tester.pumpWidget(
        montar(
          vertical: false,
          selected: perfis[0],
          onSelect: (p) => escolhido = p,
        ),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.byIcon(Icons.movie));
      expect(escolhido, isNull);
    });

    testWidgets('com um perfil aceso, os atalhos aparecem e disparam',
        (tester) async {
      ProfileAction? disparado;
      await tester.pumpWidget(
        montar(
          vertical: false,
          selected: perfis[0],
          onAction: (a) => disparado = a,
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('Space'), findsOneWidget);
      await tester.tap(find.text('Space'));
      expect(disparado?.input, {'kind': 'key_press', 'key': 'space'});
    });

    testWidgets('mostra o ícone real do programa quando ele chega',
        (tester) async {
      await tester.pumpWidget(montar(vertical: false, icones: {'a': _png}));
      await tester.pumpAndSettle();

      // O desenho genérico do perfil 'a' deu lugar à imagem do programa; o
      // outro perfil, sem ícone real, continua desenhado.
      expect(find.byType(Image), findsOneWidget);
      expect(find.byIcon(Icons.movie), findsNothing);
      expect(find.byIcon(Icons.public), findsOneWidget);
    });

    testWidgets('cabe nas duas orientações', (tester) async {
      // Um layout que estoura vira exceção no teste — é o que se está medindo
      // aqui, já que a barra muda de eixo conforme o celular vira.
      for (final vertical in [true, false]) {
        await tester.pumpWidget(
          montar(vertical: vertical, selected: perfis[1]),
        );
        await tester.pumpAndSettle();
        expect(find.text('Ctrl+R'), findsOneWidget);
      }
    });
  });

  group('perfis criados pelo usuário', () {
    Map<String, dynamic> json({
      String id = 'u-1',
      String nome = 'Estudo',
      String icone = 'school',
      List<Map<String, String>> apps = const [],
      List<String> devices = const [],
    }) =>
        {
          'id': id,
          'name': nome,
          'icon': icone,
          'apps': apps,
          'devices': devices,
        };

    test('cada programa vira uma ação de abrir', () {
      final p = ControlProfile.fromJson(json(apps: [
        {'name': 'Spotify', 'path': r'C:\Spotify.lnk'},
        {'name': 'Chrome', 'path': r'C:\Chrome.lnk'},
      ]));
      expect(p.custom, isTrue);
      expect(p.actions.length, 2);
      expect(p.actions.first.isLaunch, isTrue);
      expect(p.actions.first.appName, 'Spotify');
      expect(p.actions.first.appPath, r'C:\Spotify.lnk');
      // O nome do programa não passa pelo sistema de idiomas.
      expect(p.actions.first.label(t), 'Spotify');
    });

    test('ação de teclado e ação de abrir não se confundem', () {
      // É este campo que decide se a tela manda teclas ou pede para abrir um
      // programa. Se os dois parecessem iguais, um perfil do usuário mandaria
      // um `input` sem tecla nenhuma para o computador.
      final abrir = ProfileAction.launch(appName: 'Spotify', appPath: 'x.lnk');
      final tecla = ProfileAction.special(
        icon: Icons.play_arrow,
        shortcut: 'Espaço',
        label: (t) => t.mediaPlayPause,
        key: 'space',
      );
      expect(abrir.isLaunch, isTrue);
      expect(tecla.isLaunch, isFalse);
      expect(tecla.appPath, isNull);
    });

    test('perfil sem programa nenhum continua válido', () {
      // Alguém que criou e ainda não escolheu nada. Aparecer vazio é melhor do
      // que sumir sem explicação.
      final p = ControlProfile.fromJson(json());
      expect(p.actions, isEmpty);
      expect(p.rawName, 'Estudo');
    });

    test('ícone desconhecido cai no genérico em vez de sumir', () {
      // Uma versão mais nova do app pode ter guardado uma chave que esta não
      // conhece.
      expect(profileIcon('nao_existe'), profileIcon('tune'));
      expect(profileIcon(null), Icons.tune);
      // E toda chave da paleta volta a ser ela mesma.
      for (final e in profileIcons.entries) {
        expect(profileIconKey(e.value), e.key);
      }
    });

    test('ida e volta pelo JSON preserva o que importa', () {
      final p = ControlProfile.fromJson(json(
        apps: [
          {'name': 'Spotify', 'path': r'C:\Spotify.lnk'}
        ],
        devices: ['dev-a', 'dev-b'],
      ));
      final volta = p.toJson();
      expect(volta['name'], 'Estudo');
      expect(volta['icon'], 'school');
      expect(volta['devices'], ['dev-a', 'dev-b']);
      expect(volta['apps'], [
        {'name': 'Spotify', 'path': r'C:\Spotify.lnk'}
      ]);
      // O `id` fica de fora: quem o define é o servidor, e ele nunca muda.
      expect(volta.containsKey('id'), isFalse);
    });

    test('perfil sem computador vale para todos', () {
      final p = ControlProfile.fromJson(json());
      expect(p.appliesTo('qualquer-um'), isTrue);
    });

    test('perfil com computador só aparece nele', () {
      final p = ControlProfile.fromJson(json(devices: ['dev-a']));
      expect(p.appliesTo('dev-a'), isTrue);
      expect(p.appliesTo('dev-b'), isFalse);
    });
  });

  group('ordem da barra', () {
    ControlProfile custom(String id, {List<String> devices = const []}) =>
        ControlProfile.fromJson({
          'id': id,
          'name': id,
          'icon': 'tune',
          'apps': const [],
          'devices': devices,
        });

    test('a fila segue a ordem guardada', () {
      final fila = ControlProfile.arrange(
        [custom('u-1')],
        ['u-1', 'sistema'],
        'dev-a',
      );
      expect(fila.first.id, 'u-1');
      expect(fila[1].id, 'sistema');
    });

    test('o que a ordem não menciona vai para o fim, não some', () {
      // É o que faz um perfil criado noutro aparelho - ou trazido por uma
      // versão nova do app - aparecer, em vez de desaparecer por não estar
      // numa lista que foi salva antes de ele existir.
      final fila = ControlProfile.arrange([custom('u-novo')], ['video'], 'dev-a');
      expect(fila.first.id, 'video');
      expect(fila.map((p) => p.id), contains('u-novo'));
      expect(fila.length, ControlProfile.builtIn.length + 1);
    });

    test('ordem vazia mantém os de fábrica na ordem natural', () {
      final fila = ControlProfile.arrange(const [], const [], 'dev-a');
      expect(fila.map((p) => p.id).toList(),
          ControlProfile.builtIn.map((p) => p.id).toList());
    });

    test('a barra de um computador não mostra perfil de outro', () {
      final fila = ControlProfile.arrange(
        [custom('u-so-do-a', devices: ['dev-a'])],
        const [],
        'dev-b',
      );
      expect(fila.map((p) => p.id), isNot(contains('u-so-do-a')));
    });

    test('sem computador informado, nada é filtrado', () {
      // É o que o editor usa: lá se arruma a coleção inteira, e esconder um
      // perfil por causa da máquina atual faria a pessoa achar que ele sumiu.
      final fila = ControlProfile.arrange(
        [custom('u-so-do-a', devices: ['dev-a'])],
        const [],
      );
      expect(fila.map((p) => p.id), contains('u-so-do-a'));
    });

    test('byId acha entre os perfis dados, não só entre os de fábrica', () {
      final meu = custom('u-1');
      expect(ControlProfile.byId('u-1'), isNull);
      expect(ControlProfile.byId('u-1', [meu])?.id, 'u-1');
      expect(ControlProfile.byId(null), isNull);
    });

    test('um id que não existe mais não derruba nada', () {
      // Perfil apagado pelo usuário, ou tirado por uma versão nova do app.
      expect(ControlProfile.byId('u-apagado', const []), isNull);
    });
  });
}
