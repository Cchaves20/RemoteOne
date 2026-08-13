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

/// Fecha **todos** os programas abertos. Devolve quantos receberam o pedido.
///
/// "Aberto" aqui é o mesmo critério do `AppKind::Running`: processo com janela
/// visível. É a definição que interessa a quem pediu "fecha tudo" — serviço de
/// sistema e tarefa de fundo não são o que a pessoa vê na barra de tarefas, e
/// encerrá-los seria estragar a máquina para cumprir o pedido ao pé da letra.
///
/// Duas exclusões, e a primeira não é opcional:
///
/// - **o próprio agente**, que tem janela e apareceria na lista. Fechar-se no
///   meio de uma automação mataria a sessão e os passos seguintes junto;
/// - **o Explorer**, que é a barra de tarefas e a área de trabalho.
///
/// E sem `/F`, como o `close_by_name`: o programa recebe o pedido e pergunta
/// sobre o que não foi salvo. Uma automação que roda sozinha, de madrugada, não
/// pode descartar o trabalho de ninguém.
pub fn close_all() -> Result<usize, String> {
    imp::close_all()
}

/// Procura um atalho pelo nome numa árvore de pastas.
///
/// Existe por causa dos perfis atribuídos a **mais de um computador**: o
/// programa é escolhido numa máquina e o caminho guardado é o de lá. Em outra
/// máquina esse caminho pode simplesmente não existir — o Spotify de um está
/// em `AppData\Roaming` do usuário dele, o do outro em `Program Files`. Sem
/// esta busca, o perfil funcionaria só no computador onde nasceu.
///
/// A comparação é pelo nome do arquivo sem extensão, sem diferenciar
/// maiúsculas. Pura de propósito — recebe as raízes em vez de descobri-las —,
/// que é o que permite testá-la fora do Windows.
pub fn find_shortcut(roots: &[std::path::PathBuf], name: &str) -> Option<std::path::PathBuf> {
    let alvo = name.to_lowercase();
    let mut fila: Vec<std::path::PathBuf> = roots.to_vec();
    // Largura e não profundidade: o menu Iniciar põe os programas mais comuns
    // na raiz e os agrupados em subpastas, então o mais provável aparece antes.
    // O teto existe para uma pasta com laço de atalhos não virar busca infinita.
    let mut visitadas = 0usize;
    while let Some(dir) = fila.pop() {
        visitadas += 1;
        if visitadas > 2_000 {
            break;
        }
        let Ok(entradas) = std::fs::read_dir(&dir) else {
            continue;
        };
        for entrada in entradas.flatten() {
            let caminho = entrada.path();
            if caminho.is_dir() {
                fila.push(caminho);
                continue;
            }
            let nome = caminho
                .file_stem()
                .map(|n| n.to_string_lossy().to_lowercase())
                .unwrap_or_default();
            if nome == alvo {
                return Some(caminho);
            }
        }
    }
    None
}

pub fn close(id: &str) -> Result<(), String> {
    imp::close(id)
}

/// Fecha um programa pelo **nome do processo** (`slack`, `outlook`).
///
/// Existe para as automações, e a diferença para o `close` acima não é
/// cosmética: aquele recebe um PID, que serve à tela de aplicativos (a lista
/// acabou de ser lida, o PID é de agora). Uma automação é escrita hoje e rodada
/// amanhã, e o PID de hoje não existe amanhã.
///
/// **Pede para fechar, não mata.** O `close` por PID usa `/F` porque quem tocou
/// no botão está olhando a lista e decidiu encerrar aquilo. Uma automação roda
/// sozinha, muitas vezes com a pessoa longe do computador - e forçar ali
/// descartaria em silêncio o documento não salvo que o programa teria pedido
/// para gravar. Sem `/F`, o Windows manda o pedido de fechamento e o programa
/// decide o que fazer com ele.
pub fn close_by_name(name: &str) -> Result<(), String> {
    imp::close_by_name(name)
}

/// O nome de processo que o `taskkill` aceita, a partir do que veio do app.
///
/// Pura e testável: é aqui que mora o erro fácil. O app pode mandar `slack`,
/// `Slack.exe` ou até um caminho, e o que o `taskkill /IM` quer é o nome do
/// executável com extensão. Devolve `None` para nome vazio ou com caractere que
/// não pertence a um nome de processo - a lista chega pela rede, e daqui sai um
/// argumento de linha de comando.
pub fn nome_de_processo(bruto: &str) -> Option<String> {
    let base = bruto
        .rsplit(['\\', '/'])
        .next()
        .unwrap_or(bruto)
        .trim();
    if base.is_empty() || base.len() > 120 {
        return None;
    }
    // Só o que compõe um nome de arquivo de programa. Sem espaço, aspas, `&`,
    // `|` nem `..`: nada daqui pode virar outro comando nem subir de pasta.
    if !base
        .chars()
        .all(|c| c.is_ascii_alphanumeric() || matches!(c, '.' | '-' | '_'))
        || base.contains("..")
    {
        return None;
    }
    let minusculo = base.to_ascii_lowercase();
    if minusculo.ends_with(".exe") {
        Some(minusculo)
    } else {
        Some(format!("{minusculo}.exe"))
    }
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
/// Processos que têm janela mas **não são programas** para quem olha.
///
/// O Windows mantém uma coleção de hospedeiros de interface com título de
/// janela: o painel de emoji (`TextInputHost`), o casco das aplicações da loja
/// (`ApplicationFrameHost`), a busca, o menu Iniciar. Eles passam pelo filtro
/// de "tem janela visível" e não são nada que alguém queira ver numa dock - nem
/// mandar fechar.
///
/// A lista é por nome e curada à mão, porque não existe marca no sistema que
/// separe "programa da pessoa" de "peça do shell". Acrescentar uma entrada aqui
/// é o conserto esperado quando aparecer outra: é uma linha, e tem teste.
///
/// O `explorer` entra por um motivo diferente e mais forte: o Windows usa **um
/// só** processo para a área de trabalho, a barra de tarefas e as janelas de
/// pasta. Fechá-lo pelo PID derrubaria a barra de tarefas inteira, então ele
/// não pode aparecer numa lista cujo uso é "fechar tudo".
#[cfg_attr(not(windows), allow(dead_code))]
const RUIDO: &[&str] = &[
    "applicationframehost",
    "ctfmon",
    "dllhost",
    "explorer",
    "lockapp",
    "messageexchangetools",
    "phoneexperiencehost",
    "runtimebroker",
    "searchapp",
    "searchhost",
    "searchui",
    "shellexperiencehost",
    "sihost",
    "startmenuexperiencehost",
    "systemsettings",
    "textinputhost",
    "widgets",
    "widgetservice",
];

/// Se este processo é peça do sistema, e não programa de gente.
///
/// Duas peneiras. A primeira é a lista de nomes acima. A segunda é o caminho:
/// tudo que mora em `Windows\SystemApps` é hospedeiro do shell por definição, e
/// pega os que ninguém lembrou de listar - é a peneira que envelhece bem.
#[cfg_attr(not(windows), allow(dead_code))]
fn e_ruido(nome: &str, caminho: &str) -> bool {
    let n = nome.to_lowercase();
    if RUIDO.contains(&n.as_str()) {
        return true;
    }
    caminho.to_lowercase().contains(r"\windows\systemapps\")
}

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
            // O caminho serve só para peneirar: não vai para o app, que
            // identifica o processo pelo PID.
            let caminho = item.get("path").and_then(|v| v.as_str()).unwrap_or("");
            if e_ruido(&name, caminho) {
                return None;
            }
            let icon = item
                .get("icon")
                .and_then(|v| v.as_str())
                .filter(|s| !s.is_empty())
                .map(|s| s.to_string());
            Some(AppInfo {
                id: id.to_string(),
                name,
                icon,
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
Add-Type -Namespace Deskside -Name IconApi -MemberDefinition @'
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
    $n = [Deskside.IconApi]::PrivateExtractIcons($caminho, $indice, $tamanho, $tamanho, $h, $ids, 1, 0)
    if ($n -le 0 -or $h[0] -eq [IntPtr]::Zero) { return '' }
    $ico = [System.Drawing.Icon]::FromHandle($h[0])
    $bmp = $ico.ToBitmap()
    $ms = New-Object System.IO.MemoryStream
    $bmp.Save($ms, [System.Drawing.Imaging.ImageFormat]::Png)
    $b64 = [Convert]::ToBase64String($ms.ToArray())
    $ms.Dispose(); $bmp.Dispose(); $ico.Dispose()
    return $b64
  } catch { return '' }
  finally { if ($h[0] -ne [IntPtr]::Zero) { [void][Deskside.IconApi]::DestroyIcon($h[0]) } }
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
    /// Corpo do script dos abertos: PID, nome, caminho do executável e ícone.
    ///
    /// O caminho existe para peneirar (ver `e_ruido`) e para achar o ícone. Vem
    /// dentro de `try/catch` porque processo protegido recusa a leitura, e uma
    /// exceção ali derrubaria a listagem inteira por causa de um antivírus.
    const RUNNING_BODY: &str = r#"
$tam = 128
$out = @()
foreach ($p in Get-Process | Where-Object { $_.MainWindowTitle -ne '' }) {
  $caminho = ''
  try { $caminho = $p.Path } catch { }
  $icon = ''
  if ($caminho -ne '') { $icon = Get-IconBase64 $caminho 0 $tam }
  $out += [PSCustomObject]@{
    Id = $p.Id; ProcessName = $p.ProcessName; path = $caminho; icon = $icon
  }
}
ConvertTo-Json -InputObject @($out) -Compress -Depth 3
"#;

    /// Os programas abertos, com ícone.
    ///
    /// Sem cache dos ícones de propósito: o custo que importa aqui é **abrir o
    /// PowerShell** (uns 200 ms), não extrair uma dúzia de ícones com o
    /// `PrivateExtractIcons`, que lê um recurso já pronto do executável.
    /// Guardar os ícones acrescentaria estado compartilhado para economizar a
    /// parte barata.
    pub fn list_running() -> Vec<AppInfo> {
        let script = format!("{ICON_HELPER}\n{RUNNING_BODY}");
        let Ok(output) = run_powershell(&script) else {
            return Vec::new();
        };
        let text = String::from_utf8_lossy(&output.stdout);
        tidy(super::parse_running(&text))
    }

    pub fn launch(id: &str) -> Result<(), String> {
        let alvo = resolve_target(id);
        // `start` resolve atalhos (.lnk) e executáveis. O "" é o título da
        // janela, exigido quando o caminho vem entre aspas.
        Command::new("cmd")
            .args(["/C", "start", "", &alvo])
            .spawn()
            .map(|_| ())
            .map_err(|e| format!("não foi possível abrir: {e}"))
    }

    /// As pastas do menu Iniciar, do usuário e do sistema.
    fn start_menus() -> Vec<std::path::PathBuf> {
        ["APPDATA", "ProgramData"]
            .iter()
            .filter_map(|v| std::env::var(v).ok())
            .map(|base| {
                std::path::PathBuf::from(base)
                    .join("Microsoft")
                    .join("Windows")
                    .join("Start Menu")
                    .join("Programs")
            })
            .filter(|p| p.is_dir())
            .collect()
    }

    /// O que abrir de fato.
    ///
    /// Caminho que existe vai como está. Caminho que **não** existe é o caso do
    /// perfil que veio de outro computador: procura-se um atalho de mesmo nome
    /// no menu Iniciar. Se nem isso, entrega-se o texto original ao `start`,
    /// que ainda resolve nomes do PATH ("notepad", "calc").
    fn resolve_target(id: &str) -> String {
        let caminho = std::path::Path::new(id);
        if caminho.exists() {
            return id.to_string();
        }
        let nome = caminho
            .file_stem()
            .map(|n| n.to_string_lossy().to_string())
            .unwrap_or_else(|| id.to_string());
        match super::find_shortcut(&start_menus(), &nome) {
            Some(achado) => {
                println!(
                    "Perfil: \"{nome}\" não existe neste computador; abrindo {}",
                    achado.display()
                );
                achado.to_string_lossy().to_string()
            }
            None => id.to_string(),
        }
    }

    pub fn close(id: &str) -> Result<(), String> {
        let pid: u32 = id.parse().map_err(|_| format!("PID inválido: {id}"))?;
        Command::new("taskkill")
            .args(["/PID", &pid.to_string(), "/F"])
            .spawn()
            .map(|_| ())
            .map_err(|e| format!("não foi possível encerrar: {e}"))
    }

    pub fn close_by_name(name: &str) -> Result<(), String> {
        let alvo = super::nome_de_processo(name)
            .ok_or_else(|| format!("nome de programa inválido: {name}"))?;
        // `output` e não `spawn`: aqui interessa **saber** se fechou. O
        // `taskkill` devolve 128 quando não há processo com aquele nome, e uma
        // automação que diz "fechei o Slack" com o Slack aberto seria pior que
        // uma que diz que não achou.
        let saida = Command::new("taskkill")
            .args(["/IM", &alvo])
            .output()
            .map_err(|e| format!("não foi possível encerrar: {e}"))?;
        if saida.status.success() {
            return Ok(());
        }
        let motivo = String::from_utf8_lossy(&saida.stderr);
        let primeira = motivo.lines().find(|l| !l.trim().is_empty()).unwrap_or("");
        Err(if primeira.is_empty() {
            format!("{alvo} não estava aberto")
        } else {
            primeira.trim().to_string()
        })
    }

    /// O nome do processo deste próprio agente, sem extensão.
    ///
    /// Descoberto do executável em vez de escrito à mão: quem renomeia o
    /// binário não pode fazer o agente se fechar sozinho por causa disso.
    fn eu_mesmo() -> String {
        std::env::current_exe()
            .ok()
            .and_then(|p| p.file_stem().map(|n| n.to_string_lossy().to_string()))
            .unwrap_or_else(|| "deskside-agent".to_string())
            .to_lowercase()
    }

    pub fn close_all() -> Result<usize, String> {
        let meu_nome = eu_mesmo();
        let abertos = list_running();
        if abertos.is_empty() {
            return Ok(0);
        }

        let mut pedidos = 0;
        for app in abertos {
            let nome = app.name.to_lowercase();
            if nome == meu_nome || nome == "explorer" {
                continue;
            }
            // Por PID, e não por nome: a lista veio com os PIDs em mãos, e
            // fechar por nome derrubaria também as janelas que **não** estavam
            // na lista - as sem janela visível, que é justamente o que se quer
            // preservar.
            //
            // Sem `/F`: é o pedido educado, o mesmo do `close_by_name`.
            let saiu = Command::new("taskkill")
                .args(["/PID", &app.id])
                .output();
            match saiu {
                Ok(r) if r.status.success() => pedidos += 1,
                // Um programa que recusa (janela modal, "salvar antes?") não
                // interrompe os outros: a automação segue e o relatório diz
                // quantos aceitaram.
                Ok(_) => {}
                Err(e) => return Err(format!("não foi possível encerrar: {e}")),
            }
        }
        Ok(pedidos)
    }
}

/// Reexporta o que o resto do agente usa de dentro do `imp` do Windows: o
/// extrator de ícone e o atalho para o PowerShell. Sem isto os dois ficam
/// visíveis só dentro deste módulo - `pub(crate)` dentro de um `mod` privado
/// não atravessa o `mod`.
#[cfg(windows)]
pub(crate) use imp::{run_powershell, ICON_HELPER};

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

    pub fn close_by_name(name: &str) -> Result<(), String> {
        println!("[apps-stub] encerrar por nome: {name}");
        Ok(())
    }

    pub fn close_all() -> Result<usize, String> {
        println!("[apps-stub] fechar tudo (nada a fazer fora do Windows)");
        Ok(0)
    }
}

#[cfg(test)]
mod tests {
    use super::{e_ruido, parse_running};

    #[test]
    fn os_hospedeiros_do_shell_nao_sao_programas() {
        // O que motivou a lista: os dois apareceram na dock de um computador
        // de verdade, com título de janela e tudo.
        assert!(e_ruido("TextInputHost", ""));
        assert!(e_ruido("MessageExchangeTools", ""));
        // Maiúsculas não importam - o nome vem do Windows como ele quiser.
        assert!(e_ruido("textinputhost", ""));
    }

    #[test]
    fn o_explorer_fica_de_fora_por_um_motivo_mais_forte() {
        // O Windows usa **um** processo para a área de trabalho, a barra de
        // tarefas e as janelas de pasta. Fechá-lo pelo PID derrubaria a barra
        // inteira, e esta lista alimenta o "fechar tudo".
        assert!(e_ruido("explorer", r"C:\Windows\explorer.exe"));
    }

    #[test]
    fn o_caminho_pega_quem_a_lista_esqueceu() {
        // A peneira que envelhece bem: tudo em SystemApps é hospedeiro do
        // shell por definição, mesmo o que ninguém lembrou de listar.
        assert!(e_ruido(
            "AlgoNovoDaMicrosoft",
            r"C:\Windows\SystemApps\Microsoft.Alguma_8wekyb3d8bbwe\algo.exe"
        ));
    }

    #[test]
    fn programa_de_gente_passa() {
        assert!(!e_ruido("Spotify", r"C:\Users\eu\AppData\Roaming\Spotify\Spotify.exe"));
        assert!(!e_ruido("notepad", r"C:\Windows\System32\notepad.exe"));
        // O notepad mora dentro de Windows e **não** é ruído: a peneira de
        // caminho olha SystemApps, não a pasta Windows inteira. Cortar por
        // "Windows" levaria junto o bloco de notas e a calculadora.
    }

    #[test]
    fn a_lista_de_abertos_traz_icone_e_descarta_ruido() {
        let json = r#"[
          {"Id":10,"ProcessName":"Spotify","path":"C:\\x\\Spotify.exe","icon":"QUJD"},
          {"Id":11,"ProcessName":"TextInputHost","path":"","icon":""},
          {"Id":12,"ProcessName":"Terminal","path":"C:\\x\\wt.exe","icon":""}
        ]"#;
        let apps = parse_running(json);
        assert_eq!(apps.len(), 2, "o TextInputHost devia ter sido descartado");
        assert_eq!(apps[0].name, "Spotify");
        assert_eq!(apps[0].icon.as_deref(), Some("QUJD"));
        // Ícone vazio vira ausente, e não uma string vazia que o app tentaria
        // decodificar como imagem.
        assert_eq!(apps[1].name, "Terminal");
        assert_eq!(apps[1].icon, None);
    }

    /// O nome que o `taskkill` recebe.
    ///
    /// É argumento de linha de comando montado a partir de texto que chegou
    /// pela rede: o que se protege aqui é a fronteira.
    mod nome_de_processo {
        use super::super::nome_de_processo as nome;

        #[test]
        fn acrescenta_exe_quando_falta() {
            assert_eq!(nome("slack").as_deref(), Some("slack.exe"));
            assert_eq!(nome("Outlook").as_deref(), Some("outlook.exe"));
        }

        #[test]
        fn nao_duplica_a_extensao() {
            assert_eq!(nome("slack.exe").as_deref(), Some("slack.exe"));
            assert_eq!(nome("SLACK.EXE").as_deref(), Some("slack.exe"));
        }

        #[test]
        fn tira_o_caminho_e_fica_com_o_nome() {
            // O app pode mandar o que tiver à mão; o `taskkill /IM` quer só o
            // nome do executável.
            assert_eq!(
                nome("C:\\Program Files\\Slack\\slack.exe").as_deref(),
                Some("slack.exe")
            );
        }

        #[test]
        fn recusa_o_que_nao_e_nome_de_programa() {
            // Daqui sai um argumento de linha de comando. Espaço, aspas, `&` e
            // `..` não pertencem a um nome de processo, e recusar é mais seguro
            // do que tentar limpar.
            assert_eq!(nome(""), None);
            assert_eq!(nome("   "), None);
            assert_eq!(nome("slack & shutdown"), None);
            assert_eq!(nome("a\"b"), None);
            assert_eq!(nome(".."), None);
            assert_eq!(nome(&"a".repeat(200)), None);
            // Um caminho com `..` **não** é recusado, e não deve ser: ele
            // colapsa no nome do arquivo, que é o que o `/IM` aceita. Subir de
            // pasta não significa nada para quem só quer um nome de processo.
            assert_eq!(
                nome("..\\..\\evil.exe").as_deref(),
                Some("evil.exe")
            );
        }
    }

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

    /// Monta uma árvore de atalhos num diretório temporário.
    fn arvore(raiz: &std::path::Path, caminhos: &[&str]) {
        for c in caminhos {
            let p = raiz.join(c);
            if let Some(pai) = p.parent() {
                std::fs::create_dir_all(pai).unwrap();
            }
            std::fs::write(&p, b"x").unwrap();
        }
    }

    fn temp(nome: &str) -> std::path::PathBuf {
        let dir = std::env::temp_dir().join(format!("deskside-apps-{nome}"));
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(&dir).unwrap();
        dir
    }

    #[test]
    fn acha_o_atalho_pelo_nome_em_subpasta() {
        // O caso real: o perfil foi montado num computador e o caminho de lá
        // não existe aqui. O que sobrevive à troca de máquina é o nome.
        let dir = temp("subpasta");
        arvore(&dir, &["Spotify/Spotify.lnk", "Acessórios/Bloco de Notas.lnk"]);
        let achado = find_shortcut(std::slice::from_ref(&dir), "Spotify").unwrap();
        assert!(achado.ends_with("Spotify.lnk"));
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn a_busca_ignora_maiusculas_e_a_extensao() {
        let dir = temp("caixa");
        arvore(&dir, &["PowerPoint.lnk"]);
        assert!(find_shortcut(std::slice::from_ref(&dir), "powerpoint").is_some());
        assert!(find_shortcut(std::slice::from_ref(&dir), "POWERPOINT").is_some());
        // Com extensão junto: o chamador passa o `file_stem`, mas se passar o
        // nome inteiro não deve casar por acidente com outra coisa.
        assert!(find_shortcut(std::slice::from_ref(&dir), "powerpoint.lnk").is_none());
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn nao_inventa_atalho_quando_nao_existe() {
        // Devolver algo parecido seria pior que devolver nada: abriria o
        // programa errado, e ninguém entenderia por quê.
        let dir = temp("ausente");
        arvore(&dir, &["Spotify.lnk"]);
        assert!(find_shortcut(std::slice::from_ref(&dir), "Spotifyy").is_none());
        assert!(find_shortcut(std::slice::from_ref(&dir), "").is_none());
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn raiz_inexistente_nao_derruba_a_busca() {
        let dir = temp("raizes");
        arvore(&dir, &["Chrome.lnk"]);
        let inexistente = dir.join("nao-existe");
        let achado = find_shortcut(&[inexistente, dir.clone()], "Chrome");
        assert!(achado.is_some(), "uma raiz ruim não pode cegar as outras");
        let _ = std::fs::remove_dir_all(&dir);
    }
}
