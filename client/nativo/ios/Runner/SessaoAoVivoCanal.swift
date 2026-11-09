// O lado do app da Live Activity: o canal `deskside/sessao`, por onde o Dart
// diz "começou", "mudou" e "acabou" (ver `client/lib/services/sessao_ao_vivo.dart`).
//
// Registrado em `AppDelegate.swift` por `scripts/preparar-ios.sh`, logo
// depois do `GeneratedPluginRegistrant`, porque a pasta `ios/` é gerada no
// build e não fica no repositório.
//
// Tudo é opcional: sem permissão (a pessoa desligou as Live Activities em
// Ajustes) ou num iOS antigo, os pedidos não fazem nada, e a sessão de
// controle segue igual.

import ActivityKit
import Flutter
import Foundation

enum SessaoAoVivoCanal {
    static func registrar(com registro: FlutterPluginRegistry) {
        guard let registrador = registro.registrar(forPlugin: "SessaoAoVivoCanal") else {
            return
        }
        let canal = FlutterMethodChannel(
            name: "deskside/sessao",
            binaryMessenger: registrador.messenger()
        )
        canal.setMethodCallHandler { chamada, responder in
            guard #available(iOS 16.2, *) else {
                responder(nil)
                return
            }
            let args = chamada.arguments as? [String: Any] ?? [:]
            switch chamada.method {
            case "iniciar":
                Sessoes.iniciar(
                    computador: args["computador"] as? String ?? "",
                    direto: args["direto"] as? Bool ?? true,
                    ms: args["ms"] as? Int
                )
            case "atualizar":
                Sessoes.atualizar(direto: args["direto"] as? Bool ?? true, ms: args["ms"] as? Int)
            case "encerrar":
                Sessoes.encerrar()
            default:
                responder(FlutterMethodNotImplemented)
                return
            }
            responder(nil)
        }
    }
}

@available(iOS 16.2, *)
private enum Sessoes {
    static var atual: Activity<SessaoAtributos>?

    static func iniciar(computador: String, direto: Bool, ms: Int?) {
        guard ActivityAuthorizationInfo().areActivitiesEnabled else { return }
        encerrar()
        let estado = SessaoAtributos.ContentState(direto: direto, ms: ms)
        atual = try? Activity.request(
            attributes: SessaoAtributos(computador: computador, desde: Date()),
            content: ActivityContent(state: estado, staleDate: nil),
            pushType: nil
        )
    }

    static func atualizar(direto: Bool, ms: Int?) {
        guard let atividade = atual else { return }
        let estado = SessaoAtributos.ContentState(direto: direto, ms: ms)
        Task { await atividade.update(ActivityContent(state: estado, staleDate: nil)) }
    }

    static func encerrar() {
        // Todas, e não só a guardada: uma atividade de uma sessão anterior
        // (o app fechado no meio) não pode ficar presa na tela bloqueada.
        for atividade in Activity<SessaoAtributos>.activities {
            Task { await atividade.end(nil, dismissalPolicy: .immediate) }
        }
        atual = nil
    }
}
