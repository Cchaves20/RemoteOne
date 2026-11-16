//! Os programas do Linux: os instalados, os favoritos e os que estão rodando.
//!
//! ## Instalados: os atalhos de menu
//!
//! Todo programa com interface instala um arquivo `.desktop` (o padrão
//! freedesktop) numa pasta `applications` — do sistema, do usuário, do Flatpak
//! ou do Snap. É dele que o menu do GNOME tira nome, ícone e o comando de
//! abrir, e é dele que sai a lista aqui. O `id` de cada programa é o nome desse
//! arquivo (`firefox_firefox.desktop`): o mesmo em qualquer Ubuntu que tenha o
//! programa, que é o que os perfis precisam para funcionar em outro computador.
//!
//! ## Abertos: pelos processos, e não pelas janelas
//!
//! O Wayland não deixa um programa ver as janelas dos outros. Então "aberto"
//! aqui é **um programa instalado cujo executável está rodando** nesta conta —
//! o que funciona igual no Wayland e no X11. É impreciso de um jeito
//! conhecido: o que roda em segundo plano com atalho de menu pode aparecer; o
//! caso mais comum, o gerenciador de arquivos do GNOME como serviço, é
//! descartado de propósito.
//!
//! ## Fechar
//!
//! Um pedido de encerramento (SIGTERM) ao processo. No Wayland não há como
//! pedir à **janela** que feche, então não há a garantia do Windows de o
//! programa perguntar sobre o que não foi salvo — muitos programas fecham
//! direto.

use std::collections::HashMap;
use std::path::{Path, PathBuf};

/// Um atalho de menu lido.
#[derive(Debug, Clone, PartialEq)]
pub struct Atalho {
    /// O nome do arquivo, como `org.gnome.TextEditor.desktop`.
    pub id: String,
    pub caminho: PathBuf,
    pub nome: String,
    /// O valor de `Icon=`: um nome do tema ou um caminho.
    pub icone: String,
    /// O comando, já separado em partes, sem os `%f`, `%U` etc.
    pub comando: Vec<String>,
}

/// Lê um `.desktop`. `None` se não for um programa que o menu mostraria aqui.
///
/// `idiomas` em ordem de preferência (`["pt_BR", "pt"]`) e `area` o valor de
/// `XDG_CURRENT_DESKTOP` (`ubuntu:GNOME`), para os atalhos que só valem em
/// algumas áreas de trabalho. Pura para ser testada em qualquer sistema.
pub fn ler_atalho(
    texto: &str,
    id: &str,
    caminho: &Path,
    idiomas: &[String],
    area: &str,
) -> Option<Atalho> {
    let mut dentro = false;
    let mut campos: HashMap<&str, &str> = HashMap::new();
    for linha in texto.lines() {
        let linha = linha.trim();
        if linha.starts_with('[') {
            // Só o grupo principal; `[Desktop Action …]` são atalhos dentro do
            // programa e repetiriam chaves com outro sentido.
            dentro = linha == "[Desktop Entry]";
            continue;
        }
        if !dentro || linha.starts_with('#') {
            continue;
        }
        if let Some((chave, valor)) = linha.split_once('=') {
            campos.entry(chave.trim()).or_insert(valor.trim());
        }
    }
    let sim = |chave: &str| {
        campos
            .get(chave)
            .is_some_and(|v| v.eq_ignore_ascii_case("true"))
    };
    if campos.get("Type").copied() != Some("Application") || sim("NoDisplay") || sim("Hidden") {
        return None;
    }
    let areas: Vec<&str> = area.split(':').filter(|a| !a.is_empty()).collect();
    let lista = |chave: &str| -> Vec<&str> {
        campos
            .get(chave)
            .map(|v| v.split(';').filter(|a| !a.is_empty()).collect())
            .unwrap_or_default()
    };
    let so_em = lista("OnlyShowIn");
    if !so_em.is_empty()
        && !so_em
            .iter()
            .any(|a| areas.iter().any(|b| a.eq_ignore_ascii_case(b)))
    {
        return None;
    }
    if lista("NotShowIn")
        .iter()
        .any(|a| areas.iter().any(|b| a.eq_ignore_ascii_case(b)))
    {
        return None;
    }
    let nome = idiomas
        .iter()
        .find_map(|i| campos.get(format!("Name[{i}]").as_str()))
        .or_else(|| campos.get("Name"))?
        .to_string();
    let comando = comando_do_exec(campos.get("Exec")?);
    if comando.is_empty() {
        return None;
    }
    Some(Atalho {
        id: id.to_string(),
        caminho: caminho.to_path_buf(),
        nome,
        icone: campos.get("Icon").copied().unwrap_or_default().to_string(),
        comando,
    })
}

/// O `Exec=` de um `.desktop` separado em partes, como a especificação manda:
/// aspas duplas agrupam, barra invertida escapa dentro delas, e os códigos de
/// campo (`%f`, `%U`…) somem — o programa abre sem arquivo nenhum.
pub fn comando_do_exec(exec: &str) -> Vec<String> {
    let mut partes = Vec::new();
    let mut atual = String::new();
    let mut tem_parte = false;
    let mut aspas = false;
    let mut chars = exec.chars().peekable();
    while let Some(c) = chars.next() {
        match c {
            '"' => {
                aspas = !aspas;
                tem_parte = true;
            }
            '\\' if aspas => {
                if let Some(n) = chars.next() {
                    atual.push(n);
                }
            }
            // Código de campo (`%U`, `%f`...): some; `%%` é um `%`.
            '%' => {
                if chars.next() == Some('%') {
                    atual.push('%');
                }
            }
            c if c.is_whitespace() && !aspas => {
                if tem_parte || !atual.is_empty() {
                    partes.push(std::mem::take(&mut atual));
                }
                tem_parte = false;
            }
            c => atual.push(c),
        }
    }
    if tem_parte || !atual.is_empty() {
        partes.push(atual);
    }
    partes.retain(|p| !p.is_empty());
    partes
}

/// O nome do executável que um atalho roda, para reconhecer o processo.
///
/// Pula os embrulhos comuns: `env VAR=x programa` e `/usr/bin/flatpak run …`
/// (este último fica de fora: o processo do Flatpak não tem o nome do
/// programa, e reconhecê-lo pelo nome do atalho já basta).
pub fn executavel(comando: &[String]) -> Option<String> {
    let mut partes = comando.iter();
    let mut primeiro = partes.next()?;
    if nome_do_arquivo(primeiro) == "env" {
        primeiro = partes.find(|p| !p.contains('=') && !p.starts_with('-'))?;
    }
    let nome = nome_do_arquivo(primeiro);
    (nome != "flatpak").then_some(nome)
}

fn nome_do_arquivo(caminho: &str) -> String {
    Path::new(caminho)
        .file_name()
        .map(|n| n.to_string_lossy().into_owned())
        .unwrap_or_default()
}

/// Os favoritos do GNOME (a barra lateral do Ubuntu), pela saída de
/// `gsettings get org.gnome.shell favorite-apps`:
/// `['firefox_firefox.desktop', 'org.gnome.Nautilus.desktop']`.
pub fn favoritos(saida: &str) -> Vec<String> {
    saida
        .split('\'')
        .filter(|p| p.ends_with(".desktop"))
        .map(str::to_string)
        .collect()
}

/// Os idiomas de preferência, de `LANG` (`pt_BR.UTF-8` → `pt_BR`, `pt`).
pub fn idiomas(lang: &str) -> Vec<String> {
    let base = lang.split(['.', '@']).next().unwrap_or_default();
    let mut lista = Vec::new();
    if !base.is_empty() && base != "C" && base != "POSIX" {
        lista.push(base.to_string());
        if let Some((lingua, _)) = base.split_once('_') {
            lista.push(lingua.to_string());
        }
    }
    lista
}

/// Qual atalho é o programa deste processo, se algum.
///
/// Pelo executável (`/proc/<pid>/exe`) ou pelo primeiro argumento do comando,
/// contra o executável de cada atalho e o nome do arquivo do atalho
/// (`gnome-text-editor` para `org.gnome.TextEditor.desktop` não bate, mas
/// `code` para `code.desktop` sim). Processos de serviço
/// (`--gapplication-service`) não são programa aberto.
pub fn atalho_do_processo<'a>(
    exe: &str,
    argumentos: &[String],
    atalhos: &'a [Atalho],
) -> Option<&'a Atalho> {
    if argumentos.iter().any(|a| a == "--gapplication-service") {
        return None;
    }
    let candidatos: Vec<String> = [
        Some(nome_do_arquivo(exe)),
        argumentos.first().map(|a| nome_do_arquivo(a)),
    ]
    .into_iter()
    .flatten()
    .filter(|n| !n.is_empty())
    .collect();
    atalhos.iter().find(|a| {
        let do_atalho = executavel(&a.comando);
        let pelo_id = a.id.trim_end_matches(".desktop").to_string();
        candidatos
            .iter()
            .any(|c| do_atalho.as_deref() == Some(c.as_str()) || *c == pelo_id)
    })
}

#[cfg(target_os = "linux")]
pub use sistema::*;

#[cfg(target_os = "linux")]
mod sistema {
    use super::*;
    use crate::apps::AppInfo;
    use std::process::{Command, Stdio};
    use std::sync::Mutex;

    /// As pastas de dados, da que vence para a que perde (padrão XDG): o
    /// usuário primeiro, para um atalho dele substituir o do sistema.
    fn pastas_de_dados() -> Vec<PathBuf> {
        let mut pastas = Vec::new();
        match std::env::var_os("XDG_DATA_HOME").filter(|v| !v.is_empty()) {
            Some(v) => pastas.push(PathBuf::from(v)),
            None => {
                if let Some(casa) = std::env::var_os("HOME") {
                    pastas.push(PathBuf::from(casa).join(".local/share"));
                }
            }
        }
        let sistema = std::env::var("XDG_DATA_DIRS")
            .ok()
            .filter(|v| !v.is_empty())
            .unwrap_or_else(|| "/usr/local/share:/usr/share".to_string());
        pastas.extend(
            sistema
                .split(':')
                .filter(|p| !p.is_empty())
                .map(PathBuf::from),
        );
        // Nem sempre estão no XDG_DATA_DIRS de quem foi aberto pelo login.
        if let Some(casa) = std::env::var_os("HOME") {
            pastas.push(PathBuf::from(casa).join(".local/share/flatpak/exports/share"));
        }
        pastas.push(PathBuf::from("/var/lib/flatpak/exports/share"));
        pastas.push(PathBuf::from("/var/lib/snapd/desktop"));
        let mut vistas = std::collections::HashSet::new();
        pastas.retain(|p| vistas.insert(p.clone()));
        pastas
    }

    /// Todos os atalhos de programa visíveis no menu, sem repetir `id`.
    pub fn atalhos() -> Vec<Atalho> {
        let idiomas = idiomas(&std::env::var("LANG").unwrap_or_default());
        let area = std::env::var("XDG_CURRENT_DESKTOP").unwrap_or_default();
        let mut vistos = std::collections::HashSet::new();
        let mut lista = Vec::new();
        for pasta in pastas_de_dados() {
            let Ok(entradas) = std::fs::read_dir(pasta.join("applications")) else {
                continue;
            };
            for entrada in entradas.flatten() {
                let caminho = entrada.path();
                let Some(id) = caminho
                    .file_name()
                    .map(|n| n.to_string_lossy().into_owned())
                    .filter(|n| n.ends_with(".desktop"))
                else {
                    continue;
                };
                // O primeiro achado vence, mesmo escondido: um atalho do
                // usuário com `NoDisplay` esconde o do sistema.
                if !vistos.insert(id.clone()) {
                    continue;
                }
                let Ok(texto) = std::fs::read_to_string(&caminho) else {
                    continue;
                };
                if let Some(a) = ler_atalho(&texto, &id, &caminho, &idiomas, &area) {
                    lista.push(a);
                }
            }
        }
        lista.sort_by_key(|a| a.nome.to_lowercase());
        lista
    }

    fn info(a: &Atalho, id: String) -> AppInfo {
        AppInfo {
            id,
            name: a.nome.clone(),
            icon: icone(&a.icone),
        }
    }

    pub fn list_installed() -> Vec<AppInfo> {
        atalhos().iter().map(|a| info(a, a.id.clone())).collect()
    }

    /// Os favoritos do GNOME, mais os atalhos da pasta Área de Trabalho.
    pub fn list_desktop() -> Vec<AppInfo> {
        let todos = atalhos();
        let saida = Command::new("gsettings")
            .args(["get", "org.gnome.shell", "favorite-apps"])
            .output()
            .map(|s| String::from_utf8_lossy(&s.stdout).into_owned())
            .unwrap_or_default();
        let mut lista: Vec<AppInfo> = favoritos(&saida)
            .iter()
            .filter_map(|id| todos.iter().find(|a| &a.id == id))
            .map(|a| info(a, a.id.clone()))
            .collect();
        let idiomas = idiomas(&std::env::var("LANG").unwrap_or_default());
        let area = std::env::var("XDG_CURRENT_DESKTOP").unwrap_or_default();
        if let Ok(entradas) = std::fs::read_dir(pasta_da_area_de_trabalho()) {
            for caminho in entradas.flatten().map(|e| e.path()) {
                if caminho.extension().is_none_or(|e| e != "desktop") {
                    continue;
                }
                let id = caminho.to_string_lossy().into_owned();
                if let Some(a) = std::fs::read_to_string(&caminho)
                    .ok()
                    .and_then(|t| ler_atalho(&t, &id, &caminho, &idiomas, &area))
                {
                    if !lista.iter().any(|i| i.name == a.nome) {
                        lista.push(info(&a, id));
                    }
                }
            }
        }
        lista
    }

    /// A pasta Área de Trabalho, que muda de nome com o idioma
    /// (`~/.config/user-dirs.dirs`: `XDG_DESKTOP_DIR="$HOME/Área de Trabalho"`).
    fn pasta_da_area_de_trabalho() -> PathBuf {
        let casa = PathBuf::from(std::env::var_os("HOME").unwrap_or_default());
        let config =
            std::fs::read_to_string(casa.join(".config/user-dirs.dirs")).unwrap_or_default();
        config
            .lines()
            .find_map(|l| l.strip_prefix("XDG_DESKTOP_DIR="))
            .map(|v| {
                v.trim_matches('"')
                    .replace("$HOME", &casa.to_string_lossy())
            })
            .map(PathBuf::from)
            .unwrap_or_else(|| casa.join("Desktop"))
    }

    /// Acha o atalho de um `id` — o nome do arquivo, um caminho, ou o nome
    /// do programa (perfis montados em outro computador).
    fn achar(id: &str) -> Option<Atalho> {
        let caminho = Path::new(id);
        if caminho.is_absolute() && caminho.exists() {
            let texto = std::fs::read_to_string(caminho).ok()?;
            let idiomas = idiomas(&std::env::var("LANG").unwrap_or_default());
            let area = std::env::var("XDG_CURRENT_DESKTOP").unwrap_or_default();
            return ler_atalho(&texto, id, caminho, &idiomas, &area);
        }
        let todos = atalhos();
        let pedido = id.trim_end_matches(".desktop").to_lowercase();
        todos
            .iter()
            .find(|a| a.id == id)
            .or_else(|| todos.iter().find(|a| a.nome.to_lowercase() == pedido))
            .or_else(|| {
                todos
                    .iter()
                    .find(|a| executavel(&a.comando).is_some_and(|e| e.to_lowercase() == pedido))
            })
            .cloned()
    }

    /// Abre pelo GNOME (`gio launch`), que faz o mesmo que o menu; sem ele,
    /// roda o comando do atalho, solto do agente.
    pub fn launch(id: &str) -> Result<(), String> {
        let atalho =
            achar(id).ok_or_else(|| format!("programa não encontrado neste computador: {id}"))?;
        // Saídas descartadas, e não capturadas: o programa aberto **herda**
        // as do `gio`, e ler uma saída que ele segura aberta deixava o agente
        // esperando o programa fechar.
        if Command::new("gio")
            .arg("launch")
            .arg(&atalho.caminho)
            .stdin(Stdio::null())
            .stdout(Stdio::null())
            .stderr(Stdio::null())
            .status()
            .is_ok_and(|s| s.success())
        {
            return Ok(());
        }
        use std::os::unix::process::CommandExt;
        let (programa, argumentos) = atalho.comando.split_first().ok_or("atalho sem comando")?;
        Command::new(programa)
            .args(argumentos)
            .stdin(Stdio::null())
            .stdout(Stdio::null())
            .stderr(Stdio::null())
            .process_group(0)
            .spawn()
            .map(|_| ())
            .map_err(|e| format!("não consegui abrir {}: {e}", atalho.nome))
    }

    /// Um programa rodando: o atalho e os processos de cada vez que ele foi
    /// aberto (o primeiro é o mais antigo).
    struct Aberto {
        pids: Vec<u32>,
        atalho: Atalho,
    }

    /// O processo que abriu este.
    fn pai(pid: u32) -> Option<u32> {
        let stat = std::fs::read_to_string(format!("/proc/{pid}/stat")).ok()?;
        // O nome, entre parênteses, pode ter espaços: o resto vem depois do
        // último `)`.
        stat.rsplit_once(')')?
            .1
            .split_whitespace()
            .nth(1)?
            .parse()
            .ok()
    }

    /// Os programas instalados que estão rodando nesta conta, um por
    /// programa. Processos abertos pelo próprio programa (as abas de um
    /// navegador, por exemplo) não contam: fechar o principal fecha eles.
    fn abertos() -> Vec<Aberto> {
        use std::os::unix::fs::MetadataExt;
        let todos = atalhos();
        let Ok(eu) = std::fs::metadata("/proc/self") else {
            return Vec::new();
        };
        let meu_pid = std::process::id();
        let mut pids: Vec<u32> = std::fs::read_dir("/proc")
            .map(|d| {
                d.flatten()
                    .filter(|e| e.metadata().is_ok_and(|m| m.uid() == eu.uid()))
                    .filter_map(|e| e.file_name().to_str()?.parse().ok())
                    .filter(|p| *p != meu_pid)
                    .collect()
            })
            .unwrap_or_default();
        pids.sort_unstable();
        let mut do_programa: HashMap<u32, String> = HashMap::new();
        let mut lista: Vec<Aberto> = Vec::new();
        for pid in pids {
            let pasta = PathBuf::from(format!("/proc/{pid}"));
            let exe = std::fs::read_link(pasta.join("exe"))
                .map(|p| p.to_string_lossy().into_owned())
                .unwrap_or_default();
            let argumentos: Vec<String> = std::fs::read(pasta.join("cmdline"))
                .map(|b| {
                    b.split(|c| *c == 0)
                        .filter(|p| !p.is_empty())
                        .map(|p| String::from_utf8_lossy(p).into_owned())
                        .collect()
                })
                .unwrap_or_default();
            let Some(a) = atalho_do_processo(&exe, &argumentos, &todos) else {
                continue;
            };
            if a.id == "deskside.desktop" {
                continue;
            }
            do_programa.insert(pid, a.id.clone());
            if pai(pid).is_some_and(|p| do_programa.get(&p) == Some(&a.id)) {
                continue;
            }
            match lista.iter_mut().find(|x| x.atalho.id == a.id) {
                Some(x) => x.pids.push(pid),
                None => lista.push(Aberto {
                    pids: vec![pid],
                    atalho: a.clone(),
                }),
            }
        }
        lista
    }

    pub fn list_running() -> Vec<AppInfo> {
        abertos()
            .iter()
            .map(|a| info(&a.atalho, a.pids[0].to_string()))
            .collect()
    }

    extern "C" {
        fn kill(pid: i32, sinal: i32) -> i32;
    }
    const SIGTERM: i32 = 15;

    fn encerrar(pid: u32) -> bool {
        unsafe { kill(pid as i32, SIGTERM) == 0 }
    }

    /// Fecha o programa da lista de abertos — todas as vezes que ele foi
    /// aberto, como pelo nome.
    pub fn close(id: &str) -> Result<(), String> {
        let pid: u32 = id
            .parse()
            .map_err(|_| format!("identificador inválido: {id}"))?;
        let pids = abertos()
            .into_iter()
            .find(|a| a.pids[0] == pid)
            .map_or_else(|| vec![pid], |a| a.pids);
        if pids.into_iter().filter(|p| encerrar(*p)).count() > 0 {
            Ok(())
        } else {
            Err("o programa já não estava aberto".into())
        }
    }

    pub fn close_by_name(name: &str) -> Result<(), String> {
        let pedido = name.trim_end_matches(".desktop").to_lowercase();
        let alvos: Vec<Aberto> = abertos()
            .into_iter()
            .filter(|a| {
                a.atalho.nome.to_lowercase() == pedido
                    || a.atalho.id.trim_end_matches(".desktop").to_lowercase() == pedido
                    || executavel(&a.atalho.comando).is_some_and(|e| e.to_lowercase() == pedido)
            })
            .collect();
        if alvos.is_empty() {
            return Err(format!("{name} não estava aberto"));
        }
        for p in alvos.iter().flat_map(|a| &a.pids) {
            encerrar(*p);
        }
        Ok(())
    }

    pub fn close_all() -> Result<usize, String> {
        Ok(abertos()
            .iter()
            .filter(|a| a.pids.iter().filter(|p| encerrar(**p)).count() > 0)
            .count())
    }

    // --- ícones -----------------------------------------------------------------

    /// Ícones já resolvidos, por nome: a lista tem dezenas de programas.
    static ICONES: Mutex<Option<HashMap<String, Option<String>>>> = Mutex::new(None);

    /// O ícone em PNG de 64 px, em base64 — o formato dos outros sistemas.
    fn icone(nome: &str) -> Option<String> {
        if nome.is_empty() {
            return None;
        }
        let mut cache = ICONES.lock().ok()?;
        cache
            .get_or_insert_with(HashMap::new)
            .entry(nome.to_string())
            .or_insert_with(|| arquivo_do_icone(nome).and_then(|p| png_base64(&p)))
            .clone()
    }

    /// O PNG de um ícone: o caminho direto, ou o nome procurado no tema em
    /// uso, no `hicolor` (onde todo programa instala o seu) e em `pixmaps`.
    /// SVG fica de fora: não há como desenhá-lo aqui, e o app mostra um ícone
    /// genérico.
    fn arquivo_do_icone(nome: &str) -> Option<PathBuf> {
        let direto = Path::new(nome);
        if direto.is_absolute() {
            return direto
                .extension()
                .is_some_and(|e| e.eq_ignore_ascii_case("png"))
                .then(|| direto.to_path_buf())
                .filter(|p| p.exists());
        }
        let tema = Command::new("gsettings")
            .args(["get", "org.gnome.desktop.interface", "icon-theme"])
            .output()
            .ok()
            .map(|s| {
                String::from_utf8_lossy(&s.stdout)
                    .trim()
                    .trim_matches('\'')
                    .to_string()
            })
            .filter(|t| !t.is_empty());
        let temas: Vec<String> = tema.into_iter().chain(["hicolor".to_string()]).collect();
        let mut bases: Vec<PathBuf> = pastas_de_dados().iter().map(|p| p.join("icons")).collect();
        if let Some(casa) = std::env::var_os("HOME") {
            bases.insert(0, PathBuf::from(casa).join(".icons"));
        }
        for tema in &temas {
            for tamanho in ["64x64", "48x48", "96x96", "128x128", "256x256", "32x32"] {
                for base in &bases {
                    let p = base
                        .join(tema)
                        .join(tamanho)
                        .join("apps")
                        .join(format!("{nome}.png"));
                    if p.exists() {
                        return Some(p);
                    }
                }
            }
        }
        pastas_de_dados()
            .iter()
            .map(|p| p.join("pixmaps").join(format!("{nome}.png")))
            .find(|p| p.exists())
    }

    fn png_base64(caminho: &Path) -> Option<String> {
        use base64::Engine;
        let mut img = image::open(caminho).ok()?;
        if img.width() > 64 || img.height() > 64 {
            img = img.resize(64, 64, image::imageops::FilterType::Triangle);
        }
        let mut png = std::io::Cursor::new(Vec::new());
        img.write_to(&mut png, image::ImageFormat::Png).ok()?;
        Some(base64::engine::general_purpose::STANDARD.encode(png.into_inner()))
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn pt() -> Vec<String> {
        vec!["pt_BR".into(), "pt".into()]
    }

    fn ler(texto: &str) -> Option<Atalho> {
        ler_atalho(
            texto,
            "x.desktop",
            Path::new("/x.desktop"),
            &pt(),
            "ubuntu:GNOME",
        )
    }

    #[test]
    fn le_nome_em_portugues_icone_e_comando() {
        let a = ler(
            "[Desktop Entry]\nType=Application\nName=Text Editor\nName[pt_BR]=Editor de Texto\n\
             Icon=org.gnome.TextEditor\nExec=gnome-text-editor %U\n\
             [Desktop Action new-window]\nName=New Window\nExec=gnome-text-editor --new-window\n",
        )
        .unwrap();
        assert_eq!(a.nome, "Editor de Texto");
        assert_eq!(a.icone, "org.gnome.TextEditor");
        assert_eq!(a.comando, vec!["gnome-text-editor"]);
    }

    #[test]
    fn o_que_o_menu_esconde_fica_de_fora() {
        assert!(
            ler("[Desktop Entry]\nType=Application\nName=A\nExec=a\nNoDisplay=true\n").is_none()
        );
        assert!(ler("[Desktop Entry]\nType=Link\nName=A\nURL=http://x\n").is_none());
        assert!(
            ler("[Desktop Entry]\nType=Application\nName=A\nExec=a\nOnlyShowIn=KDE;\n").is_none()
        );
        assert!(
            ler("[Desktop Entry]\nType=Application\nName=A\nExec=a\nNotShowIn=GNOME;\n").is_none()
        );
        assert!(ler(
            "[Desktop Entry]\nType=Application\nName=A\nExec=a\nOnlyShowIn=GNOME;Unity;\n"
        )
        .is_some());
    }

    #[test]
    fn exec_com_aspas_codigos_e_embrulhos() {
        assert_eq!(
            comando_do_exec(r#""/opt/Meu App/app" --flag %F"#),
            vec!["/opt/Meu App/app", "--flag"]
        );
        assert_eq!(comando_do_exec("app 100%% %u"), vec!["app", "100%"]);
        assert_eq!(
            executavel(&comando_do_exec(
                "env BAMF_DESKTOP_FILE_HINT=/x.desktop /snap/bin/firefox %u"
            )),
            Some("firefox".into())
        );
        assert_eq!(
            executavel(&comando_do_exec("/usr/bin/flatpak run org.x.App")),
            None
        );
    }

    #[test]
    fn favoritos_do_gnome_e_idiomas() {
        assert_eq!(
            favoritos("['firefox_firefox.desktop', 'org.gnome.Nautilus.desktop']\n"),
            vec!["firefox_firefox.desktop", "org.gnome.Nautilus.desktop"]
        );
        assert!(favoritos("@as []").is_empty());
        assert_eq!(idiomas("pt_BR.UTF-8"), vec!["pt_BR", "pt"]);
        assert!(idiomas("C.UTF-8").is_empty());
    }

    #[test]
    fn reconhece_o_programa_pelo_processo() {
        let editor =
            ler("[Desktop Entry]\nType=Application\nName=Editor\nExec=gnome-text-editor %U\n")
                .unwrap();
        let mut code =
            ler("[Desktop Entry]\nType=Application\nName=VS Code\nExec=/usr/share/code/code %F\n")
                .unwrap();
        code.id = "code.desktop".into();
        let mut arquivos = ler(
            "[Desktop Entry]\nType=Application\nName=Arquivos\nExec=nautilus --new-window %U\n",
        )
        .unwrap();
        arquivos.id = "org.gnome.Nautilus.desktop".into();
        let todos = vec![editor, code, arquivos];
        let args = |s: &[&str]| s.iter().map(|x| x.to_string()).collect::<Vec<_>>();

        let achado = atalho_do_processo(
            "/usr/bin/gnome-text-editor",
            &args(&["gnome-text-editor"]),
            &todos,
        );
        assert_eq!(achado.map(|a| a.nome.as_str()), Some("Editor"));
        let achado = atalho_do_processo(
            "/usr/share/code/code",
            &args(&["/usr/share/code/code"]),
            &todos,
        );
        assert_eq!(achado.map(|a| a.nome.as_str()), Some("VS Code"));
        // O Arquivos como serviço do GNOME, sem janela: não é programa aberto.
        assert!(atalho_do_processo(
            "/usr/bin/nautilus",
            &args(&["/usr/bin/nautilus", "--gapplication-service"]),
            &todos
        )
        .is_none());
        assert!(atalho_do_processo("/usr/bin/bash", &args(&["bash"]), &todos).is_none());
    }
}
