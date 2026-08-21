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
