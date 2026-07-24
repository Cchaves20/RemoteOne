import 'package:flutter/material.dart';

/// Ensina os gestos de controle. Aparece na primeira vez que se abre um
/// computador e pode ser revisto em Configurações → Ajuda.
class GestureTutorialScreen extends StatelessWidget {
  const GestureTutorialScreen({super.key});

  static const _gestures = [
    (Icons.touch_app, 'Tocar', 'Leva o cursor ao ponto tocado e dá um clique (botão esquerdo).'),
    (Icons.swipe, 'Arrastar', 'Move o cursor seguindo o seu dedo.'),
    (Icons.ads_click, 'Segurar', 'Clique com o botão direito (menu de contexto).'),
    (Icons.pinch, 'Dois dedos', 'Rola a página para cima e para baixo.'),
    (Icons.zoom_in, 'Botão da lupa', 'Amplia a tela para enxergar melhor. Use + e − para ajustar; toque no X para voltar a controlar.'),
    (Icons.keyboard, 'Botão do teclado', 'Abre o teclado com as teclas especiais (Ctrl, Alt, setas...).'),
  ];

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Como controlar')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          const Text(
            'A tela do computador ocupa o celular inteiro e você controla como '
            'num touchscreen:',
          ),
          const SizedBox(height: 12),
          for (final (icon, title, desc) in _gestures)
            Card(
              child: ListTile(
                leading: Icon(icon, size: 32),
                title: Text(title),
                subtitle: Text(desc),
              ),
            ),
          const SizedBox(height: 16),
          FilledButton(
            onPressed: () => Navigator.of(context).maybePop(),
            child: const Text('Entendi'),
          ),
        ],
      ),
    );
  }
}
