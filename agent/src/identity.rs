//! Identidade persistente do agente.
//!
//! O agente gera um `device_id` (UUID) na primeira execução e o guarda em
//! disco, para que o mesmo computador seja reconhecido em conexões futuras
//! (base do pareamento — Etapa 5 do projeto).

use std::fs;
use std::io;
use std::path::Path;

use uuid::Uuid;

/// Lê o `device_id` do caminho informado; se não existir, gera um novo UUID,
/// grava e o retorna.
pub fn load_or_create_device_id(path: &Path) -> io::Result<String> {
    if let Ok(existing) = fs::read_to_string(path) {
        let trimmed = existing.trim();
        if !trimmed.is_empty() {
            return Ok(trimmed.to_string());
        }
    }

    let id = Uuid::new_v4().to_string();
    if let Some(parent) = path.parent() {
        fs::create_dir_all(parent)?;
    }
    fs::write(path, &id)?;
    Ok(id)
}

/// Lê o segredo deste computador, ou `String::new()` se ainda não houver.
///
/// Vazio **não** é a mesma coisa que ausente, e a diferença é o que impede um
/// desastre: no `hello`, vazio significa "sei guardar um segredo, mas ainda não
/// tenho" — o pedido de adoção. Um agente antigo não manda o campo, e o
/// servidor sabe que não deve emitir para ele, porque emitir trancaria a
/// máquina do lado de fora na reconexão seguinte.
pub fn load_secret(path: &Path) -> String {
    fs::read_to_string(path)
        .map(|t| t.trim().to_string())
        .unwrap_or_default()
}

/// Guarda o segredo entregue pelo servidor.
///
/// Perder isto custa caro: sem o segredo, o servidor recusa a conexão e o único
/// conserto é desparear e parear de novo pelo app. Daí o erro ser devolvido em
/// vez de ignorado — quem chama precisa poder registrar que não conseguiu.
pub fn save_secret(path: &Path, secret: &str) -> io::Result<()> {
    if let Some(parent) = path.parent() {
        fs::create_dir_all(parent)?;
    }
    fs::write(path, secret.trim())
}

/// O resumo que vai ao servidor no lugar do identificador da máquina.
///
/// O identificador é o `MachineGuid` do Windows: sobrevive a reinstalar o
/// Deskside (o `device_id` não sobrevive — é um arquivo nosso) e só muda se o
/// Windows for reinstalado. É o que amarra o teste de 30 dias ao computador
/// (ver `backend/app/teste.py`): sem isto, reinstalar o agente dava uma
/// máquina "nova" a cada mês.
///
/// **Só o resumo sai do computador**, nunca o valor. O prefixo separa este
/// resumo de qualquer outro SHA-256 que um dia o agente produza.
///
/// Devolve `None` para texto vazio ou absurdo — e `None` no servidor quer
/// dizer "não sei", que nunca corta o teste de ninguém.
///
/// Um limite conhecido: computadores clonados de uma mesma imagem sem
/// `sysprep` compartilham o `MachineGuid`, e para o servidor são uma máquina
/// só. É raro fora de empresa, e o custo é dividir os dois testes da máquina.
pub fn resumo_da_maquina(identificador: &str) -> Option<String> {
    use sha2::{Digest, Sha256};

    let limpo = identificador.trim().to_ascii_lowercase();
    if limpo.is_empty() || limpo.len() > 128 {
        return None;
    }
    Some(format!(
        "{:x}",
        Sha256::digest(format!("deskside:maquina:{limpo}").as_bytes())
    ))
}

/// O resumo desta máquina, ou `None` se não der para ler.
pub fn maquina() -> Option<String> {
    imp::machine_guid().and_then(|guid| resumo_da_maquina(&guid))
}

#[cfg(windows)]
mod imp {
    use std::ffi::c_void;

    // `HKEY_LOCAL_MACHINE` é `(HKEY)(LONG)0x80000002`: o valor passa por um
    // inteiro de 32 bits **com sinal** antes de virar ponteiro, então no
    // Windows de 64 bits ele é estendido com uns. Escrever `0x8000_0002 as
    // isize` daria outra chave — e o registro responderia "não achei".
    const HKEY_LOCAL_MACHINE: isize = 0x8000_0002u32 as i32 as isize;
    const RRF_RT_REG_SZ: u32 = 0x0000_0002;
    /// Lê a visão de 64 bits do registro mesmo se, um dia, este processo for
    /// de 32: sem isto a leitura cairia no `WOW6432Node`, onde o `MachineGuid`
    /// não existe.
    const RRF_SUBKEY_WOW6464KEY: u32 = 0x0001_0000;

    #[link(name = "advapi32")]
    extern "system" {
        fn RegGetValueW(
            chave: isize,
            subchave: *const u16,
            valor: *const u16,
            flags: u32,
            tipo: *mut u32,
            dados: *mut c_void,
            tamanho: *mut u32,
        ) -> i32;
    }

    pub fn machine_guid() -> Option<String> {
        let subchave: Vec<u16> = "SOFTWARE\\Microsoft\\Cryptography\0".encode_utf16().collect();
        let valor: Vec<u16> = "MachineGuid\0".encode_utf16().collect();
        let mut dados = [0u16; 128];
        let mut tamanho = (dados.len() * 2) as u32;
        let resultado = unsafe {
            RegGetValueW(
                HKEY_LOCAL_MACHINE,
                subchave.as_ptr(),
                valor.as_ptr(),
                RRF_RT_REG_SZ | RRF_SUBKEY_WOW6464KEY,
                std::ptr::null_mut(),
                dados.as_mut_ptr() as *mut c_void,
                &mut tamanho,
            )
        };
        if resultado != 0 {
            eprintln!("Não consegui ler o MachineGuid (erro {resultado}).");
            return None;
        }
        let fim = dados.iter().position(|&c| c == 0).unwrap_or(dados.len());
        Some(String::from_utf16_lossy(&dados[..fim]))
    }
}

#[cfg(not(windows))]
mod imp {
    /// Fora do Windows não há `MachineGuid`, e o Deskside só controla
    /// Windows. `None` aqui é o mesmo "não sei" de um agente antigo.
    pub fn machine_guid() -> Option<String> {
        None
    }
}

#[cfg(test)]
mod maquina {
    use super::resumo_da_maquina;

    const GUID: &str = "3f2504e0-4f89-11d3-9a0c-0305e82c3301";

    #[test]
    fn o_resumo_e_sha256_em_hexadecimal() {
        // É exatamente o formato que o servidor aceita (64 hexadecimais
        // minúsculos); qualquer outra coisa ele trata como ausente.
        let r = resumo_da_maquina(GUID).unwrap();
        assert_eq!(r.len(), 64);
        assert!(r.chars().all(|c| c.is_ascii_hexdigit() && !c.is_ascii_uppercase()));
    }

    #[test]
    fn o_identificador_nao_sai_do_computador() {
        let r = resumo_da_maquina(GUID).unwrap();
        assert!(!r.contains("3f2504e0"));
    }

    #[test]
    fn a_mesma_maquina_da_sempre_o_mesmo_resumo() {
        // Maiúsculas e espaços não podem transformar um computador em dois.
        assert_eq!(
            resumo_da_maquina(GUID),
            resumo_da_maquina(&format!("  {}  ", GUID.to_uppercase()))
        );
    }

    #[test]
    fn maquinas_diferentes_dao_resumos_diferentes() {
        assert_ne!(
            resumo_da_maquina(GUID),
            resumo_da_maquina("00000000-0000-0000-0000-000000000000")
        );
    }

    #[test]
    fn a_receita_e_a_combinada() {
        // Valor calculado **fora** do Rust (`hashlib.sha256` do Python, sobre
        // `deskside:maquina:<guid>`). Se alguém mudar o prefixo ou a
        // normalização deste lado, todo computador vira "novo" para o
        // servidor — e cada um ganha mais dois testes. Este número muda, e o
        // teste avisa antes.
        assert_eq!(
            resumo_da_maquina(GUID).unwrap(),
            "66c07f84e530b9ca810fa035126eca7d3bc2fd98791276b102c469d9e0c69e63"
        );
    }

    #[test]
    fn vazio_ou_absurdo_nao_vira_resumo() {
        assert_eq!(resumo_da_maquina(""), None);
        assert_eq!(resumo_da_maquina("   "), None);
        assert_eq!(resumo_da_maquina(&"x".repeat(200)), None);
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn segredo_ausente_vira_vazio_e_nao_erro() {
        let dir = std::env::temp_dir().join(format!("deskside-seg-{}", Uuid::new_v4()));
        assert_eq!(load_secret(&dir.join("agent_secret")), "");
    }

    #[test]
    fn segredo_sobrevive_a_ida_e_volta() {
        let dir = std::env::temp_dir().join(format!("deskside-seg-{}", Uuid::new_v4()));
        let caminho = dir.join("agent_secret");
        save_secret(&caminho, "  abc-123  ").unwrap();
        // Aparado dos dois lados: um "\n" que sobrasse viraria um segredo
        // diferente do que o servidor guardou, e a recusa não diria por quê.
        assert_eq!(load_secret(&caminho), "abc-123");
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn creates_when_missing_and_is_stable() {
        let dir = std::env::temp_dir().join(format!("deskside-test-{}", Uuid::new_v4()));
        let path = dir.join("device_id");

        let first = load_or_create_device_id(&path).unwrap();
        assert!(!first.is_empty());
        assert!(path.exists());

        // A segunda chamada devolve o mesmo id.
        let second = load_or_create_device_id(&path).unwrap();
        assert_eq!(first, second);

        fs::remove_dir_all(&dir).ok();
    }

    #[test]
    fn generates_valid_uuid() {
        let dir = std::env::temp_dir().join(format!("deskside-test-{}", Uuid::new_v4()));
        let path = dir.join("device_id");

        let id = load_or_create_device_id(&path).unwrap();
        assert!(Uuid::parse_str(&id).is_ok());

        fs::remove_dir_all(&dir).ok();
    }
}
