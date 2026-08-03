//! Qualidade adaptativa (Fase 4b do `docs/webrtc-plano.md`).
//!
//! O `h264.rs` explica por que nenhuma configuração do codificador segura a
//! banda sem travar a imagem: com o descarte de quadros desligado — e ele
//! precisa ficar desligado, porque imagem travada é pior que imagem borrada —
//! o openh264 estoura o teto de taxa quando o conteúdo exige. Então o limite
//! de verdade tem que vir de fora, e vem daqui: **menos pixels e menos
//! quadros** quando a rede aperta, de volta ao normal quando ela sobra.
//!
//! Isso deixou de ser conforto quando o TURN entrou (Fase 5): com relay, o
//! vídeo atravessa o VPS nos dois sentidos, e a franquia da Oracle é finita.
//!
//! ## O sinal
//!
//! **Perda de pacotes**, tirada dos relatórios de recepção RTCP que o telefone
//! já manda de segundo em segundo. Escolhido não por ser o melhor sinal, mas
//! por ser o único que as duas pontas já trocam sem nada novo no protocolo — e
//! por ser o que realmente estraga a imagem: pacote perdido é bloco corrompido,
//! e bloco corrompido é pedido de quadro-chave, que é uma rajada de bytes
//! justamente quando não há banda para ela.
//!
//! ## As regras, e por que cada uma existe
//!
//! - **Desce rápido, sobe devagar.** Descer errado custa nitidez por alguns
//!   segundos; subir errado custa uma imagem que congela. Os dois erros não
//!   têm o mesmo preço, então não têm o mesmo gatilho.
//! - **Zona morta** entre 2% e 10%. Sem ela, uma rede que oscila em 5% ficaria
//!   subindo e descendo para sempre, e cada troca custa uma recaptura e um
//!   quadro-chave — o remédio viraria a doença.
//! - **Espera depois de mudar.** Os relatórios que chegam logo após uma
//!   mudança ainda descrevem o mundo anterior. Reagir a eles é reagir ao
//!   próprio eco.
//! - **Cautela crescente.** Cada queda dobra o tempo de calmaria exigido para
//!   voltar a subir, até um teto. Uma rede que já derrubou a qualidade três
//!   vezes não merece o mesmo benefício da dúvida da primeira.
//!
//! Tudo aqui é função pura do que entra — sem relógio, sem rede, sem estado
//! global. É o que permite testar a política inteira em milissegundos, que é o
//! oposto de descobrir a oscilação depois, num 5G, olhando para uma tela que
//! pisca.

use std::time::Duration;

/// Um degrau da escada: o que a tela vira neste nível.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Level {
    /// Largura máxima do quadro capturado. É o parâmetro que mais pesa: o
    /// custo de codificar é praticamente linear no número de pixels.
    pub width: u32,
    pub fps: u32,
    /// Alvo passado ao codificador. Ajuda, mas não manda — vale menos que os
    /// outros dois, pelo motivo que o `h264.rs` documenta.
    pub bitrate: u32,
}

/// A escada, do melhor para o pior.
///
/// **O topo não é um limite, é a ausência de um.** Cada degrau é um teto que
/// se aplica por cima do que já estava configurado, então o degrau 0 devolve
/// exatamente o que o dono da máquina pediu — quem pôs 60 fps continua com 60.
/// Escrever `1280/30` aqui teria transformado o padrão em máximo, e a escada
/// passaria a *impor* qualidade em vez de só reduzi-la.
///
/// O piso ainda é utilizável para controle remoto: 640px e 12 fps mostram
/// texto legível e movimento contínuo, que é o que se precisa para clicar no
/// lugar certo. Abaixo disso a resposta não é degradar mais, é o JPEG.
// Uma linha por degrau, de propósito: a escada é uma tabela, e a leitura
// vertical das colunas é o que deixa evidente que ela só piora para baixo.
#[rustfmt::skip]
pub const LADDER: [Level; 5] = [
    Level { width: u32::MAX, fps: u32::MAX, bitrate: u32::MAX },
    Level { width: 1280, fps: 20, bitrate: 1_000_000 },
    Level { width: 960, fps: 20, bitrate: 700_000 },
    Level { width: 800, fps: 15, bitrate: 450_000 },
    Level { width: 640, fps: 12, bitrate: 250_000 },
];

/// Acima disto a rede está claramente entregando menos do que se manda.
const DOWN_LOSS: f32 = 0.10;

/// Abaixo disto a rede está sobrando e vale tentar mais.
const UP_LOSS: f32 = 0.02;

/// Quanto tempo ignorar os relatórios depois de uma mudança.
const SETTLE: Duration = Duration::from_secs(3);

/// Calmaria exigida para a primeira subida. Dobra a cada queda.
const PATIENCE: Duration = Duration::from_secs(10);

/// Quantas vezes a paciência pode dobrar (10s → 20 → 40 → 80).
const MAX_DOUBLINGS: u32 = 3;

/// A política de qualidade: recebe perda, devolve mudanças de degrau.
#[derive(Debug)]
pub struct Ladder {
    level: usize,
    /// Tempo de rede limpa acumulado desde a última mudança.
    calm: Duration,
    /// O que falta da espera pós-mudança.
    settle: Duration,
    /// Quantas quedas já houve nesta sessão.
    falls: u32,
}

impl Default for Ladder {
    fn default() -> Self {
        Self::new()
    }
}

impl Ladder {
    pub fn new() -> Self {
        Self {
            level: 0,
            calm: Duration::ZERO,
            settle: Duration::ZERO,
            falls: 0,
        }
    }

    /// Volta ao topo. Chamado a cada sessão de vídeo nova: a rede da sessão
    /// anterior não diz nada sobre a próxima, e começar punido por causa de um
    /// 5G de ontem seria entregar menos do que a rede de agora aguenta.
    pub fn reset(&mut self) {
        *self = Self::new();
    }

    /// O degrau em uso.
    pub fn current(&self) -> Level {
        LADDER[self.level]
    }

    /// A posição na escada, contada do topo. Só para as mensagens de console.
    pub fn step(&self) -> usize {
        self.level
    }

    /// Registra uma janela de observação e devolve o degrau novo, se mudou.
    ///
    /// `loss` é a fração perdida (0,0 a 1,0) e `dt` é quanto tempo essa janela
    /// cobriu. Nada de relógio aqui dentro: quem sabe que horas são é o laço
    /// principal, e é isso que torna esta política testável.
    pub fn observe(&mut self, loss: f32, dt: Duration) -> Option<Level> {
        // Ainda ecoando a mudança anterior.
        if !self.settle.is_zero() {
            self.settle = self.settle.saturating_sub(dt);
            return None;
        }
        if loss >= DOWN_LOSS {
            return self.step_down();
        }
        if loss <= UP_LOSS {
            self.calm += dt;
            if self.calm >= self.patience() {
                return self.step_up();
            }
            return None;
        }
        // Zona morta. Perder o crédito acumulado aqui é de propósito: uma rede
        // que fica em 5% não é uma rede que aguenta mais.
        self.calm = Duration::ZERO;
        None
    }

    /// `saturating_sub(1)` porque só se pergunta isto fora do topo, e fora do
    /// topo já houve pelo menos uma queda: a primeira volta merece a paciência
    /// base, não o dobro dela.
    fn patience(&self) -> Duration {
        PATIENCE * 2u32.pow(self.falls.saturating_sub(1).min(MAX_DOUBLINGS))
    }

    fn step_down(&mut self) -> Option<Level> {
        self.calm = Duration::ZERO;
        if self.level + 1 >= LADDER.len() {
            return None; // já no piso; degradar mais não ajudaria
        }
        self.level += 1;
        self.falls += 1;
        self.settle = SETTLE;
        Some(self.current())
    }

    fn step_up(&mut self) -> Option<Level> {
        self.calm = Duration::ZERO;
        if self.level == 0 {
            return None;
        }
        self.level -= 1;
        self.settle = SETTLE;
        // Aguentar o topo de novo limpa a ficha: a cautela existe por causa de
        // uma rede ruim, e essa rede evidentemente passou.
        if self.level == 0 {
            self.falls = 0;
        }
        Some(self.current())
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn s(n: u64) -> Duration {
        Duration::from_secs(n)
    }

    /// Passa `janelas` observações de 2s com a perda dada, devolvendo a última
    /// mudança vista.
    fn feed(l: &mut Ladder, loss: f32, janelas: u32) -> Option<Level> {
        let mut last = None;
        for _ in 0..janelas {
            if let Some(n) = l.observe(loss, s(2)) {
                last = Some(n);
            }
        }
        last
    }

    #[test]
    fn a_escada_so_piora_para_baixo() {
        // Se um degrau tiver mais pixels ou mais quadros que o anterior, descer
        // deixa de ser descer - e o laço de realimentação passa a empurrar na
        // direção errada sem que nada mais no código perceba.
        for par in LADDER.windows(2) {
            assert!(par[1].width <= par[0].width, "largura subiu: {par:?}");
            assert!(par[1].fps <= par[0].fps, "fps subiu: {par:?}");
            assert!(par[1].bitrate <= par[0].bitrate, "taxa subiu: {par:?}");
            assert!(
                par[1].width < par[0].width || par[1].fps < par[0].fps,
                "degrau que não muda nem pixels nem quadros não economiza \
                 banda de verdade: {par:?}"
            );
        }
    }

    #[test]
    fn rede_limpa_no_topo_nao_muda_nada() {
        let mut l = Ladder::new();
        assert_eq!(feed(&mut l, 0.0, 60), None);
        assert_eq!(l.current(), LADDER[0]);
    }

    #[test]
    fn perda_alta_desce_um_degrau_por_vez() {
        let mut l = Ladder::new();
        assert_eq!(l.observe(0.30, s(2)), Some(LADDER[1]));
        // A espera de 3s cobre as duas janelas seguintes: descer dois degraus
        // de uma vez por causa de relatórios que ainda descrevem o estado
        // anterior é exatamente o erro que ela existe para impedir. Uma janela
        // que só *termina* dentro da espera também não conta — o que ela mediu
        // é metade de cada mundo, e metade não serve para decidir.
        assert_eq!(l.observe(0.30, s(2)), None);
        assert_eq!(l.observe(0.30, s(2)), None);
        assert_eq!(l.observe(0.30, s(2)), Some(LADDER[2]));
    }

    #[test]
    fn a_espera_ignora_o_eco_da_mudanca() {
        let mut l = Ladder::new();
        l.observe(0.30, s(2)).unwrap();
        assert_eq!(l.observe(0.30, s(1)), None);
        assert_eq!(l.observe(0.30, s(1)), None);
        assert_eq!(l.observe(0.30, s(1)), None);
        // 3s cumpridos: agora vale reagir.
        assert_eq!(l.observe(0.30, s(2)), Some(LADDER[2]));
    }

    #[test]
    fn nao_desce_alem_do_piso() {
        let mut l = Ladder::new();
        feed(&mut l, 0.50, 100);
        assert_eq!(l.current(), *LADDER.last().unwrap());
        assert_eq!(l.step(), LADDER.len() - 1);
    }

    #[test]
    fn sobe_so_depois_da_calmaria() {
        let mut l = Ladder::new();
        l.observe(0.30, s(2)).unwrap();
        feed(&mut l, 0.0, 2); // cumpre a espera
        // Nove segundos de rede limpa ainda não bastam.
        assert_eq!(feed(&mut l, 0.0, 4), None);
        assert_eq!(l.step(), 1);
        // O décimo fecha a conta.
        assert_eq!(l.observe(0.0, s(2)), Some(LADDER[0]));
    }

    #[test]
    fn zona_morta_nao_credita_subida() {
        let mut l = Ladder::new();
        l.observe(0.30, s(2)).unwrap();
        feed(&mut l, 0.05, 2); // cumpre a espera
        // Cinco por cento por dois minutos: não é ruim o bastante para descer
        // nem bom o bastante para subir. A qualidade fica onde está.
        assert_eq!(feed(&mut l, 0.05, 60), None);
        assert_eq!(l.step(), 1);
    }

    #[test]
    fn cada_queda_torna_a_subida_mais_cautelosa() {
        let mut l = Ladder::new();
        // Duas quedas: a paciência vai de 10s para 20s.
        l.observe(0.30, s(2)).unwrap();
        feed(&mut l, 0.30, 3); // duas janelas de espera + a que derruba
        assert_eq!(l.step(), 2);
        feed(&mut l, 0.0, 2); // cumpre a espera
        // 10s de calmaria já teriam bastado com uma queda só; com duas, não.
        assert_eq!(feed(&mut l, 0.0, 5), None);
        assert_eq!(l.step(), 2);
        assert_eq!(l.observe(0.0, s(10)), Some(LADDER[1]));
    }

    #[test]
    fn voltar_ao_topo_limpa_a_ficha() {
        let mut l = Ladder::new();
        l.observe(0.30, s(2)).unwrap();
        feed(&mut l, 0.0, 2); // espera
        assert_eq!(feed(&mut l, 0.0, 6), Some(LADDER[0]));
        // De volta ao topo, a próxima queda recomeça com paciência de 10s - a
        // cautela existia por causa de uma rede que evidentemente passou.
        feed(&mut l, 0.0, 2);
        l.observe(0.30, s(2)).unwrap();
        feed(&mut l, 0.0, 2); // espera
        assert_eq!(feed(&mut l, 0.0, 5), Some(LADDER[0]));
    }

    #[test]
    fn reset_volta_ao_topo() {
        let mut l = Ladder::new();
        feed(&mut l, 0.50, 20);
        assert_ne!(l.step(), 0);
        l.reset();
        assert_eq!(l.step(), 0);
        assert_eq!(l.current(), LADDER[0]);
    }

    #[test]
    fn perda_invalida_nao_mexe_na_qualidade() {
        // NaN sai de uma divisão por zero em algum contador; que ele não vire
        // nem subida nem descida é o comportamento seguro.
        let mut l = Ladder::new();
        assert_eq!(feed(&mut l, f32::NAN, 60), None);
        assert_eq!(l.step(), 0);
    }
}
