//! Gerenciamento de aplicativos do computador (Etapa 8 do projeto):
//! listar programas instalados, listar os que estão abertos, abrir e encerrar.
//!
//! Real no Windows; nas demais plataformas são stubs (listas vazias), para o
//! agente continuar compilando e rodando no Linux/macOS de desenvolvimento.

use serde::{Deserialize, Serialize};

/// Um aplicativo. `id` é o que se usa para agir sobre ele: o caminho do atalho
/// (área de trabalho/instalados) ou o PID (em execução). `icon` é o ícone real
/// do programa em PNG codificado em base64 — ausente quando não foi possível
/// extrair (aí o app mostra a inicial do nome).
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct AppInfo {
    pub id: String,
    pub name: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub icon: Option<String>,
}

/// O que listar: os atalhos da área de trabalho (o conjunto que o usuário
/// mesmo montou — usado na dock), todos os programas instalados, ou os que
/// estão abertos agora.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum AppKind {
    Desktop,
    Installed,
    Running,
}

pub fn list(kind: AppKind) -> Vec<AppInfo> {
    match kind {
        AppKind::Desktop => imp::list_desktop(),
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
                icon: None,
            })
        })
        .collect()
}

/// Interpreta o JSON dos atalhos da área de trabalho (id/name/icon). Função
/// pura — testada em qualquer SO.
#[cfg_attr(not(windows), allow(dead_code))]
fn parse_desktop(text: &str) -> Vec<AppInfo> {
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
            let id = item.get("id")?.as_str()?.to_string();
            let name = item.get("name")?.as_str()?.to_string();
            // String vazia = não deu para extrair o ícone.
            let icon = item
                .get("icon")
                .and_then(|v| v.as_str())
                .filter(|s| !s.is_empty())
                .map(|s| s.to_string());
            Some(AppInfo { id, name, icon })
        })
        .collect()
}

#[cfg(windows)]
mod imp {
    use std::path::{Path, PathBuf};
    use std::process::{Command, Output};

    use base64::Engine;

    use super::{tidy, AppInfo};

    /// Executa um script no PowerShell via `-EncodedCommand`.
    ///
    /// O script vai em base64 (UTF-16LE), então aspas, `$`, `{}` e afins
    /// chegam intactos — passar scripts grandes por `-Command` na linha de
    /// comando é frágil, porque o PowerShell reinterpreta as aspas.
    pub(crate) fn run_powershell(script: &str) -> std::io::Result<Output> {
        let utf16: Vec<u8> = script
            .encode_utf16()
            .flat_map(|unit| unit.to_le_bytes())
            .collect();
        let encoded = base64::engine::general_purpose::STANDARD.encode(utf16);
        Command::new("powershell")
            .args(["-NoProfile", "-NonInteractive", "-EncodedCommand", &encoded])
            .output()
    }

    /// Trecho de PowerShell que extrai o ícone real de um arquivo em PNG
    /// base64 (`Get-IconBase64 caminho indice tamanho`).
    ///
    /// Fica separado porque tem dois usuários: a dock, que extrai o ícone de
    /// cada atalho da área de trabalho, e a barra de perfis, que extrai o do
    /// programa em primeiro plano. Uma cópia para cada acabaria divergindo.
    pub(crate) const ICON_HELPER: &str = r#"
Add-Type -AssemblyName System.Drawing
Add-Type -Namespace RemoteOne -Name IconApi -MemberDefinition @'
[DllImport("user32.dll", CharSet = CharSet.Unicode)]
public static extern int PrivateExtractIcons(string szFileName, int nIconIndex,
    int cxIcon, int cyIcon, IntPtr[] phicon, int[] piconid, int nIcons, int flags);
[DllImport("user32.dll")]
public static extern bool DestroyIcon(IntPtr hIcon);
'@

# Extrai o ícone no tamanho pedido. ExtractAssociatedIcon só devolve 32x32
# (fica pixelado numa tela retina); PrivateExtractIcons aceita a resolução,
# então pegamos a versão grande que os programas modernos embutem.
function Get-IconBase64($caminho, $indice, $tamanho) {
  $h = New-Object IntPtr[] 1
  $ids = New-Object int[] 1
  try {
    $n = [RemoteOne.IconApi]::PrivateExtractIcons($caminho, $indice, $tamanho, $tamanho, $h, $ids, 1, 0)
    if ($n -le 0 -or $h[0] -eq [IntPtr]::Zero) { return '' }
    $ico = [System.Drawing.Icon]::FromHandle($h[0])
    $bmp = $ico.ToBitmap()
    $ms = New-Object System.IO.MemoryStream
    $bmp.Save($ms, [System.Drawing.Imaging.ImageFormat]::Png)
    $b64 = [Convert]::ToBase64String($ms.ToArray())
    $ms.Dispose(); $bmp.Dispose(); $ico.Dispose()
    return $b64
  } catch { return '' }
  finally { if ($h[0] -ne [IntPtr]::Zero) { [void][RemoteOne.IconApi]::DestroyIcon($h[0]) } }
}
"#;

    /// Corpo do script da dock: varre a área de trabalho e usa o
    /// `Get-IconBase64` do [`ICON_HELPER`], que é anexado antes dele.
    const DESKTOP_BODY: &str = r#"
$sh = New-Object -ComObject WScript.Shell
$dirs = @("$env:USERPROFILE\Desktop", "$env:PUBLIC\Desktop", "$env:USERPROFILE\Área de Trabalho")
$out = @()
foreach ($d in $dirs) {
  if (-not (Test-Path -LiteralPath $d)) { continue }
  Get-ChildItem -LiteralPath $d -Filter *.lnk -File -ErrorAction SilentlyContinue | ForEach-Object {
    $icon = ''
    # Candidatos, em ordem: o ícone declarado no atalho (é o que o Windows
    # mostra), o programa apontado por ele, e o próprio atalho.
    $cands = @()
    try {
      $lnk = $sh.CreateShortcut($_.FullName)
      if ($lnk.IconLocation) {
        $partes = $lnk.IconLocation -split ',', 2
        $p = $partes[0].Trim('"')
        $idx = 0
        if ($partes.Count -gt 1) { [int]::TryParse($partes[1], [ref]$idx) | Out-Null }
        if ($p) { $cands += ,@($p, $idx) }
      }
      if ($lnk.TargetPath) { $cands += ,@($lnk.TargetPath, 0) }
    } catch { }
    $cands += ,@($_.FullName, 0)

    foreach ($c in $cands) {
      if ($icon -ne '') { break }
      if (-not (Test-Path -LiteralPath $c[0])) { continue }
      # 128px cobre telas retina (ícone de 42pt em 3x); cai para menores se o
      # programa não embutir uma versão grande.
      foreach ($tam in 128, 96, 64, 48, 32) {
        $icon = Get-IconBase64 $c[0] $c[1] $tam
        if ($icon -ne '') { break }
      }
    }
    # Último recurso: a API antiga (32x32), melhor que nenhum ícone.
    if ($icon -eq '') {
      try {
        $i = [System.Drawing.Icon]::ExtractAssociatedIcon($_.FullName)
        if ($i) {
          $b = $i.ToBitmap(); $ms = New-Object System.IO.MemoryStream
          $b.Save($ms, [System.Drawing.Imaging.ImageFormat]::Png)
          $icon = [Convert]::ToBase64String($ms.ToArray())
          $ms.Dispose(); $b.Dispose(); $i.Dispose()
        }
      } catch { }
    }
    $out += [PSCustomObject]@{ id = $_.FullName; name = $_.BaseName; icon = $icon }
  }
}
ConvertTo-Json -InputObject @($out) -Compress -Depth 3
"#;

    /// Atalhos da **área de trabalho** (do usuário e a pública), com os ícones
    /// reais. É o conjunto que a própria pessoa escolheu deixar à mão — por
    /// isso alimenta a dock, em vez das centenas de entradas do menu Iniciar.
    pub fn list_desktop() -> Vec<AppInfo> {
        let script = format!("{ICON_HELPER}\n{DESKTOP_BODY}");
        let output = match run_powershell(&script) {
            Ok(output) => output,
            Err(e) => {
                eprintln!("Falha ao listar a área de trabalho: {e}");
                return Vec::new();
            }
        };
        if !output.stderr.is_empty() {
            eprintln!(
                "PowerShell (área de trabalho): {}",
                String::from_utf8_lossy(&output.stderr).trim()
            );
        }
        let text = String::from_utf8_lossy(&output.stdout);
        let apps = tidy(super::parse_desktop(&text));
        if apps.is_empty() {
            // O script não produziu nada (erro de sintaxe, política de execução,
            // System.Drawing indisponível...). Cai para a varredura simples em
            // Rust: sem ícones, mas com a lista — nunca pior do que antes.
            eprintln!("Ícones indisponíveis; listando a área de trabalho sem eles.");
            return list_desktop_sem_icones();
        }
        let com_icone = apps.iter().filter(|a| a.icon.is_some()).count();
        println!(
            "Área de trabalho: {} programa(s), {} com ícone",
            apps.len(),
            com_icone
        );
        apps
    }

    /// Plano B: varre as pastas da área de trabalho direto pelo sistema de
    /// arquivos, sem depender do PowerShell (e, portanto, sem ícones).
    fn list_desktop_sem_icones() -> Vec<AppInfo> {
        let mut roots: Vec<PathBuf> = Vec::new();
        if let Some(up) = std::env::var_os("USERPROFILE") {
            roots.push(Path::new(&up).join("Desktop"));
            roots.push(Path::new(&up).join("Área de Trabalho"));
        }
        if let Some(pb) = std::env::var_os("PUBLIC") {
            roots.push(Path::new(&pb).join("Desktop"));
        }
        let mut out = Vec::new();
        for root in roots {
            collect_shortcuts(&root, 0, 0, &mut out);
        }
        tidy(out)
    }

    /// Programas instalados = atalhos (.lnk) dos menus Iniciar do sistema e do
    /// usuário. É o que o usuário reconhece como "seus programas".
    pub fn list_installed() -> Vec<AppInfo> {
        let mut roots: Vec<PathBuf> = Vec::new();
        if let Some(pd) = std::env::var_os("ProgramData") {
            roots.push(Path::new(&pd).join(r"Microsoft\Windows\Start Menu\Programs"));
        }
        if let Some(ad) = std::env::var_os("APPDATA") {
            roots.push(Path::new(&ad).join(r"Microsoft\Windows\Start Menu\Programs"));
        }
        let mut out = Vec::new();
        for root in roots {
            collect_shortcuts(&root, 0, 4, &mut out);
        }
        tidy(out)
    }

    /// Percorre a pasta em busca de atalhos, até `max_depth` níveis (0 = só o
    /// nível atual). O limite evita varrer árvores enormes no menu Iniciar.
    fn collect_shortcuts(dir: &Path, depth: usize, max_depth: usize, out: &mut Vec<AppInfo>) {
        let Ok(entries) = std::fs::read_dir(dir) else {
            return;
        };
        for entry in entries.flatten() {
            let path = entry.path();
            if path.is_dir() {
                if depth < max_depth {
                    collect_shortcuts(&path, depth + 1, max_depth, out);
                }
            } else if path
                .extension()
                .is_some_and(|e| e.eq_ignore_ascii_case("lnk") || e.eq_ignore_ascii_case("url"))
            {
                if let Some(name) = path.file_stem().and_then(|s| s.to_str()) {
                    // Ignora desinstaladores e afins.
                    let lower = name.to_lowercase();
                    if lower.contains("uninstall") || lower.contains("desinstal") {
                        continue;
                    }
                    out.push(AppInfo {
                        id: path.to_string_lossy().to_string(),
                        name: name.to_string(),
                        // O menu Iniciar não extrai ícones (seria lento para
                        // centenas de itens); só a área de trabalho traz.
                        icon: None,
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
        let Ok(output) = run_powershell(script) else {
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

    pub fn list_desktop() -> Vec<AppInfo> {
        println!("[apps-stub] listar área de trabalho (vazio fora do Windows)");
        Vec::new()
    }

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
            AppInfo {
                id: "b".into(),
                name: "Spotify".into(),
                icon: None,
            },
            AppInfo {
                id: "a".into(),
                name: "Chrome".into(),
                icon: None,
            },
            AppInfo {
                id: "c".into(),
                name: "spotify".into(),
                icon: None,
            },
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
        assert_eq!(
            one,
            vec![AppInfo {
                id: "7".into(),
                name: "code".into(),
                icon: None
            }]
        );

        // Saída vazia ou inválida não quebra.
        assert!(parse_running("").is_empty());
        assert!(parse_running("nada disso").is_empty());
    }

    #[test]
    fn parses_desktop_shortcuts_with_and_without_icon() {
        let apps = parse_desktop(
            r#"[{"id":"C:\\a.lnk","name":"iTunes","icon":"iVBORw0KGgo="},
                {"id":"C:\\b.lnk","name":"Steam","icon":""}]"#,
        );
        assert_eq!(apps.len(), 2);
        assert_eq!(apps[0].name, "iTunes");
        assert_eq!(apps[0].icon.as_deref(), Some("iVBORw0KGgo="));
        // Ícone vazio vira None (o app mostra a inicial do nome).
        assert_eq!(apps[1].icon, None);

        // Um só atalho: o PowerShell pode devolver objeto em vez de array.
        let one = parse_desktop(r#"{"id":"C:\\c.lnk","name":"Chrome","icon":""}"#);
        assert_eq!(one.len(), 1);
        assert_eq!(one[0].name, "Chrome");

        assert!(parse_desktop("").is_empty());
    }

    #[test]
    fn app_info_omits_icon_when_absent() {
        // Sem ícone, o campo nem entra no JSON (mensagem menor no WebSocket).
        let sem = AppInfo {
            id: "1".into(),
            name: "X".into(),
            icon: None,
        };
        assert_eq!(
            serde_json::to_string(&sem).unwrap(),
            r#"{"id":"1","name":"X"}"#
        );
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
