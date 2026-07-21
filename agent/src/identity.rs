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

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn creates_when_missing_and_is_stable() {
        let dir = std::env::temp_dir().join(format!("remoteone-test-{}", Uuid::new_v4()));
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
        let dir = std::env::temp_dir().join(format!("remoteone-test-{}", Uuid::new_v4()));
        let path = dir.join("device_id");

        let id = load_or_create_device_id(&path).unwrap();
        assert!(Uuid::parse_str(&id).is_ok());

        fs::remove_dir_all(&dir).ok();
    }
}
