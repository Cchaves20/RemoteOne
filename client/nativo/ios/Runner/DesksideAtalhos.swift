// As frases da Siri. Só no app (alvo Runner): o widget usa as ações de
// `Comum/DesksideComum.swift`, mas frases são do app.
//
// Ver o cabeçalho de `DesksideComum.swift` para o login e a segurança.

import AppIntents

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
