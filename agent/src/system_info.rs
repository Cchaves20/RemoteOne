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
        }
    }
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
    fn rotulo_do_disco_perde_a_barra_final() {
        // `C:\` é o ponto de montagem que o Windows reporta; na tela cabe `C:`.
        let disks = sysinfo::Disks::new_with_refreshed_list();
        for disk in disks.list() {
            let label = disk_label(disk);
            assert!(!label.ends_with('\\'), "rótulo com barra: {label}");
        }
    }
}
