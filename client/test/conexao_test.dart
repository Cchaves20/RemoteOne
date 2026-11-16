import 'package:deskside_client/services/video_session.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';

void main() {
  StatsReport rel(String id, String tipo, Map<String, dynamic> v) =>
      StatsReport(id, tipo, 0, v);

  test('par direto: os ms da ida e volta', () {
    final c = conexaoDasEstatisticas([
      rel('p1', 'candidate-pair', {'state': 'in-progress', 'nominated': false}),
      rel('p2', 'candidate-pair', {
        'state': 'succeeded',
        'nominated': true,
        'currentRoundTripTime': 0.018,
        'localCandidateId': 'l1',
        'remoteCandidateId': 'r1',
      }),
      rel('l1', 'local-candidate', {'candidateType': 'srflx'}),
      rel('r1', 'remote-candidate', {'candidateType': 'host'}),
    ]);
    expect(c!.direta, isTrue);
    expect(c.idaEVoltaMs, 18);
  });

  test('par pelo relay é marcado como não direto', () {
    final c = conexaoDasEstatisticas([
      rel('p', 'candidate-pair', {
        'state': 'succeeded',
        'nominated': true,
        'currentRoundTripTime': 0.21,
        'localCandidateId': 'l',
        'remoteCandidateId': 'r',
      }),
      rel('l', 'local-candidate', {'candidateType': 'relay'}),
      rel('r', 'remote-candidate', {'candidateType': 'srflx'}),
    ]);
    expect(c!.direta, isFalse);
    expect(c.idaEVoltaMs, 210);
  });

  test('sem par escolhido ainda, não há o que mostrar', () {
    expect(
      conexaoDasEstatisticas([
        rel('p', 'candidate-pair', {'state': 'in-progress'}),
      ]),
      isNull,
    );
  });
}
