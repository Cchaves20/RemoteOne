//! Gerenciamento de aplicativos do computador (Etapa 8 do projeto):
//! listar programas instalados, listar os que estão abertos, abrir e encerrar.
//!
//! Real no Windows; nas demais plataformas são stubs (listas vazias), para o
//! agente continuar compilando e rodando no Linux/macOS de desenvolvimento.

use serde::{Deserialize, Serialize};

/// Um aplicativo. `id` é o que se usa para agir sobre ele: o caminho do atalho
/// (instalados) ou o PID (em execução).
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct AppInfo {
    pub id: String,
    pub name: String,
}

/// O que listar: programas instalados ou os que estão abertos agora.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum AppKind {
    Installed,
    Running,
}

pub fn list(kind: AppKind) -> Vec<AppInfo> {
    match kind {
        AppKind::Installed => imp::list_installed(),
        AppKind::Running => imp::list_running(),
    }
}

pub fn launch(id: &str) -> Result<(), String> {
    imp::launch(id)
}

pub fn close(id: &str) -> Result<(), String> {
    imp::close(id)
}

/// Ordena por nome (sem diferenciar maiúsculas) e remove nomes repetidos.
/// Só a implementação do Windows usa; mantida fora do `cfg` para ser testável
/// em qualquer sistema.
#[cfg_attr(not(windows), allow(dead_code))]
fn tidy(mut apps: Vec<AppInfo>) -> Vec<AppInfo> {
    apps.sort_by_key(|a| a.name.to_lowercase());
    apps.dedup_by_key(|a| a.name.to_lowercase());
    apps
}

/// Interpreta o JSON do PowerShell com os processos (objeto único quando há só
/// um processo, array quando há vários). Função pura — testada em qualquer SO.
#[cfg_attr(not(windows), allow(dead_code))]
fn parse_running(text: &str) -> Vec<AppInfo> {
    let Ok(value) = serde_json::from_str::<serde_json::Value>(text.trim()) else {
        return Vec::new();
    };
    let items = match value {
        serde_json::Value::Array(items) => items,
        other => vec![other],
    };
    items
        .into_iter()
        .filter_map(|item| {
            let id = item.get("Id")?.as_i64()?;
            let name = item.get("ProcessName")?.as_str()?.to_string();
            Some(AppInfo {
                id: id.to_string(),
                name,
            })
        })
        .collect()
}

#[cfg(windows)]
mod imp {
    use std::path::{Path, PathBuf};
    use std::process::Command;

    use super::{tidy, AppInfo};

    /// Programas instalados = atalhos (.lnk) dos menus Iniciar do sistema e do
    /// usuário. É o que o usuário reconhece como "seus programas".
    pub fn list_installed() -> Vec<AppInfo> {
        let mut roots: Vec<PathBuf> = Vec::new();
        if let Some(pd) = std::env::var_os("ProgramData") {
            roots.push(
                Path::new(&pd).join(r"Microsoft\Windows\Start Menu\Programs"),
            );
        }
        if let Some(ad) = std::env::var_os("APPDATA") {
            roots.push(
                Path::new(&ad).join(r"Microsoft\Windows\Start Menu\Programs"),
            );
        }
        let mut out = Vec::new();
        for root in roots {
            collect_shortcuts(&root, 0, &mut out);
        }
        tidy(out)
    }

    /// Percorre a pasta em busca de .lnk (profundidade limitada, para não
    /// varrer a árvore inteira em máquinas com muitos programas).
    fn collect_shortcuts(dir: &Path, depth: usize, out: &mut Vec<AppInfo>) {
        if depth > 4 {
            return;
        }
        let Ok(entries) = std::fs::read_dir(dir) else {
            return;
        };
        for entry in entries.flatten() {
            let path = entry.path();
            if path.is_dir() {
                collect_shortcuts(&path, depth + 1, out);
            } else if path.extension().is_some_and(|e| e.eq_ignore_ascii_case("lnk")) {
                if let Some(name) = path.file_stem().and_then(|s| s.to_str()) {
                    // Ignora desinstaladores e afins.
                    let lower = name.to_lowercase();
                    if lower.contains("uninstall") || lower.contains("desinstal") {
                        continue;
                    }
                    out.push(AppInfo {
                        id: path.to_string_lossy().to_string(),
                        name: name.to_string(),
                    });
                }
            }
        }
    }

    /// Programas abertos = processos com janela visível (evita listar dezenas
    /// de serviços de fundo que não interessam ao usuário).
    pub fn list_running() -> Vec<AppInfo> {
        let script = "Get-Process | Where-Object {$_.MainWindowTitle -ne ''} | \
                      Select-Object Id,ProcessName | ConvertTo-Json -Compress";
        let output = Command::new("powershell")
            .args(["-NoProfile", "-Command", script])
            .output();
        let Ok(output) = output else {
            return Vec::new();
        };
        let text = String::from_utf8_lossy(&output.stdout);
        tidy(super::parse_running(&text))
    }

    pub fn launch(id: &str) -> Result<(), String> {
        // `start` resolve atalhos (.lnk) e executáveis. O "" é o título da
        // janela, exigido quando o caminho vem entre aspas.
        Command::new("cmd")
            .args(["/C", "start", "", id])
            .spawn()
            .map(|_| ())
            .map_err(|e| format!("não foi possível abrir: {e}"))
    }

    pub fn close(id: &str) -> Result<(), String> {
        let pid: u32 = id.parse().map_err(|_| format!("PID inválido: {id}"))?;
        Command::new("taskkill")
            .args(["/PID", &pid.to_string(), "/F"])
            .spawn()
            .map(|_| ())
            .map_err(|e| format!("não foi possível encerrar: {e}"))
    }
}

#[cfg(not(windows))]
mod imp {
    use super::AppInfo;

    pub fn list_installed() -> Vec<AppInfo> {
        println!("[apps-stub] listar instalados (vazio fora do Windows)");
        Vec::new()
    }

    pub fn list_running() -> Vec<AppInfo> {
        println!("[apps-stub] listar em execução (vazio fora do Windows)");
        Vec::new()
    }

    pub fn launch(id: &str) -> Result<(), String> {
        println!("[apps-stub] abrir: {id}");
        Ok(())
    }

    pub fn close(id: &str) -> Result<(), String> {
        println!("[apps-stub] encerrar: {id}");
        Ok(())
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn tidy_sorts_and_dedups_by_name() {
        let apps = tidy(vec![
            AppInfo { id: "b".into(), name: "Spotify".into() },
            AppInfo { id: "a".into(), name: "Chrome".into() },
            AppInfo { id: "c".into(), name: "spotify".into() },
        ]);
        assert_eq!(apps.len(), 2);
        assert_eq!(apps[0].name, "Chrome");
        assert_eq!(apps[1].name, "Spotify");
    }

    #[test]
    fn parses_powershell_array_and_single_object() {
        // Vários processos: array.
        let many = parse_running(
            r#"[{"Id":10,"ProcessName":"chrome"},{"Id":20,"ProcessName":"spotify"}]"#,
        );
        assert_eq!(many.len(), 2);
        assert_eq!(many[0].id, "10");
        assert_eq!(many[1].name, "spotify");

        // Um só processo: o PowerShell devolve objeto, não array.
        let one = parse_running(r#"{"Id":7,"ProcessName":"code"}"#);
        assert_eq!(one, vec![AppInfo { id: "7".into(), name: "code".into() }]);

        // Saída vazia ou inválida não quebra.
        assert!(parse_running("").is_empty());
        assert!(parse_running("nada disso").is_empty());
    }

    #[test]
    fn app_kind_serializes_snake_case() {
        assert_eq!(
            serde_json::to_string(&AppKind::Installed).unwrap(),
            "\"installed\""
        );
        assert_eq!(
            serde_json::to_string(&AppKind::Running).unwrap(),
            "\"running\""
        );
    }
}
