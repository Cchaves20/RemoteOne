//! "Salvar o trabalho aberto": Ctrl+S, e só em quem sabe o que fazer com ele.
//!
//! Nasceu junto com o agendamento, e é ele que dá sentido ao recurso: uma
//! automação que fecha tudo às 18h com a pessoa longe do computador é uma
//! promessa de perder trabalho. Salvar antes de fechar é o que torna "fim de
//! expediente" seguro o bastante para alguém agendar.
//!
//! ## Por que uma lista escrita à mão
//!
//! A tentação é mandar Ctrl+S em tudo que está aberto. Não dá: **Ctrl+S não
//! significa "salvar" em toda parte.** Num navegador ele abre "salvar página
//! como" — uma caixa modal que fica esperando alguém digitar um nome. A
//! automação seguiria em frente, o passo seguinte tentaria fechar os programas,
//! e o computador terminaria a noite com uma caixa de diálogo aberta no meio da
//! tela. Em outros programas o mesmo atalho faz coisa completamente diferente.
//!
//! Então é uma lista de permissão, e não de exclusão. Uma lista de exclusão
//! erraria por omissão: todo programa novo do mundo entraria nela sozinho, e o
//! erro só apareceria na noite em que alguém deixasse a automação rodando. Uma
//! lista de permissão erra por silêncio — um editor que falta simplesmente não
//! é salvo, e isso se conserta acrescentando uma linha aqui.
//!
//! ## O que ainda pode dar errado, e por que tudo bem
//!
//! Um arquivo **novo e nunca salvo** abre "salvar como" mesmo num editor de
//! verdade. Não há como saber isso de fora sem adivinhar pelo título da janela,
//! que é frágil em cinco idiomas. O desfecho, porém, é o seguro: a caixa fica
//! aberta, e um `CloseAll` depois não consegue fechar aquele programa — que é
//! exatamente o que se quer, porque o que estava lá não tinha sido salvo. Nada
//! se perde; alguém encontra a caixa no dia seguinte.

use std::time::Duration;

use crate::apps::AppInfo;

/// Quanto esperar depois de trazer a janela para a frente.
///
/// O Ctrl+S vai para quem tem o foco, e o foco não muda no mesmo instante em
/// que se pede. Mandar a tecla cedo demais a entrega ao programa **anterior** —
/// e aí ela vira um Ctrl+S no navegador, que é o que esta lista existe para
/// evitar.
pub const ESPERA_FOCO: Duration = Duration::from_millis(350);

/// Quanto esperar depois do Ctrl+S, antes de ir ao próximo.
///
/// Gravar um arquivo grande não é instantâneo, e roubar o foco no meio da
/// gravação é como um editor reage pior.
pub const ESPERA_SALVAR: Duration = Duration::from_millis(600);

/// Teto de programas salvos num passo.
///
/// Cada um custa quase um segundo entre foco e gravação. Sem teto, uma máquina
/// com trinta janelas abertas transformaria um passo em meio minuto — e o
/// orçamento de espera da automação inteira é de sessenta segundos.
pub const MAX_ALVOS: usize = 12;

/// Os programas em que Ctrl+S grava o que está aberto, e não abre uma caixa.
///
/// Nomes de processo em minúsculas, sem `.exe`. Ao acrescentar um: a pergunta
/// não é "isto é um editor?", e sim "**Ctrl+S neste programa, com um arquivo já
/// salvo antes, grava sem perguntar nada?**". Se a resposta for "abre uma
/// janela", ele não entra.
pub const EDITORES: &[&str] = &[
    // Código e texto puro
    "code",
    "code-insiders",
    "cursor",
    "windsurf",
    "zed",
    "devenv",
    "notepad",
    "notepad++",
    "sublime_text",
    "gvim",
    "emacs",
    "geany",
    "atom",
    // JetBrains. Os nomes mudam com a arquitetura ("idea64", "idea"), e por
    // isso os dois estão aqui em vez de um casamento por prefixo solto.
    "idea",
    "idea64",
    "pycharm",
    "pycharm64",
    "webstorm",
    "webstorm64",
    "clion",
    "clion64",
    "rider",
    "rider64",
    "phpstorm",
    "phpstorm64",
    "goland",
    "goland64",
    "rubymine",
    "rubymine64",
    "datagrip",
    "datagrip64",
    "studio64",
    // Escritório
    "winword",
    "excel",
    "powerpnt",
    "onenote",
    "msaccess",
    "mspub",
    "visio",
    "wordpad",
    "write",
    "soffice",
    "swriter",
    "scalc",
    "simpress",
    // Notas
    "obsidian",
    "typora",
    "joplin",
    "logseq",
    // Imagem, vídeo e som
    "photoshop",
    "illustrator",
    "indesign",
    "premiere",
    "afterfx",
    "audition",
    "animate",
    "gimp",
    "inkscape",
    "krita",
    "blender",
    "audacity",
    "kdenlive",
    "shotcut",
    "resolve",
    // Engenharia
    "acad",
    "freecad",
    "kicad",
];

/// Um programa aberto que vale um Ctrl+S.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Alvo {
    pub pid: u32,
    pub nome: String,
}

/// Se este nome de processo está na lista.
///
/// Compara em minúsculas porque o Windows devolve `WINWORD` e a lista guarda
/// `winword` — e um recurso que dependesse da caixa das letras funcionaria em
/// alguns programas e não em outros, sem nada explicando a diferença.
pub fn e_editor(nome: &str) -> bool {
    let nome = nome.trim().to_ascii_lowercase();
    EDITORES.iter().any(|e| casa(&nome, e))
}

/// Casamento exato, ou com o sufixo de versão que alguns programas carregam.
///
/// `gimp-2.10` é o nome real do processo do GIMP, e `blender` às vezes vem com
/// a versão colada. Um prefixo solto seria perigoso — `wordpad` começa com
/// `word` —, então só conta como versão o que vem depois de um separador ou de
/// um dígito.
fn casa(nome: &str, editor: &str) -> bool {
    if nome == editor {
        return true;
    }
    nome.strip_prefix(editor).is_some_and(|resto| {
        resto.starts_with(['-', '_', ' ', '.'])
            || resto.chars().next().is_some_and(|c| c.is_ascii_digit())
    })
}

/// Quais dos programas abertos merecem o Ctrl+S, na ordem em que vieram.
///
/// Um por processo: duas janelas do mesmo editor chegariam como dois itens, e
/// salvar duas vezes o mesmo processo gastaria um segundo para nada — o Ctrl+S
/// vai para a janela em foco, e é a mesma nas duas voltas.
pub fn alvos(abertos: &[AppInfo]) -> Vec<Alvo> {
    let mut vistos: Vec<u32> = Vec::new();
    let mut fila = Vec::new();
    for app in abertos {
        if !e_editor(&app.name) {
            continue;
        }
        let Ok(pid) = app.id.parse::<u32>() else {
            continue;
        };
        if vistos.contains(&pid) {
            continue;
        }
        vistos.push(pid);
        fila.push(Alvo {
            pid,
            nome: app.name.clone(),
        });
        if fila.len() >= MAX_ALVOS {
            break;
        }
    }
    fila
}

/// O que aconteceu no passo.
#[derive(Debug, Clone, PartialEq, Eq, Default)]
pub struct Desfecho {
    pub salvos: usize,
    /// Quem não deu para salvar, com o motivo. Nunca interrompe os seguintes:
    /// um editor minimizado que não aceita foco não pode custar o Ctrl+S dos
    /// outros cinco.
    pub falhas: Vec<String>,
}

/// Traz cada alvo para a frente e manda o Ctrl+S.
///
/// As três ações da plataforma entram por fora para esta função poder ser
/// testada — sem isso, verificar "manda na ordem certa, espera entre uma e
/// outra, e uma falha não para as seguintes" exigiria abrir editores de
/// verdade.
pub fn salvar<F, T, D>(alvos: &[Alvo], mut focar: F, mut teclar: T, mut dormir: D) -> Desfecho
where
    F: FnMut(u32) -> Result<(), String>,
    T: FnMut() -> Result<(), String>,
    D: FnMut(Duration),
{
    let mut desfecho = Desfecho::default();
    for alvo in alvos {
        if let Err(motivo) = focar(alvo.pid) {
            desfecho.falhas.push(format!("{}: {motivo}", alvo.nome));
            continue;
        }
        dormir(ESPERA_FOCO);
        // O Ctrl+S só sai depois do foco confirmado. Mandá-lo mesmo quando o
        // foco falhou entregaria a tecla a quem estivesse na frente - que é
        // justamente o programa que esta lista existe para não receber Ctrl+S.
        if let Err(motivo) = teclar() {
            desfecho.falhas.push(format!("{}: {motivo}", alvo.nome));
            continue;
        }
        dormir(ESPERA_SALVAR);
        desfecho.salvos += 1;
    }
    desfecho
}

#[cfg(test)]
mod tests {
    use super::*;

    fn app(pid: &str, nome: &str) -> AppInfo {
        AppInfo {
            id: pid.into(),
            name: nome.into(),
            icon: None,
        }
    }

    #[test]
    fn navegador_nao_recebe_ctrl_s() {
        // O caso que define o recurso: num navegador o atalho abre "salvar
        // página como", uma caixa modal que fica esperando um nome. A automação
        // seguiria em frente e o computador passaria a noite com ela aberta.
        for nome in ["chrome", "msedge", "firefox", "opera", "brave"] {
            assert!(!e_editor(nome), "{nome} não podia estar na lista");
        }
    }

    #[test]
    fn a_caixa_das_letras_nao_muda_o_resultado() {
        // O Windows devolve `WINWORD`; a lista guarda `winword`. Sem isto o
        // recurso funcionaria em alguns programas e não em outros, e ninguém
        // ligaria a diferença à caixa das letras.
        assert!(e_editor("WINWORD"));
        assert!(e_editor("Code"));
        assert!(e_editor("  notepad  "));
    }

    #[test]
    fn sufixo_de_versao_casa_e_prefixo_solto_nao() {
        // `gimp-2.10` é o nome real do processo.
        assert!(e_editor("gimp-2.10"));
        assert!(e_editor("blender4.2"));
        // E `wordpad` começa com `word`, que é o acidente que a regra evita.
        assert!(!e_editor("codeblocks"));
        assert!(!e_editor("notepadqq"));
    }

    #[test]
    fn um_ctrl_s_por_processo() {
        // Duas janelas do mesmo editor chegam como dois itens; salvar duas
        // vezes o mesmo processo gastaria um segundo para nada.
        let abertos = [
            app("100", "code"),
            app("100", "code"),
            app("200", "chrome"),
            app("300", "WINWORD"),
        ];
        let fila = alvos(&abertos);
        assert_eq!(fila.len(), 2);
        assert_eq!(fila[0].pid, 100);
        assert_eq!(fila[1].pid, 300);
    }

    #[test]
    fn pid_ilegivel_e_pulado_sem_derrubar_o_resto() {
        let abertos = [app("nao-e-numero", "code"), app("42", "krita")];
        let fila = alvos(&abertos);
        assert_eq!(fila.len(), 1);
        assert_eq!(fila[0].pid, 42);
    }

    #[test]
    fn o_teto_de_alvos_e_respeitado() {
        // Cada alvo custa quase um segundo, e a automação inteira tem sessenta.
        let muitos: Vec<AppInfo> = (0..40).map(|i| app(&i.to_string(), "code")).collect();
        assert_eq!(alvos(&muitos).len(), MAX_ALVOS);
    }

    #[test]
    fn foca_espera_e_so_entao_manda_a_tecla() {
        // A ordem é o recurso: o Ctrl+S vai para quem tem o foco, e o foco não
        // muda no instante em que se pede.
        // Um `RefCell` porque as três ações são closures separadas e todas
        // escrevem no mesmo roteiro — que é justamente o que se quer observar.
        let roteiro = std::cell::RefCell::new(Vec::<String>::new());
        let esperas = std::cell::RefCell::new(Vec::<Duration>::new());
        let fila = [Alvo {
            pid: 7,
            nome: "code".into(),
        }];
        let desfecho = salvar(
            &fila,
            |pid| {
                roteiro.borrow_mut().push(format!("focar {pid}"));
                Ok(())
            },
            || {
                roteiro.borrow_mut().push("ctrl+s".into());
                Ok(())
            },
            |d| esperas.borrow_mut().push(d),
        );
        assert_eq!(desfecho.salvos, 1);
        assert_eq!(roteiro.into_inner(), ["focar 7", "ctrl+s"]);
        assert_eq!(esperas.into_inner(), [ESPERA_FOCO, ESPERA_SALVAR]);
    }

    #[test]
    fn foco_que_falha_nao_manda_a_tecla_para_quem_esta_na_frente() {
        // Se o foco não foi, o Ctrl+S iria para o programa que já estava na
        // frente - que pode ser justamente o navegador.
        let mut teclou = 0;
        let fila = [Alvo {
            pid: 7,
            nome: "code".into(),
        }];
        let desfecho = salvar(
            &fila,
            |_| Err("sem janela visível".into()),
            || {
                teclou += 1;
                Ok(())
            },
            |_| {},
        );
        assert_eq!(teclou, 0);
        assert_eq!(desfecho.salvos, 0);
        assert_eq!(desfecho.falhas, ["code: sem janela visível"]);
    }

    #[test]
    fn uma_falha_nao_impede_os_seguintes() {
        // Um editor minimizado que não aceita foco não pode custar o Ctrl+S dos
        // outros - é a mesma regra da automação inteira.
        let fila = [
            Alvo {
                pid: 1,
                nome: "code".into(),
            },
            Alvo {
                pid: 2,
                nome: "krita".into(),
            },
        ];
        let desfecho = salvar(
            &fila,
            |pid| {
                if pid == 1 {
                    Err("minimizado".into())
                } else {
                    Ok(())
                }
            },
            || Ok(()),
            |_| {},
        );
        assert_eq!(desfecho.salvos, 1);
        assert_eq!(desfecho.falhas.len(), 1);
    }
}
