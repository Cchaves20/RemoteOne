// O desenho da sessão ao vivo: na tela bloqueada e na Ilha Dinâmica.
//
// O app inicia, atualiza e encerra (ver `Runner/SessaoAoVivoCanal.swift`);
// aqui é só o desenho. Tocar em qualquer parte abre o app de volta na tela
// remota.

import ActivityKit
import SwiftUI
import WidgetKit

struct SessaoAoVivoWidget: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: SessaoAtributos.self) { contexto in
            TelaBloqueada(contexto: contexto)
                .activityBackgroundTint(Color(uiColor: UIColor(rgb: 0x121530)))
                .activitySystemActionForegroundColor(.white)
        } dynamicIsland: { contexto in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    MonitorPequeno(ligado: true, largura: 34)
                        .padding(.leading, 4)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    Text(contexto.attributes.desde, style: .timer)
                        .font(.system(.title3, design: .monospaced))
                        .foregroundStyle(cianoClaro)
                        .frame(maxWidth: 90)
                        .multilineTextAlignment(.trailing)
                }
                DynamicIslandExpandedRegion(.center) {
                    Text(contexto.attributes.computador)
                        .font(.headline)
                        .lineLimit(1)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    Linha(estado: contexto.state)
                }
            } compactLeading: {
                MonitorPequeno(ligado: true, largura: 22)
            } compactTrailing: {
                Text(contexto.attributes.desde, style: .timer)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(cianoClaro)
                    .frame(maxWidth: 52)
            } minimal: {
                MonitorPequeno(ligado: true, largura: 18)
            }
            .widgetURL(URL(string: "deskside://sessao"))
        }
    }
}

private let cianoClaro = Color(uiColor: UIColor(rgb: 0x67E8F9))

/// "Controlando · direto · 18 ms" (ou "relay", em âmbar).
private struct Linha: View {
    let estado: SessaoAtributos.ContentState

    var body: some View {
        let cor = estado.direto
            ? cianoClaro
            : Color(uiColor: UIColor(rgb: 0xFBBF24))
        HStack(spacing: 6) {
            Text("Controlando").foregroundStyle(.secondary)
            Text("·").foregroundStyle(.secondary)
            Text(estado.direto ? "direto" : "relay").foregroundStyle(cor)
            if let ms = estado.ms {
                Text("· \(ms) ms")
                    .font(.system(.footnote, design: .monospaced))
                    .foregroundStyle(cor)
            }
        }
        .font(.footnote)
    }
}

private struct TelaBloqueada: View {
    let contexto: ActivityViewContext<SessaoAtributos>

    var body: some View {
        HStack(spacing: 12) {
            MonitorPequeno(ligado: true, largura: 46)
            VStack(alignment: .leading, spacing: 3) {
                Text(contexto.attributes.computador)
                    .font(.headline)
                    .foregroundStyle(.white)
                    .lineLimit(1)
                Linha(estado: contexto.state)
            }
            Spacer(minLength: 8)
            Text(contexto.attributes.desde, style: .timer)
                .font(.system(.title2, design: .monospaced))
                .foregroundStyle(.white)
                .frame(maxWidth: 96)
                .multilineTextAlignment(.trailing)
        }
        .padding(16)
    }
}
