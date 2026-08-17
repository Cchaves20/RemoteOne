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
//! Agora quem instala é o **próprio executável** (`deskside-agent.exe
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
pub const APP_NAME: &str = "Deskside";

/// Nome do atalho na pasta Inicializar.
pub const STARTUP_FILE: &str = "DesksideAgent.vbs";

/// Chave de desinstalação, sob `HKCU`. Fica no usuário e não na máquina porque
/// a instalação é por usuário — e escrever em `HKLM` exigiria administrador.
pub const UNINSTALL_KEY: &str =
    r"Software\Microsoft\Windows\CurrentVersion\Uninstall\Deskside";

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
        "' Inicia o agente do Deskside oculto, sem janela de console.\r\n\
         Set sh = CreateObject(\"WScript.Shell\")\r\n\
         sh.Run \"\"\"{caminho}\"\"\", 0, False\r\n"
    )
}

/// Nome da tarefa agendada que inicia o agente no logon.
pub const TASK_NAME: &str = "Deskside";

/// O comando do PowerShell que cria a tarefa agendada do logon.
///
/// ## Por que uma tarefa, e não a pasta Inicializar
///
/// A pasta Inicializar é a forma mais lenta que existe de subir no logon, e não
/// por acaso: quem a processa é o Explorer, **depois** de terminar de carregar,
/// e o Windows 10/11 ainda aplica um retardo próprio ao que está nela. O
/// resultado, num notebook, são dezenas de segundos entre entrar na conta e o
/// computador ficar alcançável — e nesse intervalo o app mostra o computador
/// offline, que é indistinguível de defeito.
///
/// Uma tarefa com disparo "ao fazer logon" não espera o Explorer. É o mesmo
/// mecanismo que os programas que sobem rápido usam.
///
/// ## Os quatro ajustes que não são enfeite
///
/// Os padrões do Agendador de Tarefas foram pensados para tarefas de manutenção,
/// e três deles quebrariam este agente em silêncio:
///
/// - **`AllowStartIfOnBatteries`**: o padrão é *não iniciar* na bateria. Num
///   notebook fora da tomada — o caso mais comum — o agente simplesmente não
///   subiria, e nada diria por quê.
/// - **`DontStopIfGoingOnBatteries`**: sem isto, tirar o notebook da tomada
///   **encerra** o agente no meio do uso.
/// - **`ExecutionTimeLimit = PT0S`** (sem limite): o padrão é três dias, e ao
///   fim deles a tarefa é morta. Um computador que fica ligado a semana toda
///   perderia o agente sem motivo aparente.
/// - **`Priority = 5`**: o padrão é 7, que o Windows traduz em prioridade
///   *abaixo do normal* para o processo. Justamente no logon, quando há disputa
///   por disco e CPU, isso é o oposto do que se quer.
///
/// ## O escape
///
/// O caminho entra num literal de aspas simples do PowerShell, onde a aspa
/// simples se escapa **dobrando**. Sem isso, um usuário chamado `O'Brien` (ou
/// qualquer pasta com apóstrofo) quebraria o comando — e o sintoma seria "a
/// tarefa não foi criada nesta máquina", sem ninguém ligar à causa.
pub fn script_da_tarefa(launcher: &Path, usuario: &str) -> String {
    let ps = |t: String| t.replace('\'', "''");
    let vbs = ps(launcher.display().to_string());
    let quem = ps(usuario.to_string());
    format!(
        "$ErrorActionPreference='Stop'; \
         $acao = New-ScheduledTaskAction -Execute 'wscript.exe' -Argument '\"{vbs}\"'; \
         $disparo = New-ScheduledTaskTrigger -AtLogOn -User '{quem}'; \
         $ajustes = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries \
         -DontStopIfGoingOnBatteries -StartWhenAvailable -MultipleInstances IgnoreNew; \
         $ajustes.ExecutionTimeLimit = 'PT0S'; \
         $ajustes.Priority = 5; \
         Register-ScheduledTask -TaskName '{TASK_NAME}' -Action $acao -Trigger $disparo \
         -Settings $ajustes -Force | Out-Null"
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
    /// O `.vbs` que inicia o agente oculto, ao lado do executável.
    ///
    /// Mora na pasta de instalação, e não na Inicializar, porque agora ele é
    /// **alvo da tarefa agendada**. A cópia na pasta Inicializar continua
    /// existindo, mas só como reserva — ver `install`.
    pub launcher: PathBuf,
    /// Atalho na pasta Inicializar. A **reserva**, quando a tarefa não pode ser
    /// criada.
    pub startup: PathBuf,
    /// Atalho no Menu Iniciar.
    pub start_menu: PathBuf,
    /// Atalho na área de trabalho.
    pub desktop: PathBuf,
    /// Se o executável precisa ser copiado (falso ao reconfigurar no lugar).
    pub copy: bool,
}

/// Onde o Windows guarda cada coisa. Agrupadas porque são quatro caminhos que
/// andam juntos, e quatro parâmetros soltos do mesmo tipo `Path` são um convite
/// a trocar dois de lugar sem o compilador notar.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Places {
    pub local_app_data: PathBuf,
    pub startup: PathBuf,
    pub start_menu: PathBuf,
    pub desktop: PathBuf,
}

/// Monta o plano a partir dos caminhos do sistema.
pub fn plan(exe_atual: &Path, lugares: &Places) -> Plan {
    let dir = install_dir(&lugares.local_app_data);
    let exe = dir.join("deskside-agent.exe");
    let copy = !already_installed(exe_atual, &exe);
    Plan {
        launcher: dir.join(STARTUP_FILE),
        dir,
        exe,
        startup: lugares.startup.join(STARTUP_FILE),
        // O `.lnk` leva o nome que aparece embaixo do ícone.
        start_menu: lugares.start_menu.join(format!("{APP_NAME}.lnk")),
        desktop: lugares.desktop.join(format!("{APP_NAME}.lnk")),
        copy,
    }
}

/// Resumo do que está instalado, para o `status`.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Status {
    pub installed: bool,
    pub autostart: bool,
    /// Por qual mecanismo ele sobe no logon.
    ///
    /// Vale dizer porque os dois funcionam e **um é muito mais rápido**. Quando
    /// alguém reclamar que o agente demora a ficar disponível depois de ligar o
    /// computador, esta linha é a primeira coisa a olhar — e sem ela a resposta
    /// começaria por dedução.
    pub autostart_por_tarefa: bool,
    pub exe: PathBuf,
    pub backend: String,
    /// Se o backend veio de uma variável de ambiente em vez do arquivo.
    ///
    /// Vale dizer porque a variável **vence** o arquivo: sem isso, alguém que
    /// trocou o servidor no `agent.conf` veria aqui o valor antigo e não teria
    /// como saber por quê.
    pub backend_from_env: bool,
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
    linhas.push(match (s.autostart, s.autostart_por_tarefa) {
        (false, _) => "Inicia com o Windows: não".to_string(),
        (true, true) => "Inicia com o Windows: sim (tarefa agendada — a forma rápida)".to_string(),
        // A reserva. Funciona, e é a razão de o agente demorar a subir: a pasta
        // Inicializar é processada pelo Explorer depois de ele carregar, e o
        // Windows ainda atrasa de propósito o que está nela.
        (true, false) => {
            "Inicia com o Windows: sim (pasta Inicializar — sobe mais devagar)".to_string()
        }
    });
    if s.backend_from_env {
        linhas.push(format!(
            "Backend: {} (da variável de ambiente, que vence o arquivo)",
            s.backend
        ));
    } else {
        linhas.push(format!("Backend: {}", s.backend));
    }
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
/// É esta chave que faz o Deskside aparecer em "Aplicativos instalados" com um
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

    /// O Menu Iniciar do usuário: a mesma raiz da pasta Inicializar, um nível
    /// acima. Fica em Aplicativos, achável pelo nome na busca do Windows.
    fn start_menu_dir() -> Result<PathBuf, String> {
        Ok(pasta("APPDATA")?
            .join("Microsoft")
            .join("Windows")
            .join("Start Menu")
            .join("Programs"))
    }

    /// A área de trabalho.
    ///
    /// `%USERPROFILE%\\Desktop` erra quando a pasta foi redirecionada para o
    /// OneDrive - e isso é o padrão em máquina nova com conta Microsoft, que é
    /// justamente o caso do usuário comum. O caminho certo está no registro,
    /// em Shell Folders, que o Windows mantém atualizado.
    fn desktop_dir() -> Result<PathBuf, String> {
        let saida = Command::new("reg")
            .args([
                "query",
                r"HKCU\Software\Microsoft\Windows\CurrentVersion\Explorer\Shell Folders",
                "/v",
                "Desktop",
            ])
            .output()
            .map_err(|e| format!("não consegui perguntar onde fica a área de trabalho: {e}"))?;
        let texto = String::from_utf8_lossy(&saida.stdout);
        // A saída é "    Desktop    REG_SZ    C:\Users\eu\OneDrive\Desktop".
        let caminho = texto
            .lines()
            .find_map(|l| l.split("REG_SZ").nth(1))
            .map(str::trim)
            .filter(|s| !s.is_empty());
        match caminho {
            Some(c) => Ok(PathBuf::from(c)),
            // Sem registro, o palpite antigo ainda é melhor que desistir.
            None => Ok(pasta("USERPROFILE")?.join("Desktop")),
        }
    }

    fn lugares() -> Result<Places, String> {
        Ok(Places {
            local_app_data: pasta("LOCALAPPDATA")?,
            startup: startup_dir()?,
            start_menu: start_menu_dir()?,
            desktop: desktop_dir()?,
        })
    }

    /// Cria um atalho `.lnk` apontando para o executável instalado.
    ///
    /// Escrito direto, sem COM e sem PowerShell. O instalador já é o momento
    /// em que mais coisa pode dar errado numa máquina alheia, e cada processo
    /// externo é mais uma forma de falhar - incluindo antivírus que barram um
    /// `powershell.exe` disparado por um instalador.
    fn criar_atalho(exe: &Path, destino: &Path) -> Result<(), String> {
        if let Some(pai) = destino.parent() {
            let _ = std::fs::create_dir_all(pai);
        }
        let mut link = mslnk::ShellLink::new(exe)
            .map_err(|e| format!("não montei o atalho: {e}"))?;
        link.set_name(Some(format!("{APP_NAME} - controle remoto")));
        // O ícone vem do próprio executável (embutido pelo build.rs).
        link.create_lnk(destino)
            .map_err(|e| format!("não gravei {}: {e}", destino.display()))
    }

    fn current_exe() -> Result<PathBuf, String> {
        std::env::current_exe().map_err(|e| format!("não descobri o próprio caminho: {e}"))
    }

    /// Encerra qualquer agente que já esteja rodando, **menos este processo**.
    ///
    /// Sem parar os outros, instalar por cima deixaria dois agentes conectados
    /// com o mesmo `device_id`, e o backend entregaria os comandos a um deles
    /// por sorteio.
    ///
    /// A exclusão do próprio PID não é detalhe: quem instala **é** o
    /// `deskside-agent.exe`, e um `taskkill /IM deskside-agent.exe` mata
    /// todos os processos com esse nome — inclusive o instalador, no meio da
    /// instalação. O sintoma foi um `install` que não imprimiu uma linha
    /// sequer e não copiou nada, deixando para trás a impressão de que não
    /// tinha feito nada por escolha.
    fn stop_running() {
        let eu = std::process::id();
        let _ = Command::new("taskkill")
            .args([
                "/IM",
                "deskside-agent.exe",
                "/F",
                "/FI",
                &format!("PID ne {eu}"),
            ])
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

    /// Roda um comando do PowerShell sem perfil e sem interação.
    ///
    /// `-ExecutionPolicy Bypass` porque a política de execução da máquina não
    /// tem nada a dizer sobre isto: é um comando na linha, não um arquivo, e
    /// numa máquina com política restritiva a instalação falharia por um motivo
    /// que não é dela.
    fn powershell(comando: &str) -> Result<std::process::Output, String> {
        Command::new("powershell")
            .args([
                "-NoProfile",
                "-NonInteractive",
                "-ExecutionPolicy",
                "Bypass",
                "-Command",
                comando,
            ])
            .output()
            .map_err(|e| format!("não consegui chamar o PowerShell: {e}"))
    }

    /// Cria a tarefa agendada que inicia o agente no logon.
    fn criar_tarefa(launcher: &Path) -> Result<(), String> {
        // `USERDOMAIN` é o nome da máquina em conta local e em conta Microsoft;
        // só num domínio corporativo ele é outra coisa. Nos dois casos é o que
        // o Agendador espera.
        let dominio = std::env::var("USERDOMAIN").unwrap_or_default();
        let nome = std::env::var("USERNAME")
            .map_err(|_| "não descobri o nome do usuário do Windows".to_string())?;
        let usuario = if dominio.is_empty() {
            nome
        } else {
            format!("{dominio}\\{nome}")
        };

        let saida = powershell(&script_da_tarefa(launcher, &usuario))?;
        if saida.status.success() {
            return Ok(());
        }
        // A mensagem do PowerShell vai junto: "a tarefa não foi criada" sozinho
        // não diz se foi política de grupo, serviço desligado ou nome de
        // usuário estranho — e são consertos diferentes.
        let motivo = String::from_utf8_lossy(&saida.stderr)
            .lines()
            .find(|l| !l.trim().is_empty())
            .unwrap_or("o PowerShell recusou sem dizer o motivo")
            .trim()
            .to_string();
        Err(motivo)
    }

    fn remover_tarefa() {
        let _ = powershell(&format!(
            "Unregister-ScheduledTask -TaskName '{TASK_NAME}' \
             -Confirm:$false -ErrorAction SilentlyContinue"
        ));
    }

    /// Se a tarefa agendada existe. Usado pelo `status`.
    pub fn tem_tarefa() -> bool {
        powershell(&format!(
            "if (Get-ScheduledTask -TaskName '{TASK_NAME}' \
             -ErrorAction SilentlyContinue) {{ exit 0 }} else {{ exit 1 }}"
        ))
        .map(|s| s.status.success())
        .unwrap_or(false)
    }

    pub fn install(backend: Option<&str>) -> Result<(), String> {
        let exe_atual = current_exe()?;
        let plano = plan(&exe_atual, &lugares()?);

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
            cfg.set("DESKSIDE_BACKEND_URL", url);
            if let Some(pai) = caminho.parent() {
                let _ = std::fs::create_dir_all(pai);
            }
            std::fs::write(&caminho, cfg.to_text())
                .map_err(|e| format!("não consegui gravar {}: {e}", caminho.display()))?;
            println!("Backend: {url}");
            // O instalador antigo guardava a URL numa variável de ambiente do
            // usuário, e variável vence arquivo. Sem este aviso, alguém
            // trocaria de servidor aqui e continuaria conectando no antigo,
            // com o arquivo na tela dizendo o contrário.
            if let Ok(v) = std::env::var("DESKSIDE_BACKEND_URL") {
                if !v.trim().is_empty() && v != url {
                    println!();
                    println!("AVISO: a variável de ambiente DESKSIDE_BACKEND_URL vale {v}");
                    println!("e ela vence o arquivo. Provavelmente sobrou do instalador antigo.");
                    // `setx VAR ""` **não** apaga: o setx recusa valor vazio.
                    // Quem apaga uma variável de usuário é o registro.
                    println!(
                        "Para remover:  reg delete \"HKCU\\Environment\" \
                         /v DESKSIDE_BACKEND_URL /f"
                    );
                    println!("e abra um terminal novo.");
                }
            }
        }

        // O `.vbs` fica ao lado do executável: é ele que a tarefa agendada
        // chama, e é dele que sai a cópia de reserva.
        std::fs::write(&plano.launcher, launcher_script(&plano.exe))
            .map_err(|e| format!("não consegui criar o iniciador oculto: {e}"))?;

        // Tarefa agendada primeiro; pasta Inicializar só se ela falhar.
        //
        // **Uma das duas, nunca as duas.** Com as duas ativas, dois agentes
        // subiriam a cada logon; a guarda de instância única faria o segundo
        // sair, mas ela também pede que o primeiro **mostre a janela** — e uma
        // janela abrindo sozinha a cada vez que se liga o computador seria uma
        // troca terrível por alguns segundos de partida.
        match criar_tarefa(&plano.launcher) {
            Ok(()) => {
                let _ = std::fs::remove_file(&plano.startup);
                println!("Início automático: tarefa agendada no logon (a forma rápida).");
            }
            Err(motivo) => {
                std::fs::write(&plano.startup, launcher_script(&plano.exe))
                    .map_err(|e| format!("não consegui criar o atalho de início: {e}"))?;
                println!("Início automático: pasta Inicializar.");
                println!("  (não deu para criar a tarefa agendada: {motivo})");
                println!("  Funciona igual, só demora mais para subir ao ligar o computador.");
            }
        }

        // Atalhos são conveniência, não requisito: sem eles o agente roda
        // igual. Uma área de trabalho redirecionada para uma pasta de rede
        // fora do ar não pode derrubar uma instalação que já funciona.
        for (onde, destino) in [
            ("Menu Iniciar", &plano.start_menu),
            ("área de trabalho", &plano.desktop),
        ] {
            match criar_atalho(&plano.exe, destino) {
                Ok(()) => println!("Atalho no {onde}."),
                Err(e) => eprintln!("Aviso: sem atalho no {onde} ({e})"),
            }
        }

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
            .arg(&plano.launcher)
            .spawn()
            .map_err(|e| format!("instalei, mas não consegui iniciar: {e}"))?;

        println!();
        println!("Pronto. O agente roda oculto e sobe junto com o Windows.");
        println!("Os atalhos abrem o programa que já está rodando, não um segundo.");
        println!("O código de pareamento aparece numa janelinha e também em:");
        println!("  %APPDATA%\\deskside\\pairing-code.txt");
        println!();
        println!("Para remover: deskside-agent.exe uninstall");
        Ok(())
    }

    pub fn uninstall() -> Result<(), String> {
        let exe_atual = current_exe()?;
        let plano = plan(&exe_atual, &lugares()?);

        stop_running();
        remover_tarefa();
        let _ = std::fs::remove_file(&plano.startup);
        let _ = std::fs::remove_file(&plano.launcher);
        let _ = std::fs::remove_file(&plano.start_menu);
        let _ = std::fs::remove_file(&plano.desktop);
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
        println!("A configuração e o device_id ficam em %APPDATA%\\deskside");
        println!("(assim, reinstalar não obriga a parear de novo).");
        Ok(())
    }

    pub fn status() -> Status {
        let exe = pasta("LOCALAPPDATA")
            .map(|p| install_dir(&p).join("deskside-agent.exe"))
            .unwrap_or_default();
        let startup = startup_dir().map(|p| p.join(STARTUP_FILE)).unwrap_or_default();
        let cfg = crate::load_config();
        let do_ambiente = std::env::var("DESKSIDE_BACKEND_URL")
            .map(|v| !v.trim().is_empty())
            .unwrap_or(false);
        // A tarefa é o caminho preferido; a pasta Inicializar é a reserva. Os
        // dois entram no cálculo porque uma instalação antiga tem só o segundo.
        let tarefa = tem_tarefa();
        Status {
            installed: exe.is_file(),
            autostart: tarefa || startup.is_file(),
            autostart_por_tarefa: tarefa,
            exe,
            backend: crate::config::resolve(&cfg, "DESKSIDE_BACKEND_URL")
                .unwrap_or_else(|| crate::DEFAULT_BACKEND_URL.to_string()),
            backend_from_env: do_ambiente,
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
        let do_ambiente = std::env::var("DESKSIDE_BACKEND_URL")
            .map(|v| !v.trim().is_empty())
            .unwrap_or(false);
        Status {
            installed: false,
            autostart: false,
            autostart_por_tarefa: false,
            exe: std::env::current_exe().unwrap_or_default(),
            backend: crate::config::resolve(&cfg, "DESKSIDE_BACKEND_URL")
                .unwrap_or_else(|| crate::DEFAULT_BACKEND_URL.to_string()),
            backend_from_env: do_ambiente,
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
    fn a_tarefa_aponta_para_o_iniciador_oculto_e_dispara_no_logon() {
        let script = script_da_tarefa(&p(r"C:\App\DesksideAgent.vbs"), r"PC\eu");
        // `wscript` e não o `.exe` direto: é o que evita um console preto
        // piscando a cada logon.
        assert!(script.contains("-Execute 'wscript.exe'"), "{script}");
        assert!(script.contains(r"C:\App\DesksideAgent.vbs"), "{script}");
        assert!(script.contains("-AtLogOn"), "{script}");
        assert!(script.contains(r"-User 'PC\eu'"), "{script}");
    }

    #[test]
    fn a_tarefa_desliga_os_padroes_que_matariam_o_agente() {
        // Os padrões do Agendador foram feitos para tarefas de manutenção, e
        // três deles quebrariam este agente **em silêncio**: não iniciar na
        // bateria, encerrar ao sair da tomada, e matar a tarefa depois de três
        // dias. Num notebook, o primeiro sozinho já significa "nunca sobe".
        let script = script_da_tarefa(&p(r"C:\App\x.vbs"), "PC\\eu");
        assert!(script.contains("-AllowStartIfOnBatteries"), "{script}");
        assert!(script.contains("-DontStopIfGoingOnBatteries"), "{script}");
        assert!(script.contains("ExecutionTimeLimit = 'PT0S'"), "{script}");
        // E a prioridade: o padrão 7 vira "abaixo do normal" para o processo,
        // justamente no logon, quando há disputa por disco e CPU.
        assert!(script.contains("Priority = 5"), "{script}");
    }

    #[test]
    fn o_caminho_com_apostrofo_nao_quebra_o_comando() {
        // `C:\Users\O'Brien\...` é um caminho legítimo, e no PowerShell a aspa
        // simples se escapa dobrando. Sem isto o comando terminaria no meio do
        // caminho e a tarefa não seria criada - com o sintoma "não funciona
        // nesta máquina" e nada ligando à causa.
        let script = script_da_tarefa(&p(r"C:\Users\O'Brien\x.vbs"), "PC\\O'Brien");
        assert!(script.contains("O''Brien"), "{script}");
        assert!(!script.contains("O'Brien"), "sobrou uma aspa solta: {script}");
    }

    #[test]
    fn instala_na_pasta_por_usuario() {
        // `Program Files` exigiria elevação, e elevação é um passo a mais que
        // assusta — sem ganho nenhum, porque o agente roda no usuário.
        let local = caminho(&["C:", "Users", "eu", "AppData", "Local"]);
        assert_eq!(
            install_dir(&local),
            caminho(&["C:", "Users", "eu", "AppData", "Local", "Programs", "Deskside"])
        );
    }

    fn lugares_de_teste() -> Places {
        Places {
            local_app_data: caminho(&["C:", "Users", "eu", "AppData", "Local"]),
            startup: caminho(&["C:", "Users", "eu", "Startup"]),
            start_menu: caminho(&["C:", "Users", "eu", "Menu"]),
            desktop: caminho(&["C:", "Users", "eu", "Desktop"]),
        }
    }

    #[test]
    fn rodar_de_fora_copia_o_executavel() {
        let lugares = lugares_de_teste();
        let plano = plan(
            &caminho(&["C:", "repo", "target", "release", "deskside-agent.exe"]),
            &lugares,
        );
        assert!(plano.copy);
        assert_eq!(
            plano.exe,
            install_dir(&lugares.local_app_data).join("deskside-agent.exe")
        );
        assert_eq!(plano.startup, lugares.startup.join(STARTUP_FILE));
    }

    #[test]
    fn os_atalhos_apontam_para_o_executavel_instalado() {
        // O atalho tem que apontar para a cópia em Programs, e não para onde
        // o instalador foi executado. Apontar para a pasta de downloads faria
        // o atalho quebrar no dia em que alguém a limpasse - sem aviso, e sem
        // ninguém associar uma coisa à outra.
        let lugares = lugares_de_teste();
        let plano = plan(&caminho(&["C:", "Downloads", "deskside-agent.exe"]), &lugares);
        assert_eq!(plano.start_menu, lugares.start_menu.join("Deskside.lnk"));
        assert_eq!(plano.desktop, lugares.desktop.join("Deskside.lnk"));
        assert!(plano.exe.starts_with(&plano.dir));
    }

    #[test]
    fn rodar_de_dentro_nao_copia_sobre_si_mesmo() {
        // Copiar um arquivo sobre ele mesmo falha no Windows com "acesso
        // negado" - um erro que manda o diagnóstico para o lado errado. Quem
        // roda `install` já instalado está reconfigurando.
        let local = caminho(&["C:", "Users", "eu", "AppData", "Local"]);
        let instalado = install_dir(&local).join("deskside-agent.exe");
        let plano = plan(&instalado, &Places { local_app_data: local, ..lugares_de_teste() });
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
            .join("deskside-agent.exe");
        let entradas = uninstall_entries(&exe, "0.9.0");
        let mapa: std::collections::HashMap<_, _> = entradas.into_iter().collect();
        assert_eq!(
            mapa["UninstallString"],
            format!("\"{}\" uninstall", exe.display())
        );
        assert_eq!(mapa["DisplayName"], "Deskside");
        assert_eq!(mapa["DisplayVersion"], "0.9.0");
        assert!(mapa["InstallLocation"].ends_with("Deskside"));
    }

    #[test]
    fn o_status_diz_quando_nao_esta_instalado() {
        let linhas = status_lines(&Status {
            installed: false,
            autostart: false,
            autostart_por_tarefa: false,
            exe: p(r"C:\x\a.exe"),
            backend: "ws://127.0.0.1:8000/ws/agent".into(),
            backend_from_env: false,
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
            autostart_por_tarefa: true,
            exe: install_dir(&caminho(&["C:", "Users", "eu", "AppData", "Local"]))
                .join("deskside-agent.exe"),
            backend: "wss://deskside.com.br/ws/agent".into(),
            backend_from_env: false,
            device_id: Some("abc123".into()),
        });
        assert!(linhas[0].contains("Deskside"));
        // A linha agora diz **por qual mecanismo**, porque um deles é
        // muito mais rápido e é a primeira coisa a olhar numa queixa de demora.
        assert!(linhas[1].contains("sim") && linhas[1].contains("tarefa agendada"));
        assert!(linhas[2].contains("deskside.com.br"));
        assert!(linhas[3].contains("abc123"));
    }

    #[test]
    fn o_status_avisa_quando_o_ambiente_mascara_o_arquivo() {
        // O instalador antigo guardava a URL numa variável de ambiente do
        // usuário, e variável vence arquivo. Sem este aviso, quem trocasse de
        // servidor no `agent.conf` veria aqui o valor antigo, com o arquivo na
        // tela dizendo o contrário e nada explicando a diferença.
        let linhas = status_lines(&Status {
            installed: true,
            autostart: true,
            autostart_por_tarefa: true,
            exe: p("x"),
            backend: "wss://antigo/ws/agent".into(),
            backend_from_env: true,
            device_id: Some("id".into()),
        });
        assert!(linhas[2].contains("wss://antigo/ws/agent"));
        assert!(
            linhas[2].contains("variável de ambiente"),
            "precisa dizer de onde veio: {}",
            linhas[2]
        );
    }

    #[test]
    fn sem_variavel_o_status_nao_polui_a_linha() {
        let linhas = status_lines(&Status {
            installed: true,
            autostart: true,
            autostart_por_tarefa: true,
            exe: p("x"),
            backend: "wss://novo/ws/agent".into(),
            backend_from_env: false,
            device_id: Some("id".into()),
        });
        assert_eq!(linhas[2], "Backend: wss://novo/ws/agent");
    }

    #[test]
    fn instalado_sem_inicio_automatico_e_um_estado_visivel() {
        // Acontece de verdade: alguém tira o atalho da pasta Inicializar e
        // depois não entende por que o computador some do app. O `status`
        // precisa dizer isso em vez de mostrar tudo verde.
        let linhas = status_lines(&Status {
            installed: true,
            autostart: false,
            autostart_por_tarefa: false,
            exe: p(r"C:\x\a.exe"),
            backend: "x".into(),
            backend_from_env: false,
            device_id: Some("id".into()),
        });
        assert!(linhas[0].starts_with("Instalado em:"));
        assert!(linhas[1].ends_with("não"));
    }
}
