//! Qual programa está em primeiro plano no computador, com o ícone dele.
//!
//! Serve à barra de perfis do app: quando o programa da frente é o PowerPoint,
//! o perfil de apresentação passa a mostrar o ícone do PowerPoint em vez do
//! desenho genérico. Quem decide qual perfil combina com qual programa é o
//! **app** — aqui só se diz qual é o programa, o nome do executável e o ícone.
//!
//! Real no Windows; nas demais plataformas é um stub que devolve `None` (não há
//! sessão gráfica no Linux de desenvolvimento).

use serde::{Deserialize, Serialize};

/// O programa em primeiro plano.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct ForegroundApp {
    /// Nome legível ("Microsoft PowerPoint"), para mostrar a quem usa.
    pub name: String,
    /// Executável em minúsculas, com extensão ("powerpnt.exe"). É a chave de
    /// comparação: o nome legível muda com o idioma do Windows, o executável
    /// não.
    pub exe: String,
    /// Ícone real do programa, PNG em base64. Ausente quando não deu para
    /// extrair (aí o app fica com o ícone genérico do perfil).
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub icon: Option<String>,
    /// O programa esconde a própria janela de quem captura a tela - é o que
    /// os apps de banco fazem contra o golpe do acesso remoto. Ela some do
    /// vídeo (aparece o que está atrás), mas continua lá: um toque naquela
    /// área cai nela. O app avisa em vez de deixar a pessoa clicar no escuro.
    ///
    /// Só se omite quando é falso, para o formato de sempre não mudar.
    #[serde(default, skip_serializing_if = "std::ops::Not::not")]
    pub hidden: bool,
}

/// Acompanha o primeiro plano guardando o que já custou caro descobrir.
///
/// Duas memórias, por dois motivos diferentes: o **PID** evita perguntar de
/// novo enquanto ninguém trocou de janela, e o **nome do programa** evita
/// extrair o ícone de novo de alguém que já apareceu (extrair passa de 100 ms,
/// e alternar entre duas janelas é o caso comum).
#[cfg_attr(not(any(windows, target_os = "macos")), allow(dead_code))]
pub struct Watcher {
    last_pid: Option<u32>,
    last: Option<ForegroundApp>,
    known: std::collections::HashMap<String, ForegroundApp>,
}

impl Default for Watcher {
    fn default() -> Self {
        Self::new()
    }
}

impl Watcher {
    pub fn new() -> Self {
        Self {
            last_pid: None,
            last: None,
            known: std::collections::HashMap::new(),
        }
    }
}

/// Interpreta o JSON do PowerShell com os dados do processo. Função pura —
/// testada em qualquer sistema.
#[cfg_attr(not(windows), allow(dead_code))]
fn parse_process(text: &str) -> Option<ForegroundApp> {
    let value: serde_json::Value = serde_json::from_str(text.trim()).ok()?;
    let exe = value.get("exe")?.as_str()?.trim();
    if exe.is_empty() {
        return None;
    }
    // O PowerShell devolve o nome sem extensão (`ProcessName`); o app compara
    // com "powerpnt.exe". Normalizar aqui mantém uma regra só, do lado que
    // sabe de que sistema o nome veio.
    let exe = exe.to_lowercase();
    let exe = if exe.ends_with(".exe") {
        exe
    } else {
        format!("{exe}.exe")
    };
    let name = value
        .get("name")
        .and_then(|v| v.as_str())
        .map(str::trim)
        .filter(|s| !s.is_empty())
        .unwrap_or(&exe)
        .to_string();
    let icon = value
        .get("icon")
        .and_then(|v| v.as_str())
        .map(str::trim)
        .filter(|s| !s.is_empty())
        .map(str::to_string);
    Some(ForegroundApp {
        name,
        exe,
        icon,
        hidden: false,
    })
}

#[cfg(windows)]
impl Watcher {
    /// O programa da frente agora, ou `None` se não deu para descobrir.
    pub fn current(&mut self) -> Option<ForegroundApp> {
        let (pid, app_name, hidden) = focused()?;
        let mut app = self.descrever(pid, app_name)?;
        // Fora da memória de propósito: um programa pode esconder a janela
        // depois de aberto (o banco, na tela de login), e a resposta tem que
        // valer para agora.
        app.hidden = hidden;
        Some(app)
    }

    fn descrever(&mut self, pid: u32, app_name: String) -> Option<ForegroundApp> {
        // Ninguém trocou de janela: a resposta é a mesma de antes.
        if self.last_pid == Some(pid) {
            return self.last.clone();
        }
        self.last_pid = Some(pid);
        // Programa já visto nesta sessão: reaproveita o ícone extraído.
        if let Some(conhecido) = self.known.get(&app_name) {
            self.last = Some(conhecido.clone());
            return self.last.clone();
        }
        let app = describe(pid)?;
        self.known.insert(app_name, app.clone());
        self.last = Some(app.clone());
        Some(app)
    }
}

/// A janela em foco: PID, nome do programa e se ele se esconde da captura,
/// direto do sistema (sem processo externo). Vem do `xcap`, que já é usado
/// para capturar a tela.
#[cfg(windows)]
fn focused() -> Option<(u32, String, bool)> {
    let janelas = xcap::Window::all().ok()?;
    let foco = janelas.iter().find(|j| j.is_focused().unwrap_or(false))?;
    let pid = foco.pid().ok()?;
    let nome = foco.app_name().unwrap_or_default();
    // Qualquer janela visível do programa da frente, e não só a em foco: o
    // banco pode esconder a janela principal e deixar o foco numa caixa de
    // diálogo dela. A barra do próprio agente também se esconde - é outro
    // processo, e nunca entra aqui.
    let escondida = pid != std::process::id()
        && janelas
            .iter()
            .filter(|j| j.pid().ok() == Some(pid))
            .filter(|j| !j.is_minimized().unwrap_or(false))
            .filter_map(|j| j.id().ok())
            .any(escondida_da_captura);
    Some((pid, nome, escondida))
}

/// Pergunta ao Windows se a janela se esconde de quem captura a tela.
///
/// Só **pergunta**: a proteção continua valendo, e o Deskside não tenta
/// contorná-la. `GetWindowDisplayAffinity` responde sobre janelas de qualquer
/// processo, sem privilégio nenhum.
#[cfg(windows)]
fn escondida_da_captura(id: u32) -> bool {
    #[link(name = "user32")]
    extern "system" {
        fn GetWindowDisplayAffinity(janela: isize, afinidade: *mut u32) -> i32;
    }
    let mut afinidade = 0u32;
    // O `xcap` guarda o HWND em 32 bits. Pode: o Windows garante que um handle
    // de janela cabe em 32 bits, estendido com sinal no processo de 64.
    let ok = unsafe { GetWindowDisplayAffinity(id as i32 as isize, &mut afinidade) };
    // WDA_MONITOR (janela preta) e WDA_EXCLUDEFROMCAPTURE (janela some):
    // para quem está no celular, as duas escondem o programa.
    ok != 0 && afinidade != 0
}

/// Pergunta ao Windows o executável, o nome e o ícone de um processo.
#[cfg(windows)]
fn describe(pid: u32) -> Option<ForegroundApp> {
    let consulta = format!(
        r#"
$p = Get-Process -Id {pid} -ErrorAction SilentlyContinue
if (-not $p) {{ '{{}}' ; exit }}
$caminho = ''
try {{ if ($p.Path) {{ $caminho = $p.Path }} }} catch {{ }}
$icone = ''
if ($caminho -ne '') {{
  # 128px cobre tela retina; cai para tamanhos menores se o programa não
  # embutir uma versão grande.
  foreach ($tam in 128, 96, 64, 48, 32) {{
    $icone = Get-IconBase64 $caminho 0 $tam
    if ($icone -ne '') {{ break }}
  }}
}}
$nome = ''
try {{ if ($p.Description) {{ $nome = $p.Description }} }} catch {{ }}
[PSCustomObject]@{{ exe = $p.ProcessName; name = $nome; icon = $icone }} | ConvertTo-Json -Compress
"#
    );
    // O extrator de ícone é o mesmo da dock, vindo de `apps.rs`: duas cópias do
    // mesmo script acabariam divergindo, e o ícone da dock e o do perfil têm
    // que ser o mesmo desenho.
    let script = format!("{}\n{consulta}", crate::apps::ICON_HELPER);
    let output = crate::apps::run_powershell(&script).ok()?;
    parse_process(&String::from_utf8_lossy(&output.stdout))
}

/// No Mac a pergunta "quem está na frente" tem resposta direta no
/// `NSWorkspace`, sem varrer janelas. O ícone sai uma vez por programa e fica
/// guardado em `known`, como no Windows.
#[cfg(target_os = "macos")]
impl Watcher {
    pub fn current(&mut self) -> Option<ForegroundApp> {
        let p = crate::mac::em_primeiro_plano()?;
        let pid = p.pid as u32;
        if self.last_pid == Some(pid) {
            return self.last.clone();
        }
        self.last_pid = Some(pid);
        let app = match self.known.get(&p.executavel) {
            Some(conhecido) => conhecido.clone(),
            None => {
                let novo = ForegroundApp {
                    icon: crate::mac::icone_do_programa(&p.app),
                    name: p.nome,
                    exe: p.executavel.clone(),
                    hidden: false,
                };
                self.known.insert(p.executavel, novo.clone());
                novo
            }
        };
        self.last = Some(app.clone());
        Some(app)
    }
}

#[cfg(not(any(windows, target_os = "macos")))]
impl Watcher {
    /// Sem sessão gráfica não há primeiro plano. O app trata a ausência como
    /// "nenhum ícone real", que é exatamente o que acontece aqui.
    pub fn current(&mut self) -> Option<ForegroundApp> {
        None
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn le_o_processo_com_icone() {
        let app = parse_process(r#"{"exe":"POWERPNT","name":"Microsoft PowerPoint","icon":"AAA"}"#)
            .unwrap();
        assert_eq!(app.exe, "powerpnt.exe");
        assert_eq!(app.name, "Microsoft PowerPoint");
        assert_eq!(app.icon.as_deref(), Some("AAA"));
    }

    #[test]
    fn sem_icone_e_sem_descricao_ainda_serve() {
        // Um programa sem descrição no arquivo e sem ícone extraível continua
        // sendo uma resposta útil: o app decide o perfil pelo executável.
        let app = parse_process(r#"{"exe":"jogo","name":"","icon":""}"#).unwrap();
        assert_eq!(app.exe, "jogo.exe");
        assert_eq!(app.name, "jogo.exe");
        assert!(app.icon.is_none());
    }

    #[test]
    fn nao_duplica_a_extensao() {
        let app = parse_process(r#"{"exe":"vlc.exe","name":"VLC","icon":""}"#).unwrap();
        assert_eq!(app.exe, "vlc.exe");
    }

    #[test]
    fn janela_escondida_so_aparece_no_json_quando_e_verdade() {
        // App antigo continua recebendo exatamente o formato de antes.
        let mut app = parse_process(r#"{"exe":"banco","name":"Banco","icon":""}"#).unwrap();
        let json = serde_json::to_value(&app).unwrap();
        assert!(json.get("hidden").is_none());
        app.hidden = true;
        let json = serde_json::to_value(&app).unwrap();
        assert_eq!(json["hidden"], true);
        // E o caminho de volta: sem o campo, falso.
        let lido: ForegroundApp = serde_json::from_str(r#"{"name":"X","exe":"x.exe"}"#).unwrap();
        assert!(!lido.hidden);
    }

    #[test]
    fn processo_que_sumiu_nao_vira_app() {
        // O script imprime `{}` quando o processo acabou entre a consulta e a
        // pergunta - uma corrida real, porque são dois momentos diferentes.
        assert!(parse_process("{}").is_none());
        assert!(parse_process("").is_none());
        assert!(parse_process("não é json").is_none());
    }

    #[test]
    fn sem_janela_em_foco_nao_ha_o_que_dizer() {
        // No Linux não há primeiro plano: o stub devolve None, e é isso que o
        // resto do caminho (backend e app) precisa saber tratar.
        let mut w = Watcher::new();
        #[cfg(not(any(windows, target_os = "macos")))]
        assert!(w.current().is_none());
        #[cfg(any(windows, target_os = "macos"))]
        let _ = w.current();
    }
}
