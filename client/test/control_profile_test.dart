import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:remoteone_client/l10n/strings.dart';
import 'package:remoteone_client/models/control_profile.dart';
import 'package:remoteone_client/widgets/profile_bar.dart';

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
}
