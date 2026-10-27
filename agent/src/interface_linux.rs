//! A interface do agente no Linux: notificações e o ícone ao lado do relógio.
//!
//! No Windows e no Mac há uma janela e uma barra fixa no alto da tela. Aqui
//! não:
//!
//! - **A barra "está controlando"** não tem equivalente no GNOME com Wayland,
//!   que não deixa um programa fixar uma janela por cima de tudo. No lugar
//!   dela vai uma **notificação** do sistema, crítica (não some sozinha), com
//!   o botão Desconectar — que faz o mesmo que o da barra (ver `barra.rs`).
//!   Junto, o GNOME acende sozinho o ícone de "tela compartilhada" enquanto a
//!   sessão de tela existir.
//! - **O código de pareamento** também vai por notificação, além do arquivo e
//!   do terminal: o agente instalado sobe sem terminal nenhum.
//! - **O ícone** usa o protocolo que o Ubuntu e o KDE mostram
//!   (StatusNotifierItem). O GNOME puro (Fedora) não mostra ícone nenhum, por
//!   isso nada essencial depende dele: código e controle vão sempre por
//!   notificação.
//!
//! A janela de configurações do Windows e do Mac fica de fora: pediria um
//! bloco grande de bibliotecas gráficas sem acrescentar nada essencial.

use std::collections::HashMap;
use std::sync::Mutex;
use std::time::{Duration, Instant};

use zbus::blocking::{Connection, Proxy};
use zbus::zvariant::Value;

use crate::gui::Compartilhado;

const NOTIFICACOES: &str = "org.freedesktop.Notifications";
const CAMINHO: &str = "/org/freedesktop/Notifications";

/// Urgência das notificações (`urgency` do padrão freedesktop).
const NORMAL: u8 = 1;
/// Crítica: o GNOME a mantém na tela até alguém fechar.
const CRITICA: u8 = 2;

// --- notificações -------------------------------------------------------------

/// A conexão com o serviço de notificações, aberta uma vez.
fn notificacoes() -> Option<Proxy<'static>> {
    static PROXY: Mutex<Option<Proxy<'static>>> = Mutex::new(None);
    let mut slot = PROXY.lock().ok()?;
    if slot.is_none() {
        let conn = Connection::session().ok()?;
        *slot = Proxy::new(&conn, NOTIFICACOES, CAMINHO, NOTIFICACOES).ok();
    }
    slot.clone()
}

/// Mostra (ou substitui, com `substitui` ≠ 0) uma notificação. Devolve o id.
///
/// `acoes` são pares (chave, rótulo): viram botões.
fn notificar(
    substitui: u32,
    titulo: &str,
    corpo: &str,
    acoes: &[(&str, &str)],
    urgencia: u8,
) -> Option<u32> {
    let proxy = notificacoes()?;
    let mut lista: Vec<&str> = Vec::new();
    for (chave, rotulo) in acoes {
        lista.push(chave);
        lista.push(rotulo);
    }
    let mut dicas: HashMap<&str, Value> = HashMap::new();
    dicas.insert("urgency", Value::from(urgencia));
    // Continua na central de notificações depois de um botão ser tocado.
    dicas.insert("resident", Value::from(true));
    dicas.insert("desktop-entry", Value::from("deskside"));
    let resultado: Result<u32, _> = proxy.call(
        "Notify",
        &(
            "Deskside", substitui, "deskside", titulo, corpo, lista, dicas,
            // Nunca expira: some quando o assunto acaba (o código usado, o
            // controle encerrado), e quem fecha é o agente.
            0i32,
        ),
    );
    match resultado {
        Ok(id) => Some(id),
        Err(e) => {
            crate::diario(&format!("notificação não saiu: {e}"));
            None
        }
    }
}

fn fechar(id: u32) {
    if id == 0 {
        return;
    }
    if let Some(proxy) = notificacoes() {
        let _ = proxy.call_method("CloseNotification", &(id,));
    }
}

/// O que cada notificação aberta significa, para saber o que fazer com o
/// botão tocado.
#[derive(Default)]
struct Abertas {
    controle: u32,
    pareamento: u32,
    desinstalar: u32,
}

static ABERTAS: Mutex<Abertas> = Mutex::new(Abertas {
    controle: 0,
    pareamento: 0,
    desinstalar: 0,
});

/// Escuta os botões tocados nas notificações.
fn escutar_botoes(estado: Compartilhado) {
    let Some(proxy) = notificacoes() else { return };
    let Ok(sinais) = proxy.receive_signal("ActionInvoked") else {
        return;
    };
    let _ = std::thread::Builder::new()
        .name("deskside-notificacoes".into())
        .spawn(move || {
            for msg in sinais {
                let Ok((id, acao)) = msg.body().deserialize::<(u32, String)>() else {
                    continue;
                };
                let (controle, desinstalar) = match ABERTAS.lock() {
                    Ok(a) => (a.controle, a.desinstalar),
                    Err(_) => continue,
                };
                if id == controle && acao == "desconectar" {
                    crate::barra::desconectar(&estado);
                } else if id == desinstalar && acao == "desinstalar" {
                    desinstalar_em_segundo_plano(estado.clone());
                }
            }
        });
}

// --- controle e pareamento ----------------------------------------------------

/// Acompanha quem está controlando e mantém a notificação de acordo: aparece
/// quando alguém abre a tela, muda quando entra outro aparelho, some quando o
/// último sai.
pub fn vigiar_controle(estado: Compartilhado) {
    escutar_botoes(estado.clone());
    let _ = std::thread::Builder::new()
        .name("deskside-controle".into())
        .spawn(move || {
            let mut mostrado = String::new();
            loop {
                let atual = estado
                    .lock()
                    .map(|e| crate::barra::texto(&e.controladores))
                    .unwrap_or_default();
                if atual != mostrado {
                    let anterior = ABERTAS.lock().map(|a| a.controle).unwrap_or(0);
                    let novo = if atual.is_empty() {
                        fechar(anterior);
                        0
                    } else {
                        notificar(
                            anterior,
                            &atual,
                            "Se não foi você quem abriu, desconecte: o celular sai da \
                             conta e precisa da senha para voltar.",
                            &[("desconectar", "Desconectar")],
                            CRITICA,
                        )
                        .unwrap_or(0)
                    };
                    if let Ok(mut a) = ABERTAS.lock() {
                        a.controle = novo;
                    }
                    mostrado = atual;
                }
                std::thread::sleep(Duration::from_millis(400));
            }
        });
}

/// Mostra o código de pareamento numa notificação quando ele chega, e a fecha
/// quando ele deixa de valer.
fn avisar_codigos() {
    crate::notify::ao_receber_codigo(|| {
        let Some((codigo, expira)) = crate::notify::codigo_pendente() else {
            return;
        };
        let anterior = ABERTAS.lock().map(|a| a.pareamento).unwrap_or(0);
        let id = notificar(
            anterior,
            &format!("Código de pareamento: {codigo}"),
            &format!(
                "Digite este código no app Deskside, no celular. Expira em {} min.",
                expira / 60
            ),
            &[],
            NORMAL,
        )
        .unwrap_or(0);
        if let Ok(mut a) = ABERTAS.lock() {
            a.pareamento = id;
        }
    });
}

// --- desinstalar --------------------------------------------------------------

/// Pergunta antes de desinstalar, numa notificação com dois botões: um clique
/// por engano no menu não pode tirar o computador da conta.
fn perguntar_desinstalar() {
    let anterior = ABERTAS.lock().map(|a| a.desinstalar).unwrap_or(0);
    let id = notificar(
        anterior,
        "Desinstalar o Deskside?",
        "Este computador sai da sua conta, para de iniciar com o sistema e as \
         configurações do Deskside são apagadas. Seus arquivos não são tocados.",
        &[("desinstalar", "Desinstalar"), ("cancelar", "Agora não")],
        CRITICA,
    )
    .unwrap_or(0);
    if let Ok(mut a) = ABERTAS.lock() {
        a.desinstalar = id;
    }
}

/// Avisa o servidor e desinstala, sem esperar para sempre — o mesmo caminho
/// do Windows e do Mac (ver `gui.rs`): um botão de sair que depende de o
/// servidor responder não é uma saída.
fn desinstalar_em_segundo_plano(estado: Compartilhado) {
    std::thread::spawn(move || {
        if let Ok(mut e) = estado.lock() {
            e.desinstalar = true;
        }
        let limite = Instant::now() + Duration::from_secs(6);
        while Instant::now() < limite {
            if estado.lock().map(|e| e.desparear_ok).unwrap_or(false) {
                break;
            }
            std::thread::sleep(Duration::from_millis(200));
        }
        if let Err(e) = crate::setup::uninstall_completo() {
            crate::diario(&format!("desinstalar: {e}"));
        }
        crate::sair(0);
    });
}

// --- o ícone ------------------------------------------------------------------

struct Bandeja {
    estado: Compartilhado,
    conectado: bool,
    codigo: Option<String>,
    controlando: bool,
    /// Há versão nova que ainda não entrou (ver `atualizacao::vigiar`).
    atualizar: bool,
}

/// "Procurar atualização" (ou "Atualizar agora", quando já se sabe que há
/// versão nova), no menu: pergunta ao site na hora, e havendo versão nova,
/// instala. Sem ele, uma versão publicada logo depois da verificação só
/// entraria 6 horas depois.
fn procurar_atualizacao(estado: Compartilhado) {
    use crate::atualizacao::Situacao;
    std::thread::spawn(move || {
        let backend = estado.lock().map(|e| e.backend.clone()).unwrap_or_default();
        let falha = match crate::atualizacao::verificar(&backend) {
            Ok(Situacao::Disponivel) => crate::atualizacao::aplicar_e_sair(&estado).err(),
            Ok(Situacao::EmDia) => {
                if let Ok(mut e) = estado.lock() {
                    e.atualizacao = crate::gui::Atualizacao::Nenhuma;
                }
                notificar(
                    0,
                    "O Deskside está em dia",
                    "Este computador já tem a versão mais recente.",
                    &[],
                    NORMAL,
                );
                None
            }
            Ok(Situacao::NaoSeAplica(motivo)) => Some(motivo.to_string()),
            Err(e) => Some(e),
        };
        if let Some(e) = falha {
            notificar(0, "Não deu para atualizar o Deskside", &e, &[], NORMAL);
        }
    });
}

fn icone() -> Vec<ksni::Icon> {
    let Ok(imagem) = image::load_from_memory(include_bytes!("../assets/tray.png")) else {
        return Vec::new();
    };
    let imagem = imagem.to_rgba8();
    let (largura, altura) = imagem.dimensions();
    let mut dados = imagem.into_raw();
    // RGBA → ARGB, que é o que o protocolo pede.
    for px in dados.chunks_exact_mut(4) {
        px.rotate_right(1);
    }
    vec![ksni::Icon {
        width: largura as i32,
        height: altura as i32,
        data: dados,
    }]
}

impl ksni::Tray for Bandeja {
    fn id(&self) -> String {
        "deskside".into()
    }

    fn title(&self) -> String {
        "Deskside".into()
    }

    fn icon_pixmap(&self) -> Vec<ksni::Icon> {
        icone()
    }

    fn menu(&self) -> Vec<ksni::MenuItem<Self>> {
        use ksni::menu::{MenuItem, StandardItem};
        let mut itens: Vec<MenuItem<Self>> = vec![StandardItem {
            label: if self.conectado {
                "Deskside: conectado".into()
            } else {
                "Deskside: sem conexão".into()
            },
            enabled: false,
            ..Default::default()
        }
        .into()];
        if let Some(codigo) = &self.codigo {
            itens.push(
                StandardItem {
                    label: format!("Código de pareamento: {codigo}"),
                    enabled: false,
                    ..Default::default()
                }
                .into(),
            );
        }
        if self.controlando {
            itens.push(
                StandardItem {
                    label: "Desconectar quem está controlando".into(),
                    activate: Box::new(|b: &mut Self| crate::barra::desconectar(&b.estado)),
                    ..Default::default()
                }
                .into(),
            );
        }
        itens.push(MenuItem::Separator);
        itens.push(
            StandardItem {
                label: if self.atualizar {
                    "Atualizar agora".into()
                } else {
                    "Procurar atualização".into()
                },
                activate: Box::new(|b: &mut Self| procurar_atualizacao(b.estado.clone())),
                ..Default::default()
            }
            .into(),
        );
        itens.push(
            StandardItem {
                label: "Desinstalar o Deskside…".into(),
                activate: Box::new(|_: &mut Self| perguntar_desinstalar()),
                ..Default::default()
            }
            .into(),
        );
        itens.push(
            StandardItem {
                label: "Sair".into(),
                activate: Box::new(|_: &mut Self| crate::sair(0)),
                ..Default::default()
            }
            .into(),
        );
        itens
    }
}

/// Abrir o Deskside pelo menu com ele já rodando: a segunda cópia sai (uma
/// instância só, ver `instance.rs`) e deixa um pedido que esta atende com uma
/// notificação. Sem ela, o clique no menu não daria sinal nenhum.
fn atender_quem_abre_de_novo(estado: Compartilhado) {
    let _ = std::thread::Builder::new()
        .name("deskside-menu".into())
        .spawn(move || {
            crate::instance::escutar_pedidos_de_janela(|| {
                let conectado = estado.lock().map(|e| e.conectado).unwrap_or(false);
                let corpo = match crate::notify::codigo_pendente() {
                    Some((codigo, _)) => format!("Código de pareamento: {codigo}"),
                    None if conectado => "Conectado. Abra o app no celular.".to_string(),
                    None => "Sem conexão com o servidor; tentando de novo.".to_string(),
                };
                notificar(0, "O Deskside já está rodando", &corpo, &[], NORMAL);
            })
        });
}

/// Sobe a interface do Linux. Só volta quando alguém escolhe Sair.
pub fn rodar(estado: Compartilhado) {
    use ksni::blocking::TrayMethods;

    avisar_codigos();
    atender_quem_abre_de_novo(estado.clone());
    let bandeja = Bandeja {
        estado: estado.clone(),
        conectado: false,
        codigo: None,
        controlando: false,
        atualizar: false,
    };
    // `assume_sni_available`: no GNOME puro não há quem mostre o ícone, e
    // isso não é erro — o resto da interface (as notificações) continua.
    let alca = match bandeja.assume_sni_available(true).spawn() {
        Ok(alca) => Some(alca),
        Err(e) => {
            crate::diario(&format!("ícone ao lado do relógio indisponível: {e}"));
            None
        }
    };

    let mut ultimo = (false, None::<String>, false, false);
    loop {
        let (conectado, controlando, atualizar) = estado
            .lock()
            .map(|e| {
                (
                    e.conectado,
                    !e.controladores.is_empty(),
                    matches!(
                        e.atualizacao,
                        crate::gui::Atualizacao::Disponivel | crate::gui::Atualizacao::Falhou(_)
                    ),
                )
            })
            .unwrap_or((false, false, false));
        let codigo = crate::notify::codigo_pendente().map(|(c, _)| c);
        // Código usado (ou vencido): a notificação dele sai junto.
        if codigo.is_none() {
            let id = ABERTAS.lock().map(|a| a.pareamento).unwrap_or(0);
            if id != 0 {
                fechar(id);
                if let Ok(mut a) = ABERTAS.lock() {
                    a.pareamento = 0;
                }
            }
        }
        let agora = (conectado, codigo, controlando, atualizar);
        if agora != ultimo {
            if let Some(alca) = &alca {
                let (c, cod, ctl, atu) = agora.clone();
                alca.update(move |b: &mut Bandeja| {
                    b.conectado = c;
                    b.codigo = cod;
                    b.controlando = ctl;
                    b.atualizar = atu;
                });
            }
            ultimo = agora;
        }
        std::thread::sleep(Duration::from_secs(1));
    }
}
