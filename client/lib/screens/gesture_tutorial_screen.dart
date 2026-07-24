import 'package:flutter/material.dart';

import '../services/app_state.dart';

/// Ensina os gestos de controle. Aparece na primeira vez que se abre um
/// computador e pode ser revisto em Configurações → Ajuda.
class GestureTutorialScreen extends StatelessWidget {
  const GestureTutorialScreen({super.key, required this.state});

  final AppState state;

  static const _icons = [
    Icons.touch_app,
    Icons.swipe,
    Icons.ads_click,
    Icons.pinch,
    Icons.zoom_in,
    Icons.keyboard,
  ];

  @override
  Widget build(BuildContext context) {
    final t = state.t;
    final gestures = t.gestures;
    return Scaffold(
      appBar: AppBar(title: Text(t.howToControlTitle)),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Text(t.gestureIntro),
          const SizedBox(height: 12),
          for (var i = 0; i < gestures.length; i++)
            Card(
              child: ListTile(
                leading: Icon(_icons[i], size: 32),
                title: Text(gestures[i].$1),
                subtitle: Text(gestures[i].$2),
              ),
            ),
          const SizedBox(height: 16),
          FilledButton(
            onPressed: () => Navigator.of(context).maybePop(),
            child: Text(t.gestureGotIt),
          ),
        ],
      ),
    );
  }
}
