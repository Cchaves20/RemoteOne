//! Métricas do computador: CPU, memória e disco.
//!
//! Usa o `sysinfo`, que é multiplataforma — diferente da captura e da injeção
//! de entrada, este módulo não precisa de stub: o mesmo código roda no Windows,
//! no Linux e no macOS, e por isso é verificado pelo `cargo check` daqui.

use serde::{Deserialize, Serialize};

/// Uma leitura das métricas, pronta para ir ao app.
///
/// Bytes, e não "GB", de propósito: quem formata é o app, que sabe o idioma do
/// usuário. Converter aqui obrigaria a mandar texto e perderia a precisão.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct SystemSnapshot {
    /// Uso de CPU somando todos os núcleos, em porcentagem (0–100).
    pub cpu_percent: f32,
    pub memory_used: u64,
    pub memory_total: u64,
    pub disk_used: u64,
    pub disk_total: u64,
    /// Nome do disco medido (`C:` no Windows, `/` no Linux), para o app poder
    /// dizer *qual* disco está mostrando.
    pub disk_name: String,
    /// Há quanto tempo o computador está ligado.
    pub uptime_seconds: u64,

    // --- as quatro medidas que faltavam para fechar o painel do documento ---
    //
    // Todas opcionais, e não por preguiça: cada uma delas simplesmente não
    // existe em algum computador legítimo. Desktop não tem bateria; máquina
    // virtual não tem GPU dedicada; e temperatura, no Windows, quase sempre
    // depende de um driver do fabricante. Mandar zero em vez de "não sei"
    // seria mentir - o app **esconde** a medida ausente em vez de mostrar 0.
    /// Uso da GPU em porcentagem, somando os motores de renderização.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub gpu_percent: Option<f32>,
    /// Nome da placa de vídeo, para o painel dizer de qual GPU se trata.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub gpu_name: Option<String>,
    /// Temperatura mais alta encontrada, em graus Celsius.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub temperature_celsius: Option<f32>,
    /// Bytes por segundo entrando e saindo, somando todas as interfaces.
    #[serde(default)]
    pub network_rx_bps: u64,
    #[serde(default)]
    pub network_tx_bps: u64,
    /// Carga da bateria (0–100). Ausente em quem não tem bateria.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub battery_percent: Option<u8>,
    /// Se está na bateria agora. Ausente quando o sistema não sabe responder.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub on_battery: Option<bool>,
}

/// Fonte das métricas, mantida **viva** entre as leituras.
///
/// É preciso ser persistente por causa da CPU: o `sysinfo` não mede um instante,
/// mede a diferença entre duas leituras. Um `System` novo a cada pedido
/// devolveria sempre 0%. Guardando-o, cada leitura cobre o intervalo desde a
/// anterior — que com o app pesquisando a cada 2 s dá uma média mais honesta que
/// uma amostra instantânea.
pub struct Monitor {
    system: sysinfo::System,
    disks: sysinfo::Disks,
    /// Quando a CPU foi lida pela última vez, para respeitar o intervalo mínimo.
    last_cpu: std::time::Instant,
    networks: sysinfo::Networks,
    /// Quando a rede foi lida pela última vez. O `sysinfo` entrega **bytes
    /// desde a última leitura**, não uma taxa; sem o intervalo não dá para
    /// dividir, e o número viraria "quanto passou desde sabe-se lá quando".
    last_net: std::time::Instant,
    components: sysinfo::Components,
    /// GPU e temperatura no Windows, medidas fora do caminho crítico.
    sonda: sonda::Sonda,
}

impl Monitor {
    /// Cria o monitor e já tira a leitura de referência da CPU.
    ///
    /// A referência sai aqui, e não na primeira leitura de verdade, para que
    /// ninguém pague a espera de 200 ms no meio da transmissão: o agente cria o
    /// monitor ao conectar e o usuário abre o painel bem depois disso.
    pub fn new() -> Self {
        let refresh = sysinfo::RefreshKind::nothing()
            .with_cpu(sysinfo::CpuRefreshKind::nothing().with_cpu_usage())
            .with_memory(sysinfo::MemoryRefreshKind::nothing().with_ram());
        let mut system = sysinfo::System::new_with_specifics(refresh);
        system.refresh_cpu_usage();
        Self {
            system,
            disks: sysinfo::Disks::new_with_refreshed_list(),
            last_cpu: std::time::Instant::now(),
            networks: sysinfo::Networks::new_with_refreshed_list(),
            last_net: std::time::Instant::now(),
            components: sysinfo::Components::new_with_refreshed_list(),
            sonda: sonda::Sonda::new(),
        }
    }

    /// Lê as métricas agora.
    ///
    /// Só espera se a leitura anterior foi há menos de 200 ms — o intervalo
    /// mínimo que o `sysinfo` exige para a CPU. Sem ele o valor viria 0%, que o
    /// usuário leria como "meu PC está livre": pior que esperar.
    pub fn snapshot(&mut self) -> SystemSnapshot {
        let elapsed = self.last_cpu.elapsed();
        if elapsed < sysinfo::MINIMUM_CPU_UPDATE_INTERVAL {
            std::thread::sleep(sysinfo::MINIMUM_CPU_UPDATE_INTERVAL - elapsed);
        }
        self.system.refresh_cpu_usage();
        self.system.refresh_memory();
        self.last_cpu = std::time::Instant::now();
        // `false`: mantém na lista os discos que sumiram (pendrive removido) em
        // vez de recriar a enumeração, que é a parte cara.
        self.disks.refresh(false);

        let (disk_name, disk_total, disk_used) = match main_disk(&self.disks) {
            Some(disk) => (
                disk_label(disk),
                disk.total_space(),
                disk.total_space().saturating_sub(disk.available_space()),
            ),
            None => (String::new(), 0, 0),
        };

        // Rede: o `sysinfo` dá bytes acumulados desde a leitura anterior, e o
        // que interessa na tela é taxa. A divisão pelo intervalo real (e não
        // pelos 2 s que o app costuma usar) é o que mantém o número honesto
        // quando o pedido atrasa.
        let intervalo = self.last_net.elapsed();
        self.networks.refresh(false);
        self.last_net = std::time::Instant::now();
        let (rx, tx) = taxa_de_rede(&self.networks, intervalo);

        // Temperatura pelo caminho multiplataforma. No Linux funciona; no
        // Windows costuma vir vazia, e aí quem responde é a sonda.
        self.components.refresh(false);
        let temperatura = temperatura_mais_alta(&self.components);

        let extras = self.sonda.ler();
        let energia = crate::awake::power_source();

        SystemSnapshot {
            // Uma casa decimal: o resto é ruído de amostragem, e a diferença
            // entre 37,4% e 37,42% não muda decisão nenhuma.
            cpu_percent: (self.system.global_cpu_usage() * 10.0).round() / 10.0,
            memory_used: self.system.used_memory(),
            memory_total: self.system.total_memory(),
            disk_used,
            disk_total,
            disk_name,
            uptime_seconds: sysinfo::System::uptime(),
            gpu_percent: extras.gpu_percent,
            gpu_name: extras.gpu_name,
            temperature_celsius: temperatura.or(extras.temperature_celsius),
            network_rx_bps: rx,
            network_tx_bps: tx,
            battery_percent: crate::awake::battery_percent(),
            on_battery: match energia {
                crate::awake::PowerSource::Battery => Some(true),
                crate::awake::PowerSource::Ac => Some(false),
                crate::awake::PowerSource::Unknown => None,
            },
        }
    }
}

/// Soma o tráfego de todas as interfaces e converte em bytes por segundo.
///
/// Soma tudo em vez de escolher "a interface principal" porque escolher exige
/// adivinhar: num notebook com Wi-Fi e cabo, com uma VPN por cima e o adaptador
/// virtual do WSL ao lado, qualquer critério erra em alguma máquina. A soma
/// responde à pergunta que a pessoa está fazendo — "está passando tráfego?".
///
/// Intervalo zero devolve zero, e não infinito: acontece quando duas leituras
/// caem no mesmo instante do relógio.
fn taxa_de_rede(networks: &sysinfo::Networks, intervalo: std::time::Duration) -> (u64, u64) {
    let segundos = intervalo.as_secs_f64();
    if segundos <= 0.0 {
        return (0, 0);
    }
    let mut rx = 0u64;
    let mut tx = 0u64;
    for (_, dados) in networks.iter() {
        rx = rx.saturating_add(dados.received());
        tx = tx.saturating_add(dados.transmitted());
    }
    (
        (rx as f64 / segundos).round() as u64,
        (tx as f64 / segundos).round() as u64,
    )
}

/// A temperatura mais alta entre os sensores, ou nada quando não há sensor.
///
/// A mais alta, e não a média: quem olha temperatura quer saber se algo está
/// esquentando, e uma média com oito sensores frios esconde exatamente o
/// sensor que importa.
fn temperatura_mais_alta(components: &sysinfo::Components) -> Option<f32> {
    components
        .iter()
        .filter_map(|c| c.temperature())
        // Sensor que responde 0 °C ou algo impossível é sensor quebrado, e um
        // número absurdo na tela é pior que medida nenhuma.
        .filter(|t| *t > 1.0 && *t < 150.0)
        .fold(None, |maior: Option<f32>, t| {
            Some(match maior {
                Some(m) if m >= t => m,
                _ => t,
            })
        })
        .map(|t| (t * 10.0).round() / 10.0)
}

impl Default for Monitor {
    fn default() -> Self {
        Self::new()
    }
}

/// O disco a mostrar quando só cabe um número na tela.
///
/// Prefere o disco do sistema pelo ponto de montagem; se não achar (letra
/// diferente, montagem incomum), cai para o maior disco fixo — nunca um pendrive,
/// que apareceria e desapareceria da tela sem explicação.
fn main_disk(disks: &sysinfo::Disks) -> Option<&sysinfo::Disk> {
    let system_mount = if cfg!(windows) { "C:\\" } else { "/" };
    disks
        .list()
        .iter()
        .find(|d| d.mount_point().to_string_lossy() == system_mount)
        .or_else(|| {
            disks
                .list()
                .iter()
                .filter(|d| !d.is_removable())
                .max_by_key(|d| d.total_space())
        })
}

/// Nome curto do disco: `C:` em vez de `C:\`, e o ponto de montagem no resto.
fn disk_label(disk: &sysinfo::Disk) -> String {
    let mount = disk.mount_point().to_string_lossy();
    mount.trim_end_matches('\\').to_string()
}

/// GPU e temperatura: as duas medidas que o `sysinfo` não dá no Windows.
///
/// Existem separadas do resto por causa do **custo**. CPU, memória e disco
/// saem de chamadas diretas do sistema e custam microssegundos; GPU sai de
/// uma consulta ao WMI, que abre um processo do PowerShell e leva de meio
/// segundo a dois. O painel do app pergunta de 2 em 2 segundos, e uma leitura
/// que às vezes demora mais do que o intervalo entre pedidos não pode ficar no
/// caminho das outras.
///
/// Por isso a sonda é **assíncrona e preguiçosa**: `ler()` devolve na hora o
/// último valor conhecido e, se ele estiver velho, dispara uma medição nova em
/// segundo plano para a próxima vez. Consequências assumidas:
///
/// - O primeiro pedido depois de abrir o painel vem sem GPU. Aparece no
///   segundo, uns segundos depois, e ninguém percebe.
/// - Com o painel fechado, ninguém chama `ler()` e nenhum PowerShell roda -
///   o custo existe só enquanto alguém está olhando.
pub mod sonda {
    /// O que a sonda consegue descobrir. Tudo opcional: nenhuma destas medidas
    /// existe em toda máquina.
    #[derive(Debug, Clone, Default, PartialEq)]
    pub struct Extras {
        pub gpu_percent: Option<f32>,
        pub gpu_name: Option<String>,
        pub temperature_celsius: Option<f32>,
    }

    /// De quanto em quanto tempo vale a pena medir de novo.
    ///
    /// Cinco segundos, e não os 2 s do painel: uso de GPU não muda de forma
    /// interessante mais rápido que isso, e cada medição custa um processo.
    const VALIDADE: std::time::Duration = std::time::Duration::from_secs(5);

    pub struct Sonda {
        estado: std::sync::Arc<std::sync::Mutex<(Extras, Option<std::time::Instant>)>>,
        /// Impede duas medições ao mesmo tempo. Sem isto, um painel aberto em
        /// dois aparelhos dobraria os processos do PowerShell.
        medindo: std::sync::Arc<std::sync::atomic::AtomicBool>,
    }

    impl Sonda {
        pub fn new() -> Self {
            Self {
                estado: std::sync::Arc::new(std::sync::Mutex::new((Extras::default(), None))),
                medindo: std::sync::Arc::new(std::sync::atomic::AtomicBool::new(false)),
            }
        }

        /// O último valor conhecido, e um pedido de atualização se ele envelheceu.
        pub fn ler(&self) -> Extras {
            let (extras, quando) = match self.estado.lock() {
                Ok(guarda) => guarda.clone(),
                // Mutex envenenado: uma medição anterior entrou em pânico. Não
                // é motivo para derrubar o painel inteiro.
                Err(_) => return Extras::default(),
            };
            let velho = quando.map(|q| q.elapsed() >= VALIDADE).unwrap_or(true);
            if velho {
                self.disparar();
            }
            extras
        }

        /// Mede em segundo plano, no máximo uma medição por vez.
        fn disparar(&self) {
            use std::sync::atomic::Ordering;
            // `swap` e não `load`+`store`: entre ler e escrever caberia uma
            // segunda thread, e o ponto do sinalizador é justamente não haver
            // duas medições ao mesmo tempo.
            if self.medindo.swap(true, Ordering::SeqCst) {
                return;
            }
            let estado = std::sync::Arc::clone(&self.estado);
            let medindo = std::sync::Arc::clone(&self.medindo);
            let criada = std::thread::Builder::new()
                .name("deskside-sonda".into())
                .spawn(move || {
                    let extras = imp::medir();
                    if let Ok(mut guarda) = estado.lock() {
                        *guarda = (extras, Some(std::time::Instant::now()));
                    }
                    medindo.store(false, Ordering::SeqCst);
                });
            // Sem thread, sem medida - e o sinalizador tem que voltar, senão a
            // sonda ficaria travada em "medindo" para sempre.
            if criada.is_err() {
                self.medindo.store(false, Ordering::SeqCst);
            }
        }
    }

    impl Default for Sonda {
        fn default() -> Self {
            Self::new()
        }
    }

    /// Lê a resposta da consulta, no formato `gpu|nome|temperatura`.
    ///
    /// Separado da chamada ao sistema porque é aqui que mora o erro possível, e
    /// é a única parte que dá para testar fora do Windows. Campo vazio é
    /// resposta normal e vira `None` - a máquina pode não ter GPU dedicada, e
    /// a temperatura falta na maioria dos Windows.
    pub fn interpretar(saida: &str) -> Extras {
        let linha = saida.trim();
        if linha.is_empty() {
            return Extras::default();
        }
        let mut campos = linha.split('|');
        let gpu = campos.next().unwrap_or("").trim();
        let nome = campos.next().unwrap_or("").trim();
        let temp = campos.next().unwrap_or("").trim();

        Extras {
            gpu_percent: gpu
                // O PowerShell escreve decimal com vírgula quando o Windows
                // está em português. Trocar aqui é mais barato que forçar a
                // cultura invariante no script.
                .replace(',', ".")
                .parse::<f32>()
                .ok()
                .filter(|v| v.is_finite() && *v >= 0.0)
                .map(|v| (v.min(100.0) * 10.0).round() / 10.0),
            gpu_name: (!nome.is_empty()).then(|| nome.to_string()),
            // O WMI devolve décimos de Kelvin. Um valor fora da faixa possível
            // é sensor mentindo, e vale mais não mostrar nada.
            temperature_celsius: temp
                .parse::<f32>()
                .ok()
                .map(|k| k / 10.0 - 273.15)
                .filter(|c| *c > 1.0 && *c < 150.0)
                .map(|c| (c * 10.0).round() / 10.0),
        }
    }

    #[cfg(windows)]
    mod imp {
        /// Consulta o WMI pelo PowerShell.
        ///
        /// Usa as classes de contador do WMI
        /// (`Win32_PerfFormattedData_GPUPerformanceCounters_GPUEngine`) e não o
        /// `Get-Counter`. A diferença não é estilo: **os nomes dos contadores
        /// de desempenho são traduzidos**, e `'\GPU Engine(*)\Utilization
        /// Percentage'` simplesmente não existe num Windows em português. Nome
        /// de classe do WMI é o mesmo em qualquer idioma.
        ///
        /// Só os motores `engtype_3D`: a lista traz um contador por motor
        /// (cópia, decodificação de vídeo, computação), e somar todos daria
        /// bem mais de 100%.
        const SCRIPT: &str = r#"
$ErrorActionPreference = 'SilentlyContinue'
$uso = (Get-CimInstance Win32_PerfFormattedData_GPUPerformanceCounters_GPUEngine |
    Where-Object { $_.Name -like '*engtype_3D*' } |
    Measure-Object -Property UtilizationPercentage -Sum).Sum
$nome = (Get-CimInstance Win32_VideoController | Select-Object -First 1).Name
$temp = (Get-CimInstance -Namespace root/wmi -ClassName MSAcpi_ThermalZoneTemperature |
    Select-Object -First 1).CurrentTemperature
"$uso|$nome|$temp"
"#;

        pub fn medir() -> super::Extras {
            match crate::apps::run_powershell(SCRIPT) {
                Ok(saida) => super::interpretar(&String::from_utf8_lossy(&saida.stdout)),
                Err(_) => super::Extras::default(),
            }
        }
    }

    #[cfg(not(windows))]
    mod imp {
        /// Fora do Windows a temperatura já vem do `sysinfo`, e GPU não há como
        /// medir sem uma dependência por fabricante. Devolve vazio.
        pub fn medir() -> super::Extras {
            super::Extras::default()
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn snapshot_traz_numeros_plausiveis() {
        let mut monitor = Monitor::new();
        let snap = monitor.snapshot();
        assert!(
            (0.0..=100.0).contains(&snap.cpu_percent),
            "cpu fora da faixa: {}",
            snap.cpu_percent
        );
        assert!(snap.memory_total > 0, "memória total não pode ser zero");
        assert!(snap.memory_used <= snap.memory_total);
        assert!(snap.disk_used <= snap.disk_total);
        assert!(snap.uptime_seconds > 0);
    }

    #[test]
    fn leitura_espacada_nao_espera_o_intervalo_minimo() {
        // O painel do app atualiza a cada 2 s. Se cada leitura pagasse os 200 ms
        // de intervalo mínimo, seria 10% do tempo do agente parado à toa.
        let mut monitor = Monitor::new();
        std::thread::sleep(sysinfo::MINIMUM_CPU_UPDATE_INTERVAL);
        let started = std::time::Instant::now();
        monitor.snapshot();
        assert!(
            started.elapsed() < sysinfo::MINIMUM_CPU_UPDATE_INTERVAL,
            "a leitura demorou {:?}",
            started.elapsed()
        );
    }

    #[test]
    fn leitura_imediata_ainda_respeita_o_intervalo() {
        // Pedir logo depois de criar o monitor não pode devolver 0% falso: aqui
        // a espera é obrigatória, e é o único caso em que ela acontece.
        let mut monitor = Monitor::new();
        let started = std::time::Instant::now();
        monitor.snapshot();
        assert!(
            started.elapsed() >= sysinfo::MINIMUM_CPU_UPDATE_INTERVAL,
            "não esperou o intervalo mínimo: {:?}",
            started.elapsed()
        );
    }

    #[test]
    fn a_sonda_le_a_resposta_completa() {
        let e = sonda::interpretar("37,5|NVIDIA GeForce RTX 3060|3132\n");
        assert_eq!(e.gpu_percent, Some(37.5));
        assert_eq!(e.gpu_name.as_deref(), Some("NVIDIA GeForce RTX 3060"));
        // 3132 décimos de Kelvin = 40,05 °C.
        assert_eq!(e.temperature_celsius, Some(40.1));
    }

    #[test]
    fn a_sonda_aceita_ponto_no_lugar_da_virgula() {
        // O separador decimal do PowerShell segue o idioma do Windows: vem
        // vírgula em português e ponto em inglês. Os dois têm de funcionar.
        assert_eq!(sonda::interpretar("37.5|x|").gpu_percent, Some(37.5));
    }

    #[test]
    fn campo_vazio_vira_ausencia_e_nao_zero() {
        // Máquina sem GPU dedicada e sem sensor de temperatura responde assim.
        // Zero apareceria na tela como "GPU parada" e "0 °C", que são medidas
        // erradas - e não é isso que aconteceu: não houve medida.
        let e = sonda::interpretar("||");
        assert_eq!(e.gpu_percent, None);
        assert_eq!(e.gpu_name, None);
        assert_eq!(e.temperature_celsius, None);
    }

    #[test]
    fn resposta_vazia_nao_quebra() {
        assert_eq!(sonda::interpretar("   "), sonda::Extras::default());
        assert_eq!(sonda::interpretar(""), sonda::Extras::default());
    }

    #[test]
    fn temperatura_impossivel_e_descartada() {
        // 0 décimo de Kelvin daria -273 °C; sensor desligado responde assim.
        assert_eq!(sonda::interpretar("0|x|0").temperature_celsius, None);
        // E 9000 décimos daria 626 °C.
        assert_eq!(sonda::interpretar("0|x|9000").temperature_celsius, None);
    }

    #[test]
    fn uso_de_gpu_nao_passa_de_cem() {
        // A soma dos motores 3D pode estourar 100 quando há duas placas.
        assert_eq!(sonda::interpretar("143,2|x|").gpu_percent, Some(100.0));
    }

    #[test]
    fn a_sonda_devolve_na_hora_mesmo_sem_medida_pronta() {
        // O ponto todo dela: o painel do app não pode esperar um processo do
        // PowerShell. A primeira leitura vem vazia e a medição fica para trás.
        let s = sonda::Sonda::new();
        let comeco = std::time::Instant::now();
        let _ = s.ler();
        assert!(
            comeco.elapsed() < std::time::Duration::from_millis(50),
            "a sonda bloqueou por {:?}",
            comeco.elapsed()
        );
    }

    #[test]
    fn intervalo_zero_nao_vira_taxa_infinita() {
        // Duas leituras no mesmo instante do relógio: dividir por zero daria
        // infinito, que no JSON vira `null` e some da tela sem explicação.
        let redes = sysinfo::Networks::new_with_refreshed_list();
        assert_eq!(
            taxa_de_rede(&redes, std::time::Duration::ZERO),
            (0, 0),
            "intervalo zero tem que dar taxa zero"
        );
    }

    #[test]
    fn a_taxa_de_rede_e_por_segundo() {
        // Não dá para forçar tráfego num teste, mas dá para garantir que a
        // divisão pelo intervalo acontece: com o dobro do tempo, a taxa não
        // pode ser maior.
        let redes = sysinfo::Networks::new_with_refreshed_list();
        let um = taxa_de_rede(&redes, std::time::Duration::from_secs(1));
        let dois = taxa_de_rede(&redes, std::time::Duration::from_secs(2));
        assert!(dois.0 <= um.0 && dois.1 <= um.1);
    }

    #[test]
    fn a_temperatura_fica_numa_faixa_plausivel() {
        // Aqui não há como saber se a máquina tem sensor; o que se garante é
        // que, havendo, o número não é absurdo - um sensor quebrado que
        // responde 0 °C ou 200 °C não pode chegar à tela.
        let comps = sysinfo::Components::new_with_refreshed_list();
        if let Some(t) = temperatura_mais_alta(&comps) {
            assert!(t > 1.0 && t < 150.0, "temperatura implausível: {t}");
        }
    }

    #[test]
    fn as_medidas_novas_sobrevivem_a_ida_e_volta_pelo_json() {
        // O app lê estes campos por nome. Um `serde` que não os serialize
        // deixaria o painel vazio sem erro nenhum aparecer.
        let mut monitor = Monitor::new();
        let s = monitor.snapshot();
        let json = serde_json::to_string(&s).unwrap();
        assert!(json.contains("network_rx_bps"), "{json}");
        assert!(json.contains("network_tx_bps"), "{json}");
        let volta: SystemSnapshot = serde_json::from_str(&json).unwrap();
        assert_eq!(volta, s);
    }

    #[test]
    fn medida_ausente_nao_ocupa_lugar_no_json() {
        // Campo opcional vazio não vai para o fio: são cinco campos que, num
        // computador de mesa, não existem - e eles viajam a cada 2 segundos.
        let s = SystemSnapshot {
            cpu_percent: 1.0,
            memory_used: 1,
            memory_total: 2,
            disk_used: 1,
            disk_total: 2,
            disk_name: "C:".into(),
            uptime_seconds: 10,
            gpu_percent: None,
            gpu_name: None,
            temperature_celsius: None,
            network_rx_bps: 0,
            network_tx_bps: 0,
            battery_percent: None,
            on_battery: None,
        };
        let json = serde_json::to_string(&s).unwrap();
        assert!(!json.contains("gpu_percent"), "{json}");
        assert!(!json.contains("battery_percent"), "{json}");
    }

    #[test]
    fn rotulo_do_disco_perde_a_barra_final() {
        // `C:\` é o ponto de montagem que o Windows reporta; na tela cabe `C:`.
        let disks = sysinfo::Disks::new_with_refreshed_list();
        for disk in disks.list() {
            let label = disk_label(disk);
            assert!(!label.ends_with('\\'), "rótulo com barra: {label}");
        }
    }
}
