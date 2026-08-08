//! Núcleo do agente desktop do Deskside.
//!
//! A lógica portável (pareamento, protocolo, identidade, cliente) vive nesta
//! biblioteca e é testada em Windows, Linux e macOS pela CI. O binário
//! (`main.rs`) é apenas uma casca fina por cima dela.

pub mod adaptive;
pub mod apps;
pub mod audio;
pub mod awake;
pub mod brightness;
pub mod capture;
pub mod client;
pub mod clipboard;
pub mod config;
pub mod datachannel;
pub mod files;
pub mod foreground;
pub mod gui;
pub mod h264;
pub mod identity;
pub mod instance;
pub mod migracao;
pub mod injector;
pub mod input;
pub mod janelas;
pub mod lote;
pub mod notify;
pub mod pairing;
pub mod platform;
pub mod power;
pub mod protocol;
pub mod setup;
pub mod system_info;
pub mod webrtc;
pub mod wol;

use std::path::PathBuf;

/// Backend padrão quando ninguém configurou nada.
///
/// Aponta para o servidor do projeto, e não para `127.0.0.1`, porque é isso que
/// faz `deskside-agent install` sem argumento nenhum funcionar. O padrão
/// anterior era o backend da própria máquina - defensável para quem
/// desenvolve, e errado para todo o resto: instalar num computador que não roda
/// backend deixava o agente tentando falar com um servidor que não existe ali,
/// e a janela dizia "Sem conexão" sem dizer o motivo.
///
/// Enquanto o produto está em teste, esse servidor é um só e é conhecido. Na
/// hora de haver mais de um, isto vira uma escolha na instalação em vez de uma
/// constante.
///
/// `option_env!` para quem desenvolve não precisar editar este arquivo:
///
/// ```text
/// DESKSIDE_DEFAULT_BACKEND=ws://127.0.0.1:8000/ws/agent cargo build --release
/// ```
///
/// Continua valendo, em ordem, o que já valia: a variável de ambiente
/// `DESKSIDE_BACKEND_URL`, depois o `agent.conf`, e só então este padrão.
pub const DEFAULT_BACKEND_URL: &str = match option_env!("DESKSIDE_DEFAULT_BACKEND") {
    Some(url) => url,
    None => "wss://caio-remoteone.duckdns.org/ws/agent",
};

/// Diretório onde ficam o `device_id` e a configuração.
///
/// `%APPDATA%\deskside` no Windows, `~/.config/deskside` no restante.
/// Deliberadamente **fora** da pasta de instalação: reinstalar ou atualizar não
/// pode obrigar a parear o computador de novo.
pub fn config_dir() -> PathBuf {
    let base = std::env::var_os("DESKSIDE_CONFIG_DIR")
        .map(PathBuf::from)
        .or_else(platform_config_dir)
        .unwrap_or_else(|| PathBuf::from("."));
    base.join("deskside")
}

/// A pasta onde a configuração ficava quando o projeto se chamava RemoteOne.
///
/// Existe só para a migração automática (ver `migracao.rs`). Some daqui quando
/// não houver mais instalação antiga em campo.
pub fn config_dir_antiga() -> PathBuf {
    let base = std::env::var_os("DESKSIDE_CONFIG_DIR")
        .map(PathBuf::from)
        .or_else(platform_config_dir)
        .unwrap_or_else(|| PathBuf::from("."));
    base.join("remoteone")
}

/// Traz a configuração do nome antigo, se ainda não houver a nova.
///
/// Chamada uma vez, no início. **Não** fica escondida dentro de `config_dir()`:
/// função que devolve um caminho não deve mexer em disco - quem lê
/// `config_dir()` espera uma resposta, não um efeito colateral.
pub fn migrar_configuracao_antiga() {
    if migracao::migrar(&config_dir_antiga(), &config_dir()) {
        diario(&format!(
            "configuração migrada de {} para {}",
            config_dir_antiga().display(),
            config_dir().display()
        ));
    }
}

/// Diretório de configuração do sistema, sem dependência externa.
fn platform_config_dir() -> Option<PathBuf> {
    if cfg!(target_os = "windows") {
        std::env::var_os("APPDATA").map(PathBuf::from)
    } else {
        std::env::var_os("XDG_CONFIG_HOME")
            .map(PathBuf::from)
            .or_else(|| std::env::var_os("HOME").map(|h| PathBuf::from(h).join(".config")))
    }
}

pub fn device_id_path() -> PathBuf {
    config_dir().join("device_id")
}

pub fn config_path() -> PathBuf {
    config_dir().join("agent.conf")
}

/// A configuração gravada. Arquivo ausente é o caso normal da primeira
/// execução, e vira configuração vazia — não erro.
pub fn load_config() -> config::Config {
    match std::fs::read_to_string(config_path()) {
        Ok(texto) => config::Config::parse(&texto),
        Err(_) => config::Config::new(),
    }
}

/// Registra uma linha no diário do agente.
///
/// Existe porque o agente instalado roda **sem console**: sobe pelo `wscript`,
/// oculto, e todo `println!`/`eprintln!` cai no vazio. Enquanto foi só um
/// programa de terminal isso não incomodou; com janela e bandeja, passou a
/// haver falha que só acontece na máquina instalada - e sem registro nenhum a
/// investigação vira adivinhação.
///
/// Sem data e sem níveis: o valor está em existir, e um formato elaborado só
/// adiaria a primeira linha útil. Falha ao gravar é ignorada de propósito - um
/// diário que derruba o programa que ele deveria explicar seria o pior dos
/// dois mundos.
pub fn diario(linha: &str) {
    use std::io::Write;
    println!("{linha}");
    let caminho = config_dir().join("agent.log");
    if let Some(pai) = caminho.parent() {
        let _ = std::fs::create_dir_all(pai);
    }
    if let Ok(mut f) = std::fs::OpenOptions::new()
        .create(true)
        .append(true)
        .open(&caminho)
    {
        let _ = writeln!(f, "{linha}");
    }
}

/// Grava a configuração, criando a pasta se preciso.
///
/// Existe porque agora há dois lugares que escrevem aqui: o `install`, que
/// guarda a URL do backend, e o agente em execução, quando o app liga ou
/// desliga o "manter pronto". Uma escolha feita no telefone precisa sobreviver
/// ao próximo login — senão ela vale até a máquina reiniciar e ninguém entende
/// por que voltou sozinha.
pub fn save_config(cfg: &config::Config) -> Result<(), String> {
    let caminho = config_path();
    if let Some(pai) = caminho.parent() {
        let _ = std::fs::create_dir_all(pai);
    }
    std::fs::write(&caminho, cfg.to_text())
        .map_err(|e| format!("não consegui gravar {}: {e}", caminho.display()))
}

#[cfg(test)]
mod tests {
    use super::DEFAULT_BACKEND_URL;

    /// Guarda contra a volta do padrão antigo.
    ///
    /// `127.0.0.1` como padrão de fábrica é o tipo de defeito que não parece
    /// defeito para quem desenvolve: na máquina de desenvolvimento o backend
    /// está mesmo ali, e funciona. Em qualquer outro computador o agente fica
    /// tentando falar com um servidor que não existe, e a janela diz "Sem
    /// conexão" sem dizer por quê.
    #[test]
    fn o_padrao_nao_pode_ser_a_propria_maquina() {
        // Compilar apontando para localhost é legítimo para desenvolver (ver
        // `DESKSIDE_DEFAULT_BACKEND`); o que não pode é ser o padrão embutido.
        if option_env!("DESKSIDE_DEFAULT_BACKEND").is_some() {
            return;
        }
        assert!(
            !DEFAULT_BACKEND_URL.contains("127.0.0.1")
                && !DEFAULT_BACKEND_URL.contains("localhost"),
            "padrão de fábrica não pode ser a própria máquina: {DEFAULT_BACKEND_URL}"
        );
    }

    #[test]
    fn o_padrao_e_o_endereco_do_agente() {
        // Errar o caminho daria um erro de conexão idêntico ao de servidor
        // fora do ar, e mandaria a investigação para o lado errado.
        assert!(
            DEFAULT_BACKEND_URL.ends_with("/ws/agent"),
            "o backend do agente termina em /ws/agent: {DEFAULT_BACKEND_URL}"
        );
    }
}
