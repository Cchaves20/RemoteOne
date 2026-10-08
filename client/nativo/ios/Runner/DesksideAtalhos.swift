// Siri e app Atalhos: as ações do Deskside sem abrir o app.
//
// ## Por que Swift, e por que aqui
//
// As ações do app Atalhos e as frases da Siri são App Intents, uma API só de
// Swift. Elas rodam **sem abrir o app**, então não dá para passar pelo Flutter:
// este arquivo fala direto com o servidor, com o mesmo login que o app guarda.
//
// A pasta `ios/` não é versionada (o `flutter create` a gera em todo build), e
// por isso este arquivo mora em `client/nativo/ios/Runner/` e é copiado para o
// projeto por `scripts/preparar-ios.sh`, que também o acrescenta ao alvo
// Runner. Não é compilado no ambiente de desenvolvimento: quem o exercita é o
// build do Codemagic.
//
// ## De onde vem o login
//
// O app guarda os tokens pelo `flutter_secure_storage`: um item comum do
// Keychain, serviço `flutter_secure_storage_service`, conta `deskside_access`
// e `deskside_refresh`, valor em UTF-8. Isto lê o mesmo item e **nunca o
// escreve**: o token de acesso renovado aqui fica só na memória, e o app
// renova o dele por conta própria ao abrir. O servidor não troca o token de
// renovação, então os dois lados podem renová-lo sem se atrapalhar.
//
// ## Segurança
//
// Toda ação exige o iPhone desbloqueado (`requiresAuthentication`). Pela tela
// de bloqueio, a Siri pede o Face ID antes. Um celular perdido não pode mexer
// no computador de ninguém por voz.

import AppIntents
import Foundation
import Security

// MARK: - Erros

@available(iOS 16.0, *)
enum ErroDoDeskside: Error, CustomLocalizedStringResourceConvertible {
    case semLogin
    case semComputador
    case servidor(String)

    var localizedStringResource: LocalizedStringResource {
        switch self {
        case .semLogin:
            return "Abra o Deskside e entre na sua conta primeiro."
        case .semComputador:
            return "Nenhum computador pareado na sua conta."
        case .servidor(let texto):
            return "\(texto)"
        }
    }
}

// MARK: - Servidor

@available(iOS 16.0, *)
enum DesksideAPI {
    static let servicoDoKeychain = "flutter_secure_storage_service"

    /// O endereço do servidor: o que o app salvou, ou o padrão.
    static var base: String {
        let salvo = UserDefaults.standard.string(forKey: "flutter.serverUrl") ?? ""
        let limpo = salvo.trimmingCharacters(in: .whitespacesAndNewlines)
        return limpo.isEmpty ? "https://deskside.com.br" : limpo
    }

    static func lerDoKeychain(_ conta: String) -> String? {
        let consulta: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: servicoDoKeychain,
            kSecAttrAccount as String: conta,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var resultado: AnyObject?
        let status = SecItemCopyMatching(consulta as CFDictionary, &resultado)
        guard status == errSecSuccess, let dados = resultado as? Data else { return nil }
        return String(data: dados, encoding: .utf8)
    }

    /// O `detail` que o servidor manda nos erros, quando há um.
    static func detalhe(_ dados: Data) -> String? {
        guard let json = try? JSONSerialization.jsonObject(with: dados) as? [String: Any] else {
            return nil
        }
        return json["detail"] as? String
    }

    static func url(_ caminho: String) throws -> URL {
        guard let url = URL(string: base + caminho) else {
            throw ErroDoDeskside.servidor("Endereço do servidor inválido.")
        }
        return url
    }

    /// Troca o token de renovação por um de acesso novo.
    static func renovar(_ refresh: String) async throws -> String {
        var pedido = URLRequest(url: try url("/api/v1/auth/refresh"))
        pedido.httpMethod = "POST"
        pedido.setValue("application/json", forHTTPHeaderField: "Content-Type")
        pedido.httpBody = try JSONSerialization.data(withJSONObject: ["refresh_token": refresh])
        pedido.timeoutInterval = 15
        let (dados, resposta) = try await URLSession.shared.data(for: pedido)
        let status = (resposta as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200,
              let json = try? JSONSerialization.jsonObject(with: dados) as? [String: Any],
              let acesso = json["access_token"] as? String
        else {
            throw ErroDoDeskside.semLogin
        }
        return acesso
    }

    /// Uma chamada autenticada. Renova o token uma vez, se ele tiver vencido.
    static func pedir(
        _ metodo: String,
        _ caminho: String,
        corpo: [String: Any]? = nil,
        prazo: TimeInterval = 20
    ) async throws -> Data {
        guard let refresh = lerDoKeychain("deskside_refresh") else {
            throw ErroDoDeskside.semLogin
        }
        var acesso = lerDoKeychain("deskside_access")
        for tentativa in 0..<2 {
            if acesso == nil || tentativa == 1 {
                acesso = try await renovar(refresh)
            }
            var pedido = URLRequest(url: try url(caminho))
            pedido.httpMethod = metodo
            pedido.timeoutInterval = prazo
            pedido.setValue("Bearer \(acesso ?? "")", forHTTPHeaderField: "Authorization")
            if let corpo = corpo {
                pedido.setValue("application/json", forHTTPHeaderField: "Content-Type")
                pedido.httpBody = try JSONSerialization.data(withJSONObject: corpo)
            }
            let (dados, resposta) = try await URLSession.shared.data(for: pedido)
            let status = (resposta as? HTTPURLResponse)?.statusCode ?? 0
            if status == 401 && tentativa == 0 {
                continue
            }
            if (200..<300).contains(status) {
                return dados
            }
            throw ErroDoDeskside.servidor(
                detalhe(dados) ?? "O servidor respondeu \(status)."
            )
        }
        throw ErroDoDeskside.semLogin
    }

    static func computadores() async throws -> [ComputadorEntity] {
        let dados = try await pedir("GET", "/api/v1/devices")
        let lista = (try? JSONSerialization.jsonObject(with: dados) as? [[String: Any]]) ?? []
        return lista.compactMap { item in
            guard let id = item["device_id"] as? String else { return nil }
            let nome = (item["name"] as? String) ?? id
            return ComputadorEntity(id: id, nome: nome)
        }
    }

    static func automacoes() async throws -> [AutomacaoEntity] {
        let dados = try await pedir("GET", "/api/v1/automations")
        let json = (try? JSONSerialization.jsonObject(with: dados) as? [String: Any]) ?? [:]
        let lista = (json["automations"] as? [[String: Any]]) ?? []
        return lista.compactMap { item in
            guard let id = item["id"] as? String else { return nil }
            return AutomacaoEntity(
                id: id,
                nome: (item["name"] as? String) ?? id,
                computadorFixo: (item["device_id"] as? String) ?? ""
            )
        }
    }

    /// O computador em que a ação roda: o pedido, ou o único da conta.
    /// `nil` quando há vários e ninguém escolheu — quem chama pergunta.
    static func computadorPadrao(_ pedido: ComputadorEntity?) async throws -> ComputadorEntity? {
        if let pedido = pedido {
            return pedido
        }
        let todos = try await computadores()
        if todos.isEmpty {
            throw ErroDoDeskside.semComputador
        }
        return todos.count == 1 ? todos[0] : nil
    }
}

// MARK: - Entidades

@available(iOS 16.0, *)
struct ComputadorEntity: AppEntity {
    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Computador"
    static let defaultQuery = ComputadorQuery()

    let id: String
    let nome: String

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(nome)")
    }
}

@available(iOS 16.0, *)
struct ComputadorQuery: EntityQuery {
    func entities(for identifiers: [String]) async throws -> [ComputadorEntity] {
        try await DesksideAPI.computadores().filter { identifiers.contains($0.id) }
    }

    func suggestedEntities() async throws -> [ComputadorEntity] {
        try await DesksideAPI.computadores()
    }
}

@available(iOS 16.0, *)
struct AutomacaoEntity: AppEntity {
    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Automação"
    static let defaultQuery = AutomacaoQuery()

    let id: String
    let nome: String
    /// Em qual computador ela roda sempre. Vazio = em qualquer um.
    let computadorFixo: String

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(nome)")
    }
}

@available(iOS 16.0, *)
struct AutomacaoQuery: EntityQuery {
    func entities(for identifiers: [String]) async throws -> [AutomacaoEntity] {
        try await DesksideAPI.automacoes().filter { identifiers.contains($0.id) }
    }

    func suggestedEntities() async throws -> [AutomacaoEntity] {
        try await DesksideAPI.automacoes()
    }
}

// MARK: - Ações

@available(iOS 16.0, *)
struct RodarAutomacaoIntent: AppIntent {
    static let title: LocalizedStringResource = "Rodar automação"
    static let description = IntentDescription("Roda uma automação do Deskside no computador.")
    static let authenticationPolicy: IntentAuthenticationPolicy = .requiresAuthentication

    @Parameter(title: "Automação")
    var automacao: AutomacaoEntity

    @Parameter(title: "Computador")
    var computador: ComputadorEntity?

    func perform() async throws -> some IntentResult & ProvidesDialog {
        var alvo = automacao.computadorFixo
        if alvo.isEmpty {
            guard let escolhido = try await DesksideAPI.computadorPadrao(computador) else {
                throw $computador.needsValueError("Em qual computador?")
            }
            alvo = escolhido.id
        }
        let caminho = "/api/v1/automations/\(automacao.id)/run?device_id="
            + (alvo.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? alvo)
        let dados = try await DesksideAPI.pedir("POST", caminho, prazo: 160)
        let json = (try? JSONSerialization.jsonObject(with: dados) as? [String: Any]) ?? [:]
        let passos = (json["results"] as? [[String: Any]]) ?? []
        let falhas = passos.filter { ($0["ok"] as? Bool) != true }.count
        let texto = falhas == 0
            ? "\(automacao.nome): pronto, \(passos.count) passo(s) no computador."
            : "\(automacao.nome): \(passos.count - falhas) de \(passos.count) passo(s) deram certo."
        return .result(dialog: "\(texto)")
    }
}

@available(iOS 16.0, *)
struct ModoApresentacaoIntent: AppIntent {
    static let title: LocalizedStringResource = "Modo apresentação"
    static let description = IntentDescription(
        "Liga ou desliga o modo apresentação: a tela não apaga e as notificações não aparecem."
    )
    static let authenticationPolicy: IntentAuthenticationPolicy = .requiresAuthentication

    @Parameter(title: "Computador")
    var computador: ComputadorEntity?

    func perform() async throws -> some IntentResult & ProvidesDialog {
        guard let alvo = try await DesksideAPI.computadorPadrao(computador) else {
            throw $computador.needsValueError("Em qual computador?")
        }
        let caminho = "/api/v1/devices/\(alvo.id)/presentation"
        let atual = try await DesksideAPI.pedir("GET", caminho)
        let json = (try? JSONSerialization.jsonObject(with: atual) as? [String: Any]) ?? [:]
        let ligar = !((json["on"] as? Bool) ?? false)
        _ = try await DesksideAPI.pedir("POST", caminho, corpo: ["on": ligar])
        let texto = ligar
            ? "Modo apresentação ligado em \(alvo.nome)."
            : "Modo apresentação desligado em \(alvo.nome)."
        return .result(dialog: "\(texto)")
    }
}

@available(iOS 16.0, *)
struct TocarPausarIntent: AppIntent {
    static let title: LocalizedStringResource = "Tocar ou pausar"
    static let description = IntentDescription("Toca ou pausa o que está tocando no computador.")
    static let authenticationPolicy: IntentAuthenticationPolicy = .requiresAuthentication

    @Parameter(title: "Computador")
    var computador: ComputadorEntity?

    func perform() async throws -> some IntentResult & ProvidesDialog {
        guard let alvo = try await DesksideAPI.computadorPadrao(computador) else {
            throw $computador.needsValueError("Em qual computador?")
        }
        _ = try await DesksideAPI.pedir(
            "POST", "/api/v1/devices/\(alvo.id)/media", corpo: ["action": "play_pause"]
        )
        let texto = "Feito em \(alvo.nome)."
        return .result(dialog: "\(texto)")
    }
}

@available(iOS 16.0, *)
struct SuspenderIntent: AppIntent {
    static let title: LocalizedStringResource = "Suspender o computador"
    static let description = IntentDescription("Põe o computador para dormir.")
    static let authenticationPolicy: IntentAuthenticationPolicy = .requiresAuthentication

    @Parameter(title: "Computador")
    var computador: ComputadorEntity?

    func perform() async throws -> some IntentResult & ProvidesDialog {
        guard let alvo = try await DesksideAPI.computadorPadrao(computador) else {
            throw $computador.needsValueError("Em qual computador?")
        }
        _ = try await DesksideAPI.pedir(
            "POST", "/api/v1/devices/\(alvo.id)/power", corpo: ["action": "suspend"]
        )
        let texto = "\(alvo.nome) vai dormir."
        return .result(dialog: "\(texto)")
    }
}

// MARK: - Frases da Siri

/// As frases que funcionam sem configurar nada. Toda frase precisa citar o
/// nome do app — é regra da Apple, para a Siri saber a quem entregar.
///
/// Em português porque o idioma de desenvolvimento do projeto é posto em
/// pt-BR por `preparar-ios.sh`: é ele que diz à Siri em que língua estas
/// frases estão. As ações em si aparecem no app Atalhos em qualquer idioma, e
/// lá dá para criar um atalho com o nome que quiser ("Modo cinema").
@available(iOS 16.0, *)
struct DesksideAtalhos: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: RodarAutomacaoIntent(),
            phrases: [
                "Rodar automação no \(.applicationName)",
                "Executar automação no \(.applicationName)",
            ]
        )
        AppShortcut(
            intent: ModoApresentacaoIntent(),
            phrases: [
                "Modo apresentação no \(.applicationName)",
                "Alternar apresentação no \(.applicationName)",
            ]
        )
        AppShortcut(
            intent: TocarPausarIntent(),
            phrases: [
                "Tocar ou pausar no \(.applicationName)",
                "Pausar o computador no \(.applicationName)",
            ]
        )
        AppShortcut(
            intent: SuspenderIntent(),
            phrases: [
                "Suspender o computador no \(.applicationName)",
            ]
        )
    }
}
