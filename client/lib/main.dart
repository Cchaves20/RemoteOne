import 'package:flutter/material.dart';

void main() {
  runApp(const RemoteOneApp());
}

class RemoteOneApp extends StatelessWidget {
  const RemoteOneApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'RemoteOne',
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.indigo),
        useMaterial3: true,
      ),
      home: const HomeScreen(),
    );
  }
}

/// Tela inicial. O fluxo de pareamento (informar o código exibido pelo
/// computador) entra aqui na Etapa 5.
class HomeScreen extends StatelessWidget {
  const HomeScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('RemoteOne')),
      body: const Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.devices_other, size: 72),
            SizedBox(height: 16),
            Text('Nenhum computador pareado'),
          ],
        ),
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: null,
        icon: const Icon(Icons.add_link),
        label: const Text('Parear computador'),
      ),
    );
  }
}
