// A sessão de controle como Live Activity: o que o app conta ao iOS para ele
// desenhar na tela bloqueada e na Ilha Dinâmica.
//
// Em `Comum` porque os dois lados precisam do mesmo tipo: o app (alvo Runner)
// inicia e atualiza a atividade, e a extensão do widget a desenha.

import ActivityKit
import Foundation

@available(iOS 16.1, *)
struct SessaoAtributos: ActivityAttributes {
    /// O que muda durante a sessão.
    struct ContentState: Codable, Hashable {
        /// Conexão direta (falso = pelo relay, o caminho mais lento).
        var direto: Bool
        /// Ida e volta em milissegundos, quando já medida.
        var ms: Int?
    }

    /// O nome do computador que está sendo controlado.
    var computador: String
    /// Quando a sessão começou: o relógio da atividade conta a partir daqui,
    /// sozinho, sem o app precisar mandar o tempo a cada segundo.
    var desde: Date
}
