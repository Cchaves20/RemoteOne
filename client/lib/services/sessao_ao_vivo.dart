import 'dart:io';

import 'package:flutter/services.dart';

/// A sessão de controle na tela bloqueada e na Ilha Dinâmica do iPhone (Live
/// Activity): o nome do computador, há quanto tempo, e se a conexão é direta.
///
/// O desenho mora na extensão do widget (`nativo/ios/DesksideWidget/
/// SessaoAoVivoWidget.swift`) e o pedido ao iOS no app
/// (`nativo/ios/Runner/SessaoAoVivoCanal.swift`); daqui só se diz começou,
/// mudou e acabou.
///
/// Tudo é opcional e silencioso: no Android, num iOS sem Live Activities, ou
/// com elas desligadas em Ajustes, as chamadas não fazem nada — a sessão de
/// controle não pode depender de um enfeite da tela bloqueada.
class SessaoAoVivo {
  SessaoAoVivo._();

  static const _canal = MethodChannel('deskside/sessao');
  static bool _ativa = false;

  static Future<void> iniciar(String computador, {bool direto = true, int? ms}) =>
      _chamar('iniciar', {'computador': computador, 'direto': direto, 'ms': ms})
          .then((_) => _ativa = true);

  static Future<void> atualizar({required bool direto, int? ms}) async {
    if (!_ativa) return;
    await _chamar('atualizar', {'direto': direto, 'ms': ms});
  }

  static Future<void> encerrar() async {
    if (!_ativa) return;
    _ativa = false;
    await _chamar('encerrar', const {});
  }

  static Future<void> _chamar(String metodo, Map<String, Object?> args) async {
    if (!Platform.isIOS) return;
    try {
      await _canal.invokeMethod<void>(metodo, args);
    } catch (_) {
      // Sem o canal (build sem a extensão) ou recusado pelo iOS: segue sem.
    }
  }
}
