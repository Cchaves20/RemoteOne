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
private let ambar = Color(uiColor: UIColor(rgb: 0xFBBF24))

/// "direto · 18 ms" (ou "relay", em âmbar).
///
/// Um texto só, numa linha. Em pedaços lado a lado (um `HStack` de `Text`),
/// cada pedaço encolhia e quebrava por conta própria quando faltava largura,
/// e a tela bloqueada mostrava "Con-tro-lando · dire-to · 98 ms" em três
/// linhas. Inteiro, ele encolhe um pouco e, no limite, corta no fim.
private struct Linha: View {
    let estado: SessaoAtributos.ContentState

    private var texto: Text {
        let cor = estado.direto ? cianoClaro : ambar
        let caminho = Text(estado.direto ? "direto" : "relay").foregroundColor(cor)
        guard let ms = estado.ms else { return caminho }
        return caminho
            + Text(" · ").foregroundColor(.secondary)
            + Text("\(ms) ms")
                .font(.system(.footnote, design: .monospaced))
                .foregroundColor(cor)
    }

    var body: some View {
        texto
            .font(.footnote)
            .lineLimit(1)
            .minimumScaleFactor(0.8)
    }
}

private struct TelaBloqueada: View {
    let contexto: ActivityViewContext<SessaoAtributos>

    var body: some View {
        HStack(spacing: 12) {
            MonitorPequeno(ligado: true, largura: 46)
            // Três linhas curtas, cada uma numa linha só: o que é, de quem,
            // e como está a conexão.
            VStack(alignment: .leading, spacing: 2) {
                Text("Controlando")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Text(contexto.attributes.computador)
                    .font(.headline)
                    .foregroundStyle(.white)
                    .lineLimit(1)
                Linha(estado: contexto.state)
            }
            .layoutPriority(1)
            Spacer(minLength: 8)
            // O relógio ocupa toda a largura que lhe derem (é assim o
            // `Text(_:style: .timer)`): largura fixa, para não roubar a do
            // texto ao lado. Cabe "1:02:33"; encolhe se não couber.
            Text(contexto.attributes.desde, style: .timer)
                .font(.system(.title3, design: .monospaced))
                .foregroundStyle(.white)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
                .multilineTextAlignment(.trailing)
                .frame(width: 80, alignment: .trailing)
        }
        .padding(16)
    }
}
