//! Manter o computador pronto para ser controlado de longe.
//!
//! O problema que isto resolve não é técnico, é de instalação. Acordar uma
//! máquina adormecida exige Wake-on-LAN, e Wake-on-LAN exige a placa de rede
//! armada no firmware e no driver - coisas que variam de computador para
//! computador e que nenhum programa consegue configurar por conta própria.
//! Nenhum produto resolveu isso, porque não é resolvível por software: uma
//! máquina desligada não roda software.
//!
//! A saída é inverter a pergunta. Em vez de "como acordar de qualquer jeito",
//! **não deixar adormecer** - e isso, sim, é genérico. O Windows tem uma API
//! para exatamente este pedido desde o XP, ela não pede administrador, não
//! mexe no plano de energia de ninguém e desaparece sozinha quando o agente
//! sai. A tela continua apagando, que é de onde vem quase toda a economia.
//!
//! O Wake-on-LAN continua existindo e não muda: ele cobre o que fica de fora
//! daqui - tampa fechada, desligamento manual, queda de energia.

/// De onde vem a energia do computador agora.
#[derive(Debug, Clone, Copy, PartialEq, Eq, serde::Serialize, serde::Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum PowerSource {
    /// Na tomada.
    Ac,
    /// Na bateria.
    Battery,
    /// Não deu para saber. Acontece em máquina virtual e em placa-mãe que não
    /// expõe o estado.
    Unknown,
}

/// Decide se o pedido de "não durma" deve estar de pé.
///
/// **`Unknown` conta como tomada.** Os dois erros possíveis aqui não custam a
/// mesma coisa: segurar quando não devia gasta alguns watts, e não segurar
/// quando devia faz o computador sumir do app - que é exatamente o que este
/// módulo existe para impedir. Quem não sabe responder é quase sempre um
/// computador de mesa ou uma máquina virtual, e nenhum dos dois tem bateria
/// para drenar.
pub fn should_hold(enabled: bool, source: PowerSource) -> bool {
    enabled && source != PowerSource::Battery
}

/// De onde vem a energia agora (stub fora do Windows).
pub fn power_source() -> PowerSource {
    imp::power_source()
}

/// Carga da bateria em porcentagem, ou nada quando não há bateria.
///
/// Mora aqui, e não no `system_info`, porque a chamada do sistema é a mesma que
/// o "manter pronto" já faz para saber se está na tomada — e duas declarações
/// da mesma estrutura do Windows em arquivos diferentes é o tipo de duplicação
/// que só se descobre errada no dia em que uma das duas muda.
pub fn battery_percent() -> Option<u8> {
    imp::battery_percent()
}

/// Segura o computador acordado enquanto existir.
///
/// O pedido vive numa **thread própria**, e não é capricho: no Windows o
/// `SetThreadExecutionState` vale para a thread que o fez e morre junto com
/// ela. Chamando de dentro do `tokio`, o pedido cairia na thread de trabalho
/// que estivesse à mão - e o tempo de vida dele passaria a depender de um
/// detalhe do escalonador. O sintoma seria o pior possível: funciona nos
/// testes, e o computador dorme algumas horas depois.
pub struct Keeper {
    /// `None` quando a thread não pôde ser criada. O agente segue funcionando;
    /// só este recurso fica de fora.
    tx: Option<std::sync::mpsc::Sender<bool>>,
    holding: bool,
}

impl Keeper {
    pub fn new() -> Self {
        let (tx, rx) = std::sync::mpsc::channel::<bool>();
        let thread = std::thread::Builder::new()
            .name("deskside-awake".into())
            .spawn(move || {
                for want in rx {
                    imp::set(want);
                }
                // O canal fechou: o agente está saindo. Solta o pedido antes de
                // morrer para não depender de o Windows limpar a thread.
                imp::set(false);
            });
        match thread {
            Ok(_) => Self {
                tx: Some(tx),
                holding: false,
            },
            Err(e) => {
                eprintln!("Não consegui criar a thread que mantém o computador acordado: {e}");
                Self {
                    tx: None,
                    holding: false,
                }
            }
        }
    }

    /// Liga ou desliga o pedido. Só fala com a thread quando o estado muda -
    /// esta função é chamada a cada batida do relógio, e repetir o pedido a
    /// cada 30 segundos não teria efeito nenhum além de encher o console.
    pub fn set(&mut self, want: bool) {
        if want == self.holding {
            return;
        }
        let Some(tx) = &self.tx else { return };
        if tx.send(want).is_err() {
            return;
        }
        self.holding = want;
        if want {
            println!("Mantendo o computador acordado (tela continua apagando normalmente)");
        } else {
            println!("Soltando o computador: ele volta a poder suspender");
        }
    }

    /// Se o pedido está de pé agora. É o que o app mostra.
    pub fn holding(&self) -> bool {
        self.holding
    }
}

impl Default for Keeper {
    fn default() -> Self {
        Self::new()
    }
}

#[cfg(windows)]
mod imp {
    use super::PowerSource;

    // Deixa o sistema acordado, mas **não** a tela: `ES_DISPLAY_REQUIRED` fica
    // de fora de propósito. A captura funciona com o painel apagado, e é o
    // backlight que responde por quase todo o consumo.
    const ES_CONTINUOUS: u32 = 0x8000_0000;
    const ES_SYSTEM_REQUIRED: u32 = 0x0000_0001;

    #[repr(C)]
    struct SystemPowerStatus {
        ac_line_status: u8,
        battery_flag: u8,
        battery_life_percent: u8,
        system_status_flag: u8,
        battery_life_time: u32,
        battery_full_life_time: u32,
    }

    #[link(name = "kernel32")]
    extern "system" {
        fn SetThreadExecutionState(flags: u32) -> u32;
        fn GetSystemPowerStatus(status: *mut SystemPowerStatus) -> i32;
    }

    pub fn set(hold: bool) {
        // Sem `ES_CONTINUOUS` a chamada valeria uma vez só, como "estou ocupado
        // agora"; com ele, vale até alguém dizer o contrário. Soltar é mandar
        // `ES_CONTINUOUS` sozinho.
        let flags = if hold {
            ES_CONTINUOUS | ES_SYSTEM_REQUIRED
        } else {
            ES_CONTINUOUS
        };
        // Devolve o estado anterior, e **zero** significa erro.
        if unsafe { SetThreadExecutionState(flags) } == 0 {
            eprintln!("O Windows recusou o pedido de manter o computador acordado");
        }
    }

    pub fn power_source() -> PowerSource {
        let mut status = SystemPowerStatus {
            ac_line_status: 255,
            battery_flag: 0,
            battery_life_percent: 0,
            system_status_flag: 0,
            battery_life_time: 0,
            battery_full_life_time: 0,
        };
        if unsafe { GetSystemPowerStatus(&mut status) } == 0 {
            return PowerSource::Unknown;
        }
        match status.ac_line_status {
            0 => PowerSource::Battery,
            1 => PowerSource::Ac,
            // 255 = o sistema não sabe. É o valor documentado, não um erro.
            _ => PowerSource::Unknown,
        }
    }

    pub fn battery_percent() -> Option<u8> {
        let mut status = SystemPowerStatus {
            ac_line_status: 255,
            battery_flag: 0,
            battery_life_percent: 255,
            system_status_flag: 0,
            battery_life_time: 0,
            battery_full_life_time: 0,
        };
        if unsafe { GetSystemPowerStatus(&mut status) } == 0 {
            return None;
        }
        // 255 = desconhecido, e o bit 128 do `battery_flag` diz "não há
        // bateria" - o caso do computador de mesa. Nos dois, mostrar 0% seria
        // pior que não mostrar nada: parece bateria acabando.
        if status.battery_life_percent > 100 || status.battery_flag & 128 != 0 {
            return None;
        }
        Some(status.battery_life_percent)
    }
}

#[cfg(not(windows))]
mod imp {
    use super::PowerSource;

    pub fn set(hold: bool) {
        println!("[awake-stub] manter acordado = {hold} (ignorado fora do Windows)");
    }

    pub fn power_source() -> PowerSource {
        PowerSource::Unknown
    }

    pub fn battery_percent() -> Option<u8> {
        None
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn desligado_nunca_segura() {
        for source in [PowerSource::Ac, PowerSource::Battery, PowerSource::Unknown] {
            assert!(!should_hold(false, source));
        }
    }

    #[test]
    fn segura_na_tomada() {
        assert!(should_hold(true, PowerSource::Ac));
    }

    #[test]
    fn solta_na_bateria() {
        assert!(!should_hold(true, PowerSource::Battery));
    }

    #[test]
    fn desconhecido_conta_como_tomada() {
        // Um computador de mesa não tem bateria para drenar, e sumir do app é
        // pior que gastar alguns watts.
        assert!(should_hold(true, PowerSource::Unknown));
    }

    #[test]
    fn keeper_comeca_solto_e_registra_a_troca() {
        let mut k = Keeper::new();
        assert!(!k.holding());
        k.set(true);
        assert!(k.holding());
        // Repetir não muda nada e não deve quebrar.
        k.set(true);
        assert!(k.holding());
        k.set(false);
        assert!(!k.holding());
    }
}
