// O widget do Deskside na tela inicial e na tela de bloqueio.
//
// Um computador e até três botões, escolhidos no app em Configurações ›
// Widgets. A escolha mora no servidor (`/api/v1/widget`), que devolve tudo
// pronto para desenhar: o nome do computador, se está online e o nome da
// automação de cada botão. Ver `backend/app/widget.py`.
//
// Os botões rodam sem abrir o app (iOS 17), pela `AcaoDoWidgetIntent` de
// `Comum/DesksideComum.swift`. Este alvo é montado inteiro por
// `scripts/preparar-ios.sh` — a pasta `ios/` não é versionada.
//
// ## O que o widget não sabe
//
// O iOS só deixa o widget se redesenhar de tempos em tempos. A bolinha de
// online é a do último desenho (pedido a cada 15 minutos, e logo depois de um
// toque num botão ou de salvar a tela de widgets no app), não um estado ao
// vivo.

import AppIntents
import SwiftUI
import UIKit
import WidgetKit

// MARK: - Dados

struct BotaoNoWidget: Hashable {
    let tipo: String
    let rotulo: String
    let simbolo: String
    let automacao: String

    init(tipo: String, nomeDaAutomacao: String?, automacao: String) {
        self.tipo = tipo
        self.automacao = automacao
        switch tipo {
        case "apresentacao":
            rotulo = "Apresentação"
            simbolo = "display"
        case "tocar_pausar":
            rotulo = "Tocar/pausar"
            simbolo = "playpause.fill"
        case "suspender":
            rotulo = "Suspender"
            simbolo = "moon.zzz.fill"
        case "volume_mais":
            rotulo = "Volume +"
            simbolo = "speaker.plus.fill"
        case "volume_menos":
            rotulo = "Volume −"
            simbolo = "speaker.minus.fill"
        case "silenciar":
            rotulo = "Silenciar"
            simbolo = "speaker.slash.fill"
        default:
            rotulo = nomeDaAutomacao ?? "Automação"
            simbolo = "bolt.fill"
        }
    }
}

struct EntradaDoWidget: TimelineEntry {
    let date: Date
    let computador: String
    let nome: String
    let online: Bool
    let botoes: [BotaoNoWidget]
    /// Quando não há o que mostrar: sem login, sem computador, sem rede.
    let aviso: String?

    static let exemplo = EntradaDoWidget(
        date: Date(),
        computador: "",
        nome: "Meu computador",
        online: true,
        botoes: [
            BotaoNoWidget(tipo: "apresentacao", nomeDaAutomacao: nil, automacao: ""),
            BotaoNoWidget(tipo: "tocar_pausar", nomeDaAutomacao: nil, automacao: ""),
            BotaoNoWidget(tipo: "automacao", nomeDaAutomacao: "Modo cinema", automacao: ""),
        ],
        aviso: nil
    )

    static func comAviso(_ texto: String) -> EntradaDoWidget {
        EntradaDoWidget(
            date: Date(), computador: "", nome: "", online: false, botoes: [], aviso: texto
        )
    }
}

// MARK: - Linha do tempo

struct Provedor: TimelineProvider {
    func placeholder(in context: Context) -> EntradaDoWidget {
        EntradaDoWidget.exemplo
    }

    func getSnapshot(in context: Context, completion: @escaping (EntradaDoWidget) -> Void) {
        if context.isPreview {
            completion(EntradaDoWidget.exemplo)
            return
        }
        Task {
            completion(await ler())
        }
    }

    func getTimeline(
        in context: Context,
        completion: @escaping (Timeline<EntradaDoWidget>) -> Void
    ) {
        Task {
            let entrada = await ler()
            let proxima = Date().addingTimeInterval(15 * 60)
            completion(Timeline(entries: [entrada], policy: .after(proxima)))
        }
    }

    private func ler() async -> EntradaDoWidget {
        do {
            let dados = try await DesksideAPI.pedir("GET", "/api/v1/widget")
            let json = (try? JSONSerialization.jsonObject(with: dados) as? [String: Any]) ?? [:]
            guard let computador = json["device_id"] as? String else {
                return .comAviso("Pareie um computador no app Deskside.")
            }
            let brutos = (json["botoes"] as? [[String: Any]]) ?? []
            let botoes = brutos.prefix(3).map { b in
                BotaoNoWidget(
                    tipo: (b["tipo"] as? String) ?? "",
                    nomeDaAutomacao: b["automacao_nome"] as? String,
                    automacao: (b["automacao_id"] as? String) ?? ""
                )
            }
            return EntradaDoWidget(
                date: Date(),
                computador: computador,
                nome: (json["device_name"] as? String) ?? computador,
                online: (json["online"] as? Bool) ?? false,
                botoes: Array(botoes),
                aviso: nil
            )
        } catch ErroDoDeskside.semLogin {
            return .comAviso("Abra o Deskside e entre na sua conta.")
        } catch {
            return .comAviso("Sem conexão com o Deskside agora.")
        }
    }
}

// MARK: - Desenho

/// As cores do app (ver `client/lib/theme.dart`), nos dois temas: o widget
/// segue o claro ou o escuro do sistema, como o resto da tela inicial.
enum CoresDeskside {
    static func dinamica(_ escuro: UInt32, _ claro: UInt32) -> Color {
        Color(uiColor: UIColor { t in
            UIColor(rgb: t.userInterfaceStyle == .dark ? escuro : claro)
        })
    }

    static let superficie = dinamica(0x141830, 0xFFFFFF)
    static let tecla = dinamica(0x1D2142, 0xFFFFFF)
    static let teclaSombra = dinamica(0x080A16, 0xC3C7D8)
    static let texto = dinamica(0xEEF0FF, 0x0E1022)
    static let texto2 = dinamica(0xA3A9C9, 0x4A5070)
    static let aoVivo = dinamica(0x22D3EE, 0x0A7C77)
    static let led = Color(uiColor: UIColor(rgb: 0x34D399))
    static let marca = [
        Color(uiColor: UIColor(rgb: 0x7C4DFF)),
        Color(uiColor: UIColor(rgb: 0x4364F7)),
        Color(uiColor: UIColor(rgb: 0x22D3EE)),
    ]
}

extension UIColor {
    convenience init(rgb: UInt32) {
        self.init(
            red: CGFloat((rgb >> 16) & 0xFF) / 255,
            green: CGFloat((rgb >> 8) & 0xFF) / 255,
            blue: CGFloat(rgb & 0xFF) / 255,
            alpha: 1
        )
    }
}

/// O monitor do app em miniatura: tela acesa (borda no degradê e brilho)
/// quando o computador está online, apagada quando não.
struct MonitorPequeno: View {
    let ligado: Bool
    var largura: CGFloat = 26

    var body: some View {
        let forma = RoundedRectangle(cornerRadius: largura * 0.14, style: .continuous)
        VStack(spacing: 1) {
            forma
                .fill(
                    ligado
                        ? AnyShapeStyle(
                            RadialGradient(
                                colors: [
                                    CoresDeskside.marca[0].opacity(0.75),
                                    CoresDeskside.marca[1].opacity(0.35),
                                    Color(uiColor: UIColor(rgb: 0x0F1330)),
                                ],
                                center: UnitPoint(x: 0.25, y: 0.2),
                                startRadius: 0,
                                endRadius: largura
                            ))
                        : AnyShapeStyle(Color(uiColor: UIColor(rgb: 0x0B0E20)))
                )
                .overlay(
                    forma.strokeBorder(
                        ligado
                            ? AnyShapeStyle(
                                LinearGradient(
                                    colors: CoresDeskside.marca,
                                    startPoint: .topLeading,
                                    endPoint: .bottomTrailing))
                            : AnyShapeStyle(Color(uiColor: UIColor(rgb: 0x2E3458))),
                        lineWidth: 1.4)
                )
                .frame(width: largura, height: largura * 0.62)
            Capsule()
                .fill(ligado ? CoresDeskside.led : Color(uiColor: UIColor(rgb: 0x2E3458)))
                .frame(width: largura * 0.3, height: 2)
        }
        .accessibilityHidden(true)
    }
}

struct VistaDoWidget: View {
    @Environment(\.widgetFamily) var familia
    let entrada: EntradaDoWidget

    var body: some View {
        conteudo
            .containerBackground(for: .widget) {
                CoresDeskside.superficie
            }
    }

    @ViewBuilder
    private var conteudo: some View {
        if let aviso = entrada.aviso {
            Text(aviso)
                .font(.caption)
                .foregroundStyle(CoresDeskside.texto2)
                .multilineTextAlignment(.center)
        } else {
            switch familia {
            case .accessoryCircular:
                circular
            case .systemSmall:
                VStack(alignment: .leading, spacing: 10) {
                    cabecalho
                    if let primeiro = entrada.botoes.first {
                        botao(primeiro)
                    }
                }
            default:
                VStack(alignment: .leading, spacing: 12) {
                    cabecalho
                    HStack(spacing: 8) {
                        ForEach(entrada.botoes, id: \.self) { b in
                            botao(b)
                        }
                    }
                }
            }
        }
    }

    private var cabecalho: some View {
        HStack(spacing: 8) {
            MonitorPequeno(ligado: entrada.online)
            Text(entrada.nome)
                .font(.headline)
                .foregroundStyle(CoresDeskside.texto)
                .lineLimit(1)
        }
    }

    /// Uma tecla com relevo: a mesma do teclado do app.
    private func botao(_ b: BotaoNoWidget) -> some View {
        Button(
            intent: AcaoDoWidgetIntent(
                tipo: b.tipo, computador: entrada.computador, automacao: b.automacao
            )
        ) {
            VStack(spacing: 5) {
                Image(systemName: b.simbolo)
                    .font(.title3)
                    .foregroundStyle(CoresDeskside.aoVivo)
                Text(b.rotulo)
                    .font(.caption2)
                    .foregroundStyle(CoresDeskside.texto)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, minHeight: 62)
            .padding(.horizontal, 4)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(CoresDeskside.tecla)
                    .shadow(color: CoresDeskside.teclaSombra, radius: 0, x: 0, y: 3)
            )
        }
        .buttonStyle(.plain)
    }

    /// Tela de bloqueio: o primeiro botão, só o ícone.
    @ViewBuilder
    private var circular: some View {
        if let primeiro = entrada.botoes.first {
            Button(
                intent: AcaoDoWidgetIntent(
                    tipo: primeiro.tipo,
                    computador: entrada.computador,
                    automacao: primeiro.automacao
                )
            ) {
                ZStack {
                    AccessoryWidgetBackground()
                    Image(systemName: primeiro.simbolo)
                        .font(.title2)
                }
            }
            .buttonStyle(.plain)
        } else {
            ZStack {
                AccessoryWidgetBackground()
                Image(systemName: "desktopcomputer")
            }
        }
    }
}

// MARK: - Widget

struct DesksideWidget: Widget {
    /// O nome que o app usa para pedir um redesenho (`HomeWidget.updateWidget`).
    static let tipo = "DesksideWidget"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: Self.tipo, provider: Provedor()) { entrada in
            VistaDoWidget(entrada: entrada)
        }
        .configurationDisplayName("Deskside")
        .description("Seu computador e três botões, escolhidos em Configurações › Widgets no app.")
        .supportedFamilies([.systemSmall, .systemMedium, .accessoryCircular])
    }
}

@main
struct DesksideWidgets: WidgetBundle {
    var body: some Widget {
        DesksideWidget()
        // A sessão ao vivo na tela bloqueada e na Ilha Dinâmica (ver
        // `SessaoAoVivoWidget.swift`). Mora aqui porque o iOS só desenha uma
        // Live Activity a partir de uma extensão de widget.
        SessaoAoVivoWidget()
    }
}
