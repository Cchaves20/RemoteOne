import 'package:flutter_test/flutter_test.dart';
import 'package:remoteone_client/main.dart';

void main() {
  testWidgets('tela inicial mostra estado sem pareamento', (tester) async {
    await tester.pumpWidget(const RemoteOneApp());

    expect(find.text('RemoteOne'), findsOneWidget);
    expect(find.text('Nenhum computador pareado'), findsOneWidget);
    expect(find.text('Parear computador'), findsOneWidget);
  });
}
