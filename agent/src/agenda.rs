//! A agenda das automações: o que roda sozinho, e quando.
//!
//! O agendamento só tem sentido se funcionar **sem o celular por perto**. Por
//! isso a agenda vive aqui, no computador: o servidor a entrega uma vez (ao
//! conectar e a cada mudança) e o disparo não depende de mais ninguém — nem do
//! telefone ligado, nem do servidor de pé às dezoito horas.
//!
//! ## A decisão é uma função pura
//!
//! Ler o relógio e decidir são coisas separadas de propósito. `avaliar` recebe
//! "que dia é, que dia da semana é, que minuto do dia é" e devolve o que fazer;
//! quem lê o relógio é uma função de dez linhas, específica de plataforma. Sem
//! essa separação, testar "o que acontece às 17:55" exigiria esperar até as
//! 17:55.

use std::collections::HashMap;

use crate::automacao::Passo;

/// Quanto tempo antes o computador avisa que uma automação vai rodar.
///
/// Cinco minutos é o que dá para salvar o que estava aberto e decidir. Menos
/// não dá tempo de reagir; mais e o aviso vira ruído, porque a pessoa esquece
/// que ele está lá.
pub const AVISO_MINUTOS: i32 = 5;

/// Atraso máximo com que uma automação ainda dispara.
///
/// Existe para o computador que estava desligado. Ligar a máquina às 19h e ver
/// o "fim de expediente" das 18h fechar tudo seria pior do que ele não ter
/// rodado: a pessoa acabou de sentar para trabalhar. Passou da hora com folga,
/// perdeu o dia.
pub const ATRASO_MAXIMO_MINUTOS: i32 = 2;

/// Uma automação agendada, como o servidor a entrega.
#[derive(Debug, Clone, PartialEq)]
pub struct Item {
    pub id: String,
    pub nome: String,
    pub hora: u8,
    pub minuto: u8,
    /// Dias da semana em que roda, **segunda = 0**. Vazio = todos os dias.
    pub dias: Vec<u8>,
    pub passos: Vec<Passo>,
}

impl Item {
    /// Converte o que o servidor mandou. `None` quando o horário não é "HH:MM".
    ///
    /// Descartar o item malformado é melhor que aceitar com um horário
    /// inventado: uma automação que não aparece na lista é um problema
    /// visível, e uma que dispara às 00:00 por causa de um `parse` falho é um
    /// problema que ninguém liga à causa.
    pub fn do_protocolo(item: &crate::protocol::AgendaItem) -> Option<Self> {
        let (h, m) = item.time.split_once(':')?;
        let hora: u8 = h.parse().ok()?;
        let minuto: u8 = m.parse().ok()?;
        if hora > 23 || minuto > 59 {
            return None;
        }
        Some(Self {
            id: item.id.clone(),
            nome: item.name.clone(),
            hora,
            minuto,
            dias: item.days.iter().copied().filter(|d| *d <= 6).collect(),
            passos: item.steps.clone(),
        })
    }

    fn minuto_do_dia(&self) -> i32 {
        self.hora as i32 * 60 + self.minuto as i32
    }

    fn roda_hoje(&self, semana: u8) -> bool {
        self.dias.is_empty() || self.dias.contains(&semana)
    }
}

/// O que o agente deve fazer agora.
#[derive(Debug, Clone, PartialEq)]
pub enum Evento {
    /// Falta pouco: mostrar o aviso com a opção de cancelar.
    Avisar { id: String, nome: String, faltam: i32 },
    /// Chegou a hora.
    Disparar {
        id: String,
        nome: String,
        passos: Vec<Passo>,
    },
}

/// O que já aconteceu com uma automação **hoje**.
///
/// Por dia, e não desde sempre: o `dia` guardado é o que faz a automação voltar
/// a valer amanhã sem ninguém limpar nada. Sem ele, cancelar uma vez cancelaria
/// para sempre — e "hoje eu não quero" viraria "nunca mais".
#[derive(Debug, Clone, Default)]
struct Marca {
    dia: u32,
    avisado: bool,
    disparado: bool,
    cancelado: bool,
}

#[derive(Debug, Default)]
pub struct Agenda {
    itens: Vec<Item>,
    marcas: HashMap<String, Marca>,
}

/// A agenda vista pelas duas partes que a usam.
///
/// Compartilhada porque ela **não pode viver dentro da conexão**. O laço de
/// rede morre e renasce a cada Wi-Fi que troca de rede e a cada suspensão do
/// notebook; uma agenda que morresse junto perderia as dezoito horas por causa
/// de um socket - exatamente o contrário do que este recurso promete.
pub type Compartilhada = std::sync::Arc<std::sync::Mutex<Agenda>>;

impl Agenda {
    /// Troca a agenda inteira pela que o servidor mandou.
    ///
    /// Inteira, e não incremental, porque é assim que ela chega — e porque
    /// lista inteira não dessincroniza. O que some leva a marca junto: uma
    /// automação apagada não pode deixar para trás um "já disparou hoje" que
    /// confundiria outra criada depois com o mesmo identificador.
    pub fn substituir(&mut self, itens: Vec<Item>) {
        self.marcas.retain(|id, _| itens.iter().any(|i| &i.id == id));
        self.itens = itens;
    }

    pub fn itens(&self) -> &[Item] {
        &self.itens
    }

    /// Cancela **o disparo de hoje**. Amanhã ela volta a valer.
    pub fn cancelar(&mut self, id: &str, dia: u32) {
        let marca = self.marcas.entry(id.to_string()).or_default();
        if marca.dia != dia {
            *marca = Marca {
                dia,
                ..Default::default()
            };
        }
        marca.cancelado = true;
    }

    /// O que fazer agora. `semana` com segunda = 0.
    pub fn avaliar(&mut self, dia: u32, semana: u8, minuto_do_dia: u16) -> Vec<Evento> {
        let agora = minuto_do_dia as i32;
        let mut eventos = Vec::new();

        for item in &self.itens {
            let marca = self.marcas.entry(item.id.clone()).or_default();
            // Virou o dia: tudo o que foi avisado, disparado ou cancelado
            // pertence a ontem.
            if marca.dia != dia {
                *marca = Marca {
                    dia,
                    ..Default::default()
                };
            }
            if !item.roda_hoje(semana) || marca.cancelado || marca.disparado {
                continue;
            }

            let faltam = item.minuto_do_dia() - agora;

            // Aviso primeiro: com o relógio batendo a cada poucos segundos, o
            // mesmo ciclo nunca avisa e dispara junto - são minutos diferentes.
            if faltam > 0 && faltam <= AVISO_MINUTOS && !marca.avisado {
                marca.avisado = true;
                eventos.push(Evento::Avisar {
                    id: item.id.clone(),
                    nome: item.nome.clone(),
                    faltam,
                });
                continue;
            }

            // `faltam` negativo é atraso. A folga cobre o relógio que só bate
            // de dez em dez segundos; além dela, o computador estava desligado
            // e o dia passou.
            if (-ATRASO_MAXIMO_MINUTOS..=0).contains(&faltam) {
                marca.disparado = true;
                eventos.push(Evento::Disparar {
                    id: item.id.clone(),
                    nome: item.nome.clone(),
                    passos: item.passos.clone(),
                });
            } else if faltam < -ATRASO_MAXIMO_MINUTOS {
                // Perdeu o dia. Marcar evita que ela dispare se alguém mexer no
                // relógio para trás.
                marca.disparado = true;
            }
        }
        eventos
    }
}

/// O relógio local: `(dia, dia da semana com segunda = 0, minuto do dia)`.
///
/// **Local, e não UTC.** "18:00" é dezoito horas onde a máquina está; um agente
/// que decidisse em UTC fecharia tudo às 15h no Brasil.
///
/// O `dia` é `AAAAMMDD`: não serve para conta nenhuma, só para saber que virou
/// o dia — e para isso um número que muda à meia-noite basta.
#[cfg(windows)]
pub fn agora_local() -> Option<(u32, u8, u16)> {
    #[repr(C)]
    #[derive(Default)]
    struct SystemTime {
        ano: u16,
        mes: u16,
        dia_da_semana: u16,
        dia: u16,
        hora: u16,
        minuto: u16,
        segundo: u16,
        milissegundos: u16,
    }

    #[link(name = "kernel32")]
    extern "system" {
        fn GetLocalTime(saida: *mut SystemTime);
    }

    let mut t = SystemTime::default();
    unsafe { GetLocalTime(&mut t) };
    // O Windows conta o domingo como 0; aqui a semana começa na segunda, que é
    // como o app apresenta os dias.
    let semana = ((t.dia_da_semana + 6) % 7) as u8;
    let dia = t.ano as u32 * 10_000 + t.mes as u32 * 100 + t.dia as u32;
    Some((dia, semana, t.hora * 60 + t.minuto))
}

#[cfg(not(windows))]
pub fn agora_local() -> Option<(u32, u8, u16)> {
    None
}

#[cfg(test)]
mod tests {
    use super::*;

    fn item(id: &str, hora: u8, minuto: u8, dias: Vec<u8>) -> Item {
        Item {
            id: id.into(),
            nome: format!("automação {id}"),
            hora,
            minuto,
            dias,
            passos: Vec::new(),
        }
    }

    fn agenda(itens: Vec<Item>) -> Agenda {
        let mut a = Agenda::default();
        a.substituir(itens);
        a
    }

    const SEG: u8 = 0;
    const SAB: u8 = 5;
    const HOJE: u32 = 20_260_812;

    #[test]
    fn avisa_cinco_minutos_antes_e_uma_vez_so() {
        let mut a = agenda(vec![item("x", 18, 0, vec![])]);
        // 17:54 — ainda não.
        assert!(a.avaliar(HOJE, SEG, 17 * 60 + 54).is_empty());
        // 17:55 — avisa.
        let eventos = a.avaliar(HOJE, SEG, 17 * 60 + 55);
        assert!(matches!(eventos[..], [Evento::Avisar { faltam: 5, .. }]));
        // 17:56 — o relógio bate de novo e **não** avisa outra vez. Sem isto o
        // aviso reapareceria a cada poucos segundos por cinco minutos.
        assert!(a.avaliar(HOJE, SEG, 17 * 60 + 56).is_empty());
    }

    #[test]
    fn dispara_na_hora() {
        let mut a = agenda(vec![item("x", 18, 0, vec![])]);
        a.avaliar(HOJE, SEG, 17 * 60 + 55);
        let eventos = a.avaliar(HOJE, SEG, 18 * 60);
        assert!(matches!(eventos[..], [Evento::Disparar { .. }]));
        // E não dispara duas vezes no mesmo dia.
        assert!(a.avaliar(HOJE, SEG, 18 * 60).is_empty());
    }

    #[test]
    fn cancelar_vale_so_para_hoje() {
        // O ponto do recurso: "hoje eu não quero" não pode virar "nunca mais".
        let mut a = agenda(vec![item("x", 18, 0, vec![])]);
        a.avaliar(HOJE, SEG, 17 * 60 + 55);
        a.cancelar("x", HOJE);
        assert!(a.avaliar(HOJE, SEG, 18 * 60).is_empty());

        // Amanhã, mesma hora: roda.
        let amanha = HOJE + 1;
        let eventos = a.avaliar(amanha, SEG + 1, 18 * 60);
        assert!(matches!(eventos[..], [Evento::Disparar { .. }]));
    }

    #[test]
    fn computador_que_estava_desligado_nao_dispara_no_dia_seguinte() {
        // Ligar a máquina às 19h e ver o "fim de expediente" das 18h fechar
        // tudo seria pior do que ele não ter rodado: a pessoa acabou de sentar.
        let mut a = agenda(vec![item("x", 18, 0, vec![])]);
        assert!(a.avaliar(HOJE, SEG, 19 * 60).is_empty());
        // E continua não disparando quando o relógio bate de novo.
        assert!(a.avaliar(HOJE, SEG, 19 * 60 + 1).is_empty());
    }

    #[test]
    fn a_folga_cobre_o_relogio_que_bate_devagar() {
        // O laço olha a agenda a cada poucos segundos, não a cada minuto: o
        // instante exato das 18:00 pode simplesmente não ser observado.
        let mut a = agenda(vec![item("x", 18, 0, vec![])]);
        let eventos = a.avaliar(HOJE, SEG, 18 * 60 + 1);
        assert!(matches!(eventos[..], [Evento::Disparar { .. }]));
    }

    #[test]
    fn respeita_os_dias_da_semana() {
        let mut a = agenda(vec![item("x", 18, 0, vec![0, 1, 2, 3, 4])]);
        assert!(a.avaliar(HOJE, SAB, 18 * 60).is_empty());
        assert!(!a.avaliar(HOJE, SEG, 18 * 60).is_empty());
    }

    #[test]
    fn lista_vazia_de_dias_significa_todos() {
        let mut a = agenda(vec![item("x", 18, 0, vec![])]);
        assert!(!a.avaliar(HOJE, SAB, 18 * 60).is_empty());
    }

    #[test]
    fn trocar_a_agenda_esquece_quem_saiu() {
        // Uma automação apagada não pode deixar para trás um "já disparou hoje"
        // que confundiria outra criada depois com o mesmo identificador.
        let mut a = agenda(vec![item("x", 18, 0, vec![])]);
        a.avaliar(HOJE, SEG, 18 * 60);
        a.substituir(vec![item("y", 9, 0, vec![])]);
        assert_eq!(a.marcas.len(), 0);

        a.substituir(vec![item("x", 18, 0, vec![])]);
        let eventos = a.avaliar(HOJE, SEG, 18 * 60);
        assert!(matches!(eventos[..], [Evento::Disparar { .. }]));
    }

    #[test]
    fn horario_malformado_e_descartado() {
        // Aceitar com um horário inventado seria pior: uma automação que não
        // aparece na lista é um problema visível; uma que dispara às 00:00 por
        // causa de um `parse` falho é um problema que ninguém liga à causa.
        let bruto = |t: &str| crate::protocol::AgendaItem {
            id: "x".into(),
            name: "n".into(),
            time: t.into(),
            days: vec![],
            steps: vec![],
        };
        assert!(Item::do_protocolo(&bruto("18:00")).is_some());
        assert!(Item::do_protocolo(&bruto("25:00")).is_none());
        assert!(Item::do_protocolo(&bruto("18h00")).is_none());
        assert!(Item::do_protocolo(&bruto("")).is_none());
        // Dia fora da semana some, e o resto do item continua valendo.
        let com_dia_ruim = crate::protocol::AgendaItem {
            days: vec![0, 9, 3],
            ..bruto("07:30")
        };
        assert_eq!(Item::do_protocolo(&com_dia_ruim).unwrap().dias, vec![0, 3]);
    }

    #[test]
    fn agenda_vazia_nao_faz_nada() {
        let mut a = Agenda::default();
        assert!(a.avaliar(HOJE, SEG, 18 * 60).is_empty());
    }
}
