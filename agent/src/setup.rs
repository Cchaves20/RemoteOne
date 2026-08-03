//! Instalação do agente no Windows, sem terminal e sem administrador.
//!
//! O que existia antes era um script de PowerShell que compilava o projeto e
//! punha um atalho na pasta Inicializar apontando para `target\release`. Isso
//! serve a quem tem o código-fonte; não serve a quem só quer usar o programa:
//!
//! - Exigia o Rust instalado e a árvore do projeto no disco.
//! - O atalho apontava para dentro do repositório: mover ou apagar a pasta
//!   quebrava a inicialização, sem aviso.
//! - Não aparecia em "Aplicativos instalados", então desinstalar era procurar
//!   um script.
//!
//! Agora quem instala é o **próprio executável** (`remoteone-agent.exe
//! install`). A razão de estar aqui, em Rust, e não num script: este código
//! entra na verificação cruzada de tipos para Windows e tem as partes puras
//! cobertas por teste. Um `.ps1` não tem nem uma coisa nem outra — e o histórico
//! deste projeto mostra que o que não é verificado quebra na máquina do usuário.
//!
//! ## Por que a pasta Inicializar, e não um serviço
//!
//! Um serviço do Windows roda antes do login, na sessão 0, **sem área de
//! trabalho**. Ele não conseguiria capturar a tela nem mover o mouse — que é
//! tudo o que este agente faz. Ele precisa da sessão interativa, e por isso
//! inicia no login. Também é o que dispensa administrador.

use std::path::{Path, PathBuf};

/// Nome da pasta e da entrada em "Aplicativos instalados".
pub const APP_NAME: &str = "RemoteOne";

/// Nome do atalho na pasta Inicializar.
pub const STARTUP_FILE: &str = "RemoteOneAgent.vbs";

/// Chave de desinstalação, sob `HKCU`. Fica no usuário e não na máquina porque
/// a instalação é por usuário — e escrever em `HKLM` exigiria administrador.
pub const UNINSTALL_KEY: &str =
    r"Software\Microsoft\Windows\CurrentVersion\Uninstall\RemoteOne";

/// O launcher que roda o agente **oculto**.
///
/// Um `.vbs` com `WScript.Shell.Run(..., 0, False)` é o jeito de iniciar sem
/// janela nenhuma. Chamar o `.exe` direto pela pasta Inicializar faria piscar um
/// console preto a cada login — pequeno, mas é a diferença entre um programa e
/// uma gambiarra.
///
/// As aspas duplas dentro do VBScript são dobradas: é assim que a linguagem as
/// escapa, e sem isso um caminho com espaço (`C:\Program Files\...`, ou
/// qualquer usuário chamado "Ana Maria") quebraria o comando.
pub fn launcher_script(exe: &Path) -> String {
    let caminho = exe.display().to_string().replace('"', "\"\"");
    format!(
        "' Inicia o agente do RemoteOne oculto, sem janela de console.\r\n\
         Set sh = CreateObject(\"WScript.Shell\")\r\n\
         sh.Run \"\"\"{caminho}\"\"\", 0, False\r\n"
    )
}

/// Onde o agente passa a morar.
///
/// `%LOCALAPPDATA%\Programs` é o lugar que o Windows reserva para instalação
/// **por usuário**, que é a que dispensa administrador. `Program Files` exigiria
/// elevação para gravar, e elevação é um passo a mais que assusta.
pub fn install_dir(local_app_data: &Path) -> PathBuf {
    local_app_data.join("Programs").join(APP_NAME)
}

/// Se este executável já é o instalado.
///
/// Importa porque copiar um arquivo sobre ele mesmo falha no Windows, e o erro
/// que aparece ("acesso negado") manda o diagnóstico para o lado errado. Quem
/// roda `install` de dentro da pasta instalada está reconfigurando, não
/// copiando.
pub fn already_installed(exe: &Path, destino: &Path) -> bool {
    // Comparação sem diferenciar maiúsculas: caminhos no Windows não as
    // distinguem, e `C:\Users\Eu` e `c:\users\eu` são o mesmo lugar.
    exe.display().to_string().to_lowercase() == destino.display().to_string().to_lowercase()
}

/// O que uma instalação precisa saber. Separado do ato de instalar para que a
/// decisão — o que vai onde — possa ser conferida sem tocar em disco algum.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Plan {
    /// Pasta de destino.
    pub dir: PathBuf,
    /// Executável instalado.
    pub exe: PathBuf,
    /// Atalho na pasta Inicializar.
    pub startup: PathBuf,
    /// Se o executável precisa ser copiado (falso ao reconfigurar no lugar).
    pub copy: bool,
}

/// Monta o plano a partir dos caminhos do sistema.
pub fn plan(exe_atual: &Path, local_app_data: &Path, startup_dir: &Path) -> Plan {
    let dir = install_dir(local_app_data);
    let exe = dir.join("remoteone-agent.exe");
    let copy = !already_installed(exe_atual, &exe);
    Plan {
        dir,
        exe,
        startup: startup_dir.join(STARTUP_FILE),
        copy,
    }
}

/// Resumo do que está instalado, para o `status`.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Status {
    pub installed: bool,
    pub autostart: bool,
    pub exe: PathBuf,
    pub backend: String,
    pub device_id: Option<String>,
}

/// O texto do `status`, em linhas.
///
/// Puro para poder ser testado: o valor deste comando está em dizer a verdade
/// quando algo não está no lugar, e é justamente esse caso que não dá para
/// exercitar à mão sem quebrar a instalação de propósito.
pub fn status_lines(s: &Status) -> Vec<String> {
    let mut linhas = Vec::new();
    if s.installed {
        linhas.push(format!("Instalado em: {}", s.exe.display()));
    } else {
        linhas.push("Não instalado (rodando de onde está).".to_string());
    }
    linhas.push(format!(
        "Inicia com o Windows: {}",
        if s.autostart { "sim" } else { "não" }
    ));
    linhas.push(format!("Backend: {}", s.backend));
    match &s.device_id {
        Some(id) => linhas.push(format!("device_id: {id}")),
        // Sem device_id é o estado de quem nunca rodou: dizer isso evita que a
        // pessoa procure o código de pareamento que ainda não existe.
        None => linhas.push("device_id: ainda não gerado (o agente nunca rodou)".to_string()),
    }
    linhas
}

/// Os valores da chave de desinstalação, como o Windows os espera.
///
/// É esta chave que faz o RemoteOne aparecer em "Aplicativos instalados" com um
/// botão de desinstalar. Sem ela o programa fica invisível para o sistema, e a
/// única forma de removê-lo seria saber de cor onde ele se escondeu.
pub fn uninstall_entries(exe: &Path, versao: &str) -> Vec<(String, String)> {
    vec![
        ("DisplayName".into(), APP_NAME.into()),
        ("DisplayVersion".into(), versao.into()),
        ("Publisher".into(), APP_NAME.into()),
        (
            "UninstallString".into(),
            format!("\"{}\" uninstall", exe.display()),
        ),
        ("DisplayIcon".into(), exe.display().to_string()),
        (
            "InstallLocation".into(),
            exe.parent().unwrap_or(exe).display().to_string(),
        ),
        // Instalação por usuário: sem isto o Windows a listaria como se fosse
        // da máquina inteira, e um segundo usuário veria um programa que não
        // consegue remover.
        ("NoModify".into(), "1".into()),
        ("NoRepair".into(), "1".into()),
    ]
}

#[cfg(windows)]
mod imp {
    use super::*;
    use std::process::Command;

    fn pasta(var: &str) -> Result<PathBuf, String> {
        std::env::var_os(var)
            .map(PathBuf::from)
            .ok_or_else(|| format!("a variável {var} não existe neste Windows"))
    }

    /// A pasta Inicializar do usuário.
    ///
    /// Montada a partir de `%APPDATA%` em vez de perguntada ao sistema: é um
    /// caminho fixo desde o Windows 7, e evita uma chamada de API só para isto.
    fn startup_dir() -> Result<PathBuf, String> {
        Ok(pasta("APPDATA")?
            .join("Microsoft")
            .join("Windows")
            .join("Start Menu")
            .join("Programs")
            .join("Startup"))
    }

    fn current_exe() -> Result<PathBuf, String> {
        std::env::current_exe().map_err(|e| format!("não descobri o próprio caminho: {e}"))
    }

    /// Encerra qualquer agente que já esteja rodando.
    ///
    /// Sem isto, instalar por cima deixaria dois agentes conectados com o mesmo
    /// `device_id` — e o backend entregaria os comandos a um deles, sorteando.
    fn stop_running() {
        let _ = Command::new("taskkill")
            .args(["/IM", "remoteone-agent.exe", "/F"])
            .output();
    }

    fn reg_add(key: &str, nome: &str, valor: &str) -> Result<(), String> {
        let saida = Command::new("reg")
            .args([
                "add",
                &format!("HKCU\\{key}"),
                "/v",
                nome,
                "/t",
                "REG_SZ",
                "/d",
                valor,
                "/f",
            ])
            .output()
            .map_err(|e| format!("não consegui escrever no registro: {e}"))?;
        if !saida.status.success() {
            return Err(format!(
                "o registro recusou {nome}: {}",
                String::from_utf8_lossy(&saida.stderr).trim()
            ));
        }
        Ok(())
    }

    pub fn install(backend: Option<&str>) -> Result<(), String> {
        let exe_atual = current_exe()?;
        let plano = plan(&exe_atual, &pasta("LOCALAPPDATA")?, &startup_dir()?);

        stop_running();

        std::fs::create_dir_all(&plano.dir)
            .map_err(|e| format!("não consegui criar {}: {e}", plano.dir.display()))?;
        if plano.copy {
            std::fs::copy(&exe_atual, &plano.exe)
                .map_err(|e| format!("não consegui copiar para {}: {e}", plano.exe.display()))?;
            println!("Copiado para {}", plano.exe.display());
        } else {
            println!("Já estava em {} — só reconfigurando.", plano.exe.display());
        }

        // A URL do backend vai para o arquivo de configuração, e não para uma
        // variável de ambiente do usuário: variável não acompanha o programa,
        // e desinstalar deixaria o rastro para trás.
        if let Some(url) = backend {
            let caminho = crate::config_path();
            let mut cfg = crate::load_config();
            cfg.set("REMOTEONE_BACKEND_URL", url);
            if let Some(pai) = caminho.parent() {
                let _ = std::fs::create_dir_all(pai);
            }
            std::fs::write(&caminho, cfg.to_text())
                .map_err(|e| format!("não consegui gravar {}: {e}", caminho.display()))?;
            println!("Backend: {url}");
        }

        std::fs::write(&plano.startup, launcher_script(&plano.exe))
            .map_err(|e| format!("não consegui criar o atalho de início: {e}"))?;

        for (nome, valor) in uninstall_entries(&plano.exe, env!("CARGO_PKG_VERSION")) {
            // O registro é conveniência, não requisito: sem ele o agente roda
            // igual, só não aparece em "Aplicativos instalados". Falhar aqui
            // não pode desfazer uma instalação que já funciona.
            if let Err(e) = reg_add(UNINSTALL_KEY, &nome, &valor) {
                eprintln!("Aviso: {e}");
                break;
            }
        }

        // Sobe agora, sem esperar o próximo login.
        Command::new("wscript.exe")
            .arg(&plano.startup)
            .spawn()
            .map_err(|e| format!("instalei, mas não consegui iniciar: {e}"))?;

        println!();
        println!("Pronto. O agente roda oculto e sobe junto com o Windows.");
        println!("O código de pareamento aparece numa janelinha e também em:");
        println!("  %APPDATA%\\remoteone\\pairing-code.txt");
        println!();
        println!("Para remover: remoteone-agent.exe uninstall");
        Ok(())
    }

    pub fn uninstall() -> Result<(), String> {
        let exe_atual = current_exe()?;
        let plano = plan(&exe_atual, &pasta("LOCALAPPDATA")?, &startup_dir()?);

        stop_running();
        let _ = std::fs::remove_file(&plano.startup);
        let _ = Command::new("reg")
            .args(["delete", &format!("HKCU\\{UNINSTALL_KEY}"), "/f"])
            .output();

        // O executável que está rodando **agora** não pode se apagar. Quem
        // apaga é um `cmd` que espera um instante e some junto — sem isso a
        // desinstalação deixaria o próprio programa para trás, que é a única
        // parte que a pessoa realmente queria ver sumir.
        let alvo = plano.exe.display().to_string();
        let _ = Command::new("cmd")
            .args([
                "/C",
                &format!(
                    "timeout /t 2 /nobreak >nul & del /f /q \"{alvo}\" & rmdir \"{}\"",
                    plano.dir.display()
                ),
            ])
            .spawn();

        println!("Removido do início automático e de \"Aplicativos instalados\".");
        println!("A configuração e o device_id ficam em %APPDATA%\\remoteone");
        println!("(assim, reinstalar não obriga a parear de novo).");
        Ok(())
    }

    pub fn status() -> Status {
        let exe = pasta("LOCALAPPDATA")
            .map(|p| install_dir(&p).join("remoteone-agent.exe"))
            .unwrap_or_default();
        let startup = startup_dir().map(|p| p.join(STARTUP_FILE)).unwrap_or_default();
        let cfg = crate::load_config();
        Status {
            installed: exe.is_file(),
            autostart: startup.is_file(),
            exe,
            backend: crate::config::resolve(&cfg, "REMOTEONE_BACKEND_URL")
                .unwrap_or_else(|| crate::DEFAULT_BACKEND_URL.to_string()),
            device_id: std::fs::read_to_string(crate::device_id_path())
                .ok()
                .map(|s| s.trim().to_string())
                .filter(|s| !s.is_empty()),
        }
    }
}

#[cfg(not(windows))]
mod imp {
    use super::*;

    const SO_WINDOWS: &str = "a instalação em segundo plano só existe no Windows; \
                              em Linux/macOS rode o agente direto";

    pub fn install(_backend: Option<&str>) -> Result<(), String> {
        Err(SO_WINDOWS.to_string())
    }

    pub fn uninstall() -> Result<(), String> {
        Err(SO_WINDOWS.to_string())
    }

    pub fn status() -> Status {
        let cfg = crate::load_config();
        Status {
            installed: false,
            autostart: false,
            exe: std::env::current_exe().unwrap_or_default(),
            backend: crate::config::resolve(&cfg, "REMOTEONE_BACKEND_URL")
                .unwrap_or_else(|| crate::DEFAULT_BACKEND_URL.to_string()),
            device_id: std::fs::read_to_string(crate::device_id_path())
                .ok()
                .map(|s| s.trim().to_string())
                .filter(|s| !s.is_empty()),
        }
    }
}

pub use imp::{install, status, uninstall};

#[cfg(test)]
mod tests {
    use super::*;

    fn p(s: &str) -> PathBuf {
        PathBuf::from(s)
    }

    /// Caminhos montados com `join`, e não escritos com barra invertida.
    ///
    /// Estes testes rodam no Linux, onde `\` é um caractere comum de nome de
    /// arquivo e não um separador — um literal `C:\a\b` viraria **um** nome só.
    /// Montando com `join`, o que se confere é a estrutura (que pasta dentro de
    /// qual), que é o que o código de fato decide.
    fn caminho(partes: &[&str]) -> PathBuf {
        partes.iter().fold(PathBuf::new(), |acc, p| acc.join(p))
    }

    #[test]
    fn o_launcher_escapa_caminho_com_espaco() {
        // "Ana Maria" no nome de usuário é comum, e um caminho com espaço sem
        // aspas faria o VBScript tentar rodar "C:\Users\Ana" — que não existe.
        let vbs = launcher_script(&p(r"C:\Users\Ana Maria\App\agente.exe"));
        assert!(
            vbs.contains(r#"sh.Run """C:\Users\Ana Maria\App\agente.exe""", 0, False"#),
            "VBScript gerado:\n{vbs}"
        );
    }

    #[test]
    fn o_launcher_esconde_a_janela() {
        // O `0` é o que impede o console preto de piscar a cada login, e o
        // `False` é o que faz o script não ficar esperando o agente terminar.
        let vbs = launcher_script(&p(r"C:\x\a.exe"));
        assert!(vbs.contains(", 0, False"));
    }

    #[test]
    fn o_launcher_dobra_aspas_do_caminho() {
        // Aspas em nome de arquivo são raras, mas uma aspas solta fecharia a
        // string do VBScript e o resto do caminho viraria código.
        let vbs = launcher_script(&p(r#"C:\a"b\x.exe"#));
        assert!(!vbs.contains(r#"a"b"#), "aspas não foram dobradas:\n{vbs}");
        assert!(vbs.contains(r#"a""b"#));
    }

    #[test]
    fn instala_na_pasta_por_usuario() {
        // `Program Files` exigiria elevação, e elevação é um passo a mais que
        // assusta — sem ganho nenhum, porque o agente roda no usuário.
        let local = caminho(&["C:", "Users", "eu", "AppData", "Local"]);
        assert_eq!(
            install_dir(&local),
            caminho(&["C:", "Users", "eu", "AppData", "Local", "Programs", "RemoteOne"])
        );
    }

    #[test]
    fn rodar_de_fora_copia_o_executavel() {
        let local = caminho(&["C:", "Users", "eu", "AppData", "Local"]);
        let startup = caminho(&["C:", "Users", "eu", "Startup"]);
        let plano = plan(
            &caminho(&["C:", "repo", "target", "release", "remoteone-agent.exe"]),
            &local,
            &startup,
        );
        assert!(plano.copy);
        assert_eq!(plano.exe, install_dir(&local).join("remoteone-agent.exe"));
        assert_eq!(plano.startup, startup.join(STARTUP_FILE));
    }

    #[test]
    fn rodar_de_dentro_nao_copia_sobre_si_mesmo() {
        // Copiar um arquivo sobre ele mesmo falha no Windows com "acesso
        // negado" - um erro que manda o diagnóstico para o lado errado. Quem
        // roda `install` já instalado está reconfigurando.
        let local = caminho(&["C:", "Users", "eu", "AppData", "Local"]);
        let instalado = install_dir(&local).join("remoteone-agent.exe");
        let plano = plan(&instalado, &local, &caminho(&["C:", "Users", "eu", "Startup"]));
        assert!(!plano.copy);
    }

    #[test]
    fn caminho_do_windows_nao_diferencia_maiusculas() {
        assert!(already_installed(
            &p(r"C:\Users\Eu\App\Agente.exe"),
            &p(r"c:\users\eu\app\agente.exe")
        ));
        assert!(!already_installed(&p(r"C:\a\x.exe"), &p(r"C:\b\x.exe")));
    }

    #[test]
    fn a_desinstalacao_aponta_para_o_proprio_executavel() {
        // Se a `UninstallString` apontasse para o script do repositório, quem
        // recebeu só o .exe não teria como desinstalar pelo Windows.
        let exe = install_dir(&caminho(&["C:", "Users", "eu", "AppData", "Local"]))
            .join("remoteone-agent.exe");
        let entradas = uninstall_entries(&exe, "0.9.0");
        let mapa: std::collections::HashMap<_, _> = entradas.into_iter().collect();
        assert_eq!(
            mapa["UninstallString"],
            format!("\"{}\" uninstall", exe.display())
        );
        assert_eq!(mapa["DisplayName"], "RemoteOne");
        assert_eq!(mapa["DisplayVersion"], "0.9.0");
        assert!(mapa["InstallLocation"].ends_with("RemoteOne"));
    }

    #[test]
    fn o_status_diz_quando_nao_esta_instalado() {
        let linhas = status_lines(&Status {
            installed: false,
            autostart: false,
            exe: p(r"C:\x\a.exe"),
            backend: "ws://127.0.0.1:8000/ws/agent".into(),
            device_id: None,
        });
        assert!(linhas[0].contains("Não instalado"));
        assert!(linhas[1].contains("não"));
        assert!(linhas[3].contains("nunca rodou"));
    }

    #[test]
    fn o_status_mostra_onde_esta_e_para_onde_aponta() {
        let linhas = status_lines(&Status {
            installed: true,
            autostart: true,
            exe: install_dir(&caminho(&["C:", "Users", "eu", "AppData", "Local"]))
                .join("remoteone-agent.exe"),
            backend: "wss://caio-remoteone.duckdns.org/ws/agent".into(),
            device_id: Some("abc123".into()),
        });
        assert!(linhas[0].contains("RemoteOne"));
        assert!(linhas[1].ends_with("sim"));
        assert!(linhas[2].contains("duckdns"));
        assert!(linhas[3].contains("abc123"));
    }

    #[test]
    fn instalado_sem_inicio_automatico_e_um_estado_visivel() {
        // Acontece de verdade: alguém tira o atalho da pasta Inicializar e
        // depois não entende por que o computador some do app. O `status`
        // precisa dizer isso em vez de mostrar tudo verde.
        let linhas = status_lines(&Status {
            installed: true,
            autostart: false,
            exe: p(r"C:\x\a.exe"),
            backend: "x".into(),
            device_id: Some("id".into()),
        });
        assert!(linhas[0].starts_with("Instalado em:"));
        assert!(linhas[1].ends_with("não"));
    }
}
