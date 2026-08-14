//! Modo apresentação: a tela não apaga e as notificações não aparecem.
//!
//! O que ele evita é específico e constrangedor: a mensagem que salta no canto
//! da tela no meio de uma apresentação, com o projetor ligado e a sala inteira
//! lendo junto. E a tela que escurece porque ninguém encostou no mouse em dez
//! minutos de fala.
//!
//! ## Quem manda: a pessoa, depois a detecção
//!
//! São duas fontes de decisão, e a ordem entre elas é o recurso inteiro:
//!
//! - **A escolha explícita** (o botão na barra de perfis) vale sobre tudo.
//! - **A detecção automática** — desligada por padrão, e configurável só na
//!   área de perfis — liga o modo quando aparece um programa em tela cheia.
//!
//! O caso que faz a regra existir: a detecção acha que é apresentação, a pessoa
//! desliga o modo à mão, e três segundos depois a detecção liga de novo. Seria
//! um botão que não obedece. Por isso a escolha manual persiste, e só é
//! esquecida quando a **apresentação em si** começa ou termina — aí ela já não
//! diz respeito ao que está acontecendo agora.
//!
//! E é esquecida só quando o automático está ligado. Com ele desligado a
//! detecção não manda em nada, e apagar a escolha da pessoa por causa de uma
//! janela que fechou seria desligar o modo sem motivo visível.

/// Quem decide se o modo está valendo.
///
/// A parte testável do recurso: as três entradas (escolha, automático,
/// detecção) entram aqui e sai um sim ou não, sem tocar em nada da plataforma.
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct Modo {
    /// Se a detecção automática vale. Desligada por padrão, de propósito: um
    /// recurso que silencia notificações sozinho, sem ninguém ter pedido, é um
    /// recurso que faz a pessoa perder uma mensagem sem entender por quê.
    auto: bool,
    /// A escolha explícita, quando houver. `None` = "deixa a detecção decidir".
    manual: Option<bool>,
    /// Se havia apresentação na última avaliação.
    detectado: bool,
    /// O título da janela em tela cheia, quando há uma.
    ///
    /// Guardado porque é o que explica um modo que ligou sozinho: sem ele, a
    /// pessoa vê a chave ligada e não faz ideia de quem a ligou.
    titulo: Option<String>,
    /// Se o modo está valendo agora.
    ativo: bool,
    /// Se este Windows tem com que silenciar as notificações.
    ///
    /// Começa otimista e só vira falso depois de uma tentativa que falhou —
    /// não dá para saber antes de tentar, e presumir o pior esconderia o
    /// recurso em toda máquina antes do primeiro uso.
    suportado: bool,
}

impl Modo {
    pub fn novo(auto: bool) -> Self {
        Self {
            auto,
            suportado: true,
            ..Default::default()
        }
    }

    pub fn titulo(&self) -> Option<&str> {
        self.titulo.as_deref()
    }

    pub fn suportado(&self) -> bool {
        self.suportado
    }

    /// Registra que o sistema não tinha com que silenciar.
    pub fn sem_suporte(&mut self) {
        self.suportado = false;
    }

    pub fn auto(&self) -> bool {
        self.auto
    }

    pub fn ativo(&self) -> bool {
        self.ativo
    }

    pub fn detectado(&self) -> bool {
        self.detectado
    }

    /// A escolha da pessoa, no botão da barra de perfis.
    ///
    /// Devolve `Some(novo)` quando o modo muda — é o que diz ao chamador que há
    /// algo a fazer na plataforma.
    pub fn escolher(&mut self, ligado: bool) -> Option<bool> {
        self.manual = Some(ligado);
        self.decidir()
    }

    /// Liga ou desliga a detecção automática. Só se edita na área de perfis.
    pub fn definir_auto(&mut self, auto: bool) -> Option<bool> {
        self.auto = auto;
        self.decidir()
    }

    /// O que a detecção viu agora: o título da janela em tela cheia, ou nada.
    pub fn avaliar(&mut self, visto: Option<&str>) -> Option<bool> {
        self.titulo = visto.map(str::to_string);
        let apresentando = visto.is_some();
        if apresentando != self.detectado {
            // A apresentação começou ou terminou: a escolha manual valia para o
            // trecho anterior. Mantê-la faria "desliguei agora" continuar
            // valendo na reunião de amanhã.
            //
            // **Só com o automático ligado.** Sem ele a detecção não manda em
            // nada, e apagar a escolha da pessoa por causa de uma janela que
            // fechou desligaria o modo sem motivo nenhum na tela.
            if self.auto {
                self.manual = None;
            }
            self.detectado = apresentando;
        }
        self.decidir()
    }

    fn desejado(&self) -> bool {
        match self.manual {
            Some(escolha) => escolha,
            None => self.auto && self.detectado,
        }
    }

    /// Recalcula, e só responde quando **mudou**.
    ///
    /// Só quando muda porque o chamador reage lançando um processo do Windows:
    /// repetir isso a cada três segundos encheria a máquina de trabalho para
    /// não mudar nada.
    fn decidir(&mut self) -> Option<bool> {
        let quer = self.desejado();
        if quer == self.ativo {
            return None;
        }
        self.ativo = quer;
        Some(quer)
    }
}

/// O modo visto pelas duas partes: o laço da conexão e a tarefa que vigia.
pub type Compartilhado = std::sync::Arc<std::sync::Mutex<Modo>>;

/// Com que frequência a detecção olha a tela.
///
/// Três segundos, e não dez como a agenda: aqui o atraso aparece: começar a
/// apresentar e esperar dez segundos pelo silêncio é tempo de sobra para a
/// notificação que se queria evitar.
pub const RITMO: std::time::Duration = std::time::Duration::from_secs(3);

/// Liga ou desliga o silêncio do sistema.
///
/// No Windows é o `PresentationSettings`, que é a peça do próprio sistema para
/// isto: ele desliga a proteção de tela, segura o computador acordado e cala as
/// notificações, tudo pelo caminho que a Microsoft mantém. A alternativa seria
/// mexer no Assistente de Foco pelo registro, num lugar sem contrato nenhum que
/// muda de forma entre versões do Windows - e que quebraria calado.
pub use imp::silenciar;

/// O que a detecção viu: o título da janela em tela cheia, se houver.
pub use imp::detectar;

#[cfg(windows)]
mod imp {
    /// `true` = silêncio ligado.
    ///
    /// Devolve `Err` quando o `PresentationSettings` não existe. Ele acompanha
    /// o Windows, mas não em toda instalação enxuta - e dizer isso é melhor que
    /// mostrar um botão que não faz nada.
    pub fn silenciar(ligar: bool) -> Result<(), String> {
        let argumento = if ligar { "/start" } else { "/stop" };
        let saida = std::process::Command::new("PresentationSettings.exe")
            .arg(argumento)
            .spawn();
        match saida {
            Ok(_) => Ok(()),
            Err(e) => Err(format!(
                "este Windows não tem o PresentationSettings ({e}); \
                 a tela continua acesa, mas as notificações não são silenciadas"
            )),
        }
    }

    pub fn detectar() -> Option<String> {
        crate::janelas::em_tela_cheia()
    }
}

#[cfg(not(windows))]
mod imp {
    pub fn silenciar(_ligar: bool) -> Result<(), String> {
        Err("modo apresentação só no Windows".into())
    }

    pub fn detectar() -> Option<String> {
        None
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn desligado_por_padrao_e_sem_automatico() {
        // Um recurso que silencia notificações sozinho, sem ninguém ter pedido,
        // faz a pessoa perder uma mensagem sem entender por quê.
        let m = Modo::default();
        assert!(!m.ativo());
        assert!(!m.auto());
    }

    #[test]
    fn sem_automatico_a_deteccao_nao_liga_nada() {
        let mut m = Modo::novo(false);
        assert_eq!(m.avaliar(Some("slides")), None);
        assert!(!m.ativo());
    }

    #[test]
    fn com_automatico_a_apresentacao_liga_e_o_fim_dela_desliga() {
        let mut m = Modo::novo(true);
        assert_eq!(m.avaliar(Some("slides")), Some(true));
        // O mesmo estado na volta seguinte não repete o pedido: cada mudança
        // custa um processo do Windows.
        assert_eq!(m.avaliar(Some("slides")), None);
        assert_eq!(m.avaliar(None), Some(false));
    }

    #[test]
    fn desligar_a_mao_vence_a_deteccao_enquanto_a_apresentacao_dura() {
        // O caso que faz a regra existir: sem isto, a detecção religaria o modo
        // três segundos depois e o botão pareceria não obedecer.
        let mut m = Modo::novo(true);
        m.avaliar(Some("slides"));
        assert_eq!(m.escolher(false), Some(false));
        assert_eq!(m.avaliar(Some("slides")), None, "a detecção não pode religar sozinha");
        assert!(!m.ativo());
    }

    #[test]
    fn a_escolha_manual_e_esquecida_quando_a_apresentacao_termina() {
        // "Desliguei agora" não pode valer para a reunião de amanhã.
        let mut m = Modo::novo(true);
        m.avaliar(Some("slides"));
        m.escolher(false);
        assert_eq!(m.avaliar(None), None, "já estava desligado");
        assert_eq!(m.avaliar(Some("slides")), Some(true), "a apresentação nova liga");
    }

    #[test]
    fn com_automatico_desligado_a_escolha_manual_sobrevive_a_janela_que_fecha() {
        // O erro que a guarda evita: apagar a escolha da pessoa por causa de uma
        // detecção que nem está mandando em nada. O modo se desligaria sozinho,
        // e nada na tela explicaria por quê.
        let mut m = Modo::novo(false);
        assert_eq!(m.escolher(true), Some(true));
        assert_eq!(m.avaliar(Some("slides")), None);
        assert_eq!(m.avaliar(None), None, "não pode desligar o que foi pedido");
        assert!(m.ativo());
    }

    #[test]
    fn ligar_o_automatico_no_meio_de_uma_apresentacao_pega_a_atual() {
        // Ligar a opção e não ver efeito nenhum até a próxima apresentação
        // pareceria uma opção quebrada.
        let mut m = Modo::novo(false);
        m.avaliar(Some("slides"));
        assert_eq!(m.definir_auto(true), Some(true));
    }

    #[test]
    fn desligar_o_automatico_desliga_o_que_ele_tinha_ligado() {
        let mut m = Modo::novo(true);
        m.avaliar(Some("slides"));
        assert_eq!(m.definir_auto(false), Some(false));
        assert!(!m.ativo());
    }

    #[test]
    fn desligar_o_automatico_nao_desliga_o_que_a_pessoa_pediu() {
        let mut m = Modo::novo(true);
        m.escolher(true);
        assert_eq!(m.definir_auto(false), None);
        assert!(m.ativo());
    }
}
