//! Trazer a configuração do nome antigo para o novo.
//!
//! O projeto se chamava RemoteOne, e o nome aparecia em dois lugares que
//! sobrevivem a uma atualização: a **pasta** de configuração
//! (`%APPDATA%\remoteone`) e as **chaves** de dentro do `agent.conf`
//! (`REMOTEONE_*`).
//!
//! Sem esta migração, trocar o nome faria cada computador perder o
//! `device_id` — e perder o `device_id` significa aparecer no aplicativo como
//! uma máquina nova, pedindo pareamento outra vez, enquanto a antiga fica na
//! lista como um fantasma que nunca mais fica online. Para quem instalou o
//! agente em três máquinas isso é chato; para quem instalou em trinta, é
//! motivo para desistir do produto.
//!
//! Duas decisões deliberadas:
//!
//! - **A pasta antiga não é apagada.** Copiar custa alguns quilobytes e deixa
//!   volta atrás possível. Apagar economizaria nada e tornaria irreversível um
//!   passo que roda sozinho, sem ninguém pedir.
//! - **Só migra quando a pasta nova não existe.** Assim rodar duas vezes não
//!   sobrescreve configuração nova com configuração velha - o que aconteceria
//!   com quem já usou a versão nova e ainda tem a pasta antiga por perto.

use std::path::Path;

/// O prefixo que as chaves de configuração tinham antes.
const PREFIXO_ANTIGO: &str = "REMOTEONE_";
/// E o de agora.
const PREFIXO_NOVO: &str = "DESKSIDE_";

/// Troca o prefixo das chaves, preservando o resto do arquivo.
///
/// Pura, e é a única parte disto que dá para testar de verdade: o resto é
/// sistema de arquivos. Só troca no **começo da linha**, porque `REMOTEONE_`
/// pode aparecer dentro de um valor (uma URL, um caminho) e ali não é chave.
pub fn renomear_chaves(texto: &str) -> String {
    texto
        .lines()
        .map(|linha| match linha.strip_prefix(PREFIXO_ANTIGO) {
            Some(resto) => format!("{PREFIXO_NOVO}{resto}"),
            None => linha.to_string(),
        })
        .collect::<Vec<_>>()
        .join("\n")
        + if texto.ends_with('\n') { "\n" } else { "" }
}

/// Copia a configuração do nome antigo para o novo, se fizer sentido.
///
/// Devolve `true` se algo foi migrado — o chamador registra isso no diário,
/// porque uma migração silenciosa é indistinguível de uma que não aconteceu no
/// dia em que alguém precisar entender por que o computador mudou de nome.
pub fn migrar(antiga: &Path, nova: &Path) -> bool {
    if nova.exists() || !antiga.is_dir() {
        return false;
    }
    if std::fs::create_dir_all(nova).is_err() {
        return false;
    }

    let mut migrou = false;
    let Ok(itens) = std::fs::read_dir(antiga) else {
        return false;
    };
    for item in itens.flatten() {
        let origem = item.path();
        if !origem.is_file() {
            continue;
        }
        let Some(nome) = origem.file_name() else {
            continue;
        };
        let destino = nova.join(nome);

        // O `agent.conf` passa pela troca de prefixo; o resto (device_id,
        // pairing-code.txt) é copiado como está.
        if nome == std::ffi::OsStr::new("agent.conf") {
            match std::fs::read_to_string(&origem) {
                Ok(texto) => {
                    if std::fs::write(&destino, renomear_chaves(&texto)).is_ok() {
                        migrou = true;
                    }
                }
                Err(_) => continue,
            }
        } else if std::fs::copy(&origem, &destino).is_ok() {
            migrou = true;
        }
    }
    migrou
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn troca_o_prefixo_das_chaves() {
        let antigo = "REMOTEONE_BACKEND_URL=wss://x/ws/agent\nREMOTEONE_VIDEO_FPS=30\n";
        let novo = renomear_chaves(antigo);
        assert!(novo.contains("DESKSIDE_BACKEND_URL=wss://x/ws/agent"));
        assert!(novo.contains("DESKSIDE_VIDEO_FPS=30"));
        assert!(!novo.contains("REMOTEONE_"));
    }

    #[test]
    fn nao_toca_no_valor_da_linha() {
        // Um caminho ou uma URL pode conter o nome antigo, e ali ele não é
        // chave: trocar corromperia o valor.
        let antigo = "REMOTEONE_CONFIG_DIR=C:\\REMOTEONE_backup\n";
        let novo = renomear_chaves(antigo);
        assert_eq!(novo, "DESKSIDE_CONFIG_DIR=C:\\REMOTEONE_backup\n");
    }

    #[test]
    fn preserva_comentarios_e_linhas_vazias() {
        let antigo = "# comentário\n\nREMOTEONE_VIDEO_FPS=24\n";
        assert_eq!(
            renomear_chaves(antigo),
            "# comentário\n\nDESKSIDE_VIDEO_FPS=24\n"
        );
    }

    #[test]
    fn arquivo_sem_quebra_final_continua_sem() {
        assert_eq!(renomear_chaves("REMOTEONE_A=1"), "DESKSIDE_A=1");
    }

    #[test]
    fn copia_a_pasta_inteira_e_traduz_so_a_config() {
        let base = std::env::temp_dir().join(format!("deskside-mig-{}", std::process::id()));
        let antiga = base.join("remoteone");
        let nova = base.join("deskside");
        std::fs::create_dir_all(&antiga).unwrap();
        std::fs::write(antiga.join("device_id"), "abc-123").unwrap();
        std::fs::write(antiga.join("agent.conf"), "REMOTEONE_VIDEO_FPS=24\n").unwrap();

        assert!(migrar(&antiga, &nova));
        // O device_id é o que impede a máquina de pedir pareamento de novo.
        assert_eq!(std::fs::read_to_string(nova.join("device_id")).unwrap(), "abc-123");
        assert_eq!(
            std::fs::read_to_string(nova.join("agent.conf")).unwrap(),
            "DESKSIDE_VIDEO_FPS=24\n"
        );
        // A antiga fica: migração automática não apaga nada.
        assert!(antiga.join("device_id").is_file());

        std::fs::remove_dir_all(&base).ok();
    }

    #[test]
    fn nao_sobrescreve_configuracao_nova() {
        let base = std::env::temp_dir().join(format!("deskside-mig2-{}", std::process::id()));
        let antiga = base.join("remoteone");
        let nova = base.join("deskside");
        std::fs::create_dir_all(&antiga).unwrap();
        std::fs::create_dir_all(&nova).unwrap();
        std::fs::write(antiga.join("device_id"), "velho").unwrap();
        std::fs::write(nova.join("device_id"), "novo").unwrap();

        assert!(!migrar(&antiga, &nova), "não deveria migrar sobre a pasta nova");
        assert_eq!(std::fs::read_to_string(nova.join("device_id")).unwrap(), "novo");

        std::fs::remove_dir_all(&base).ok();
    }

    #[test]
    fn sem_pasta_antiga_nao_faz_nada() {
        let base = std::env::temp_dir().join(format!("deskside-mig3-{}", std::process::id()));
        assert!(!migrar(&base.join("remoteone"), &base.join("deskside")));
    }
}
