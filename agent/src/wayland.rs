//! Tela, mouse e teclado no Linux com Wayland, pelo portal do sistema.
//!
//! O Wayland não deixa um programa capturar a tela nem mexer no mouse por conta
//! própria. O caminho oficial é o portal (`xdg-desktop-portal`): o programa
//! pede, o sistema mostra uma janela de "compartilhar tela e controle", e a
//! pessoa aprova. O teste feito antes de escrever isto
//! (`scripts/spike-wayland.py`, no Ubuntu 26.04 com GNOME 50) mostrou o que
//! torna o agente possível: pedindo para **lembrar**, o sistema devolve uma
//! ficha (`restore_token`), e com ela as próximas sessões abrem em 0,1 s, sem
//! janela — inclusive depois de sair e entrar de novo na sessão.
//!
//! ## A ficha muda a cada uso
//!
//! Cada sessão aberta com a ficha devolve uma **nova**, e a velha deixa de
//! valer. Por isso ela é regravada toda vez, em `~/.config/deskside`, legível só
//! pelo dono: com ela, qualquer programa daquela conta abriria a tela sem
//! perguntar.
//!
//! ## A sessão só existe enquanto alguém vê a tela
//!
//! Com a sessão aberta, o GNOME mostra um ícone de "tela compartilhada" no
//! alto. Aberta o tempo todo, o ícone ficaria aceso sempre e ninguém mais
//! prestaria atenção nele; abrindo só durante o uso, ele é o aviso de que
//! alguém está vendo. A sessão nasce com a captura (`Captura`) e morre com ela.
//!
//! ## Quando a ficha não serve
//!
//! O sistema volta a mostrar a janela — e num computador sem ninguém na frente
//! ninguém vai clicar. O agente espera um pouco, avisa o celular ("libere o
//! acesso na tela do computador") e desiste em dois minutos, em vez de ficar
//! preso.
//!
//! ## A área de transferência vai junto
//!
//! No Wayland só a janela em foco lê e escreve a área de transferência, e o
//! agente não tem janela. O portal resolve dentro da mesma sessão: ela é pedida
//! antes de começar (`RequestClipboard`) e vale enquanto a sessão existir — que
//! é quando o celular está com a tela aberta, o único lugar do app que copia e
//! cola. Testado com `scripts/spike-clipboard.py`, nos dois sentidos.

use std::collections::HashMap;
use std::os::fd::OwnedFd;
use std::path::PathBuf;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::mpsc::{Receiver, RecvTimeoutError};
use std::sync::{Arc, Mutex};
use std::time::Duration;

use zbus::blocking::{Connection, Proxy};
use zbus::zvariant::{DeserializeDict, OwnedObjectPath, Type, Value};

const PORTAL: &str = "org.freedesktop.portal.Desktop";
const CAMINHO: &str = "/org/freedesktop/portal/desktop";
const REMOTO: &str = "org.freedesktop.portal.RemoteDesktop";
const TELA: &str = "org.freedesktop.portal.ScreenCast";
const AREA: &str = "org.freedesktop.portal.Clipboard";

const TECLADO: u32 = 1;
const PONTEIRO: u32 = 2;
const MONITOR: u32 = 1;
const LEMBRAR_ATE_REVOGAR: u32 = 2;
const CURSOR_NA_IMAGEM: u32 = 2;

/// Depois de quanto tempo esperando a resposta do sistema o celular é avisado.
/// Com a ficha valendo, a resposta vem em 0,1 s; mais que isto é a janela de
/// permissão esperando alguém.
const AVISAR_DEPOIS: Duration = Duration::from_secs(3);
/// Quanto esperar alguém aprovar antes de desistir.
const DESISTIR_DEPOIS: Duration = Duration::from_secs(120);

/// O texto que vai ao celular quando o sistema está pedindo permissão.
pub const PEDINDO_PERMISSAO: &str = "O computador está pedindo permissão para compartilhar a \
     tela. Alguém precisa aprovar na tela dele (uma vez só: depois ele lembra).";

/// Esta sessão gráfica é Wayland?
pub fn ativo() -> bool {
    std::env::var("XDG_SESSION_TYPE").is_ok_and(|t| t == "wayland")
        || std::env::var_os("WAYLAND_DISPLAY").is_some()
}

// --- a ficha ------------------------------------------------------------------

fn caminho_da_ficha() -> PathBuf {
    crate::config_dir().join("wayland-ficha")
}

fn ler_ficha() -> Option<String> {
    let texto = std::fs::read_to_string(caminho_da_ficha()).ok()?;
    let texto = texto.trim();
    (!texto.is_empty()).then(|| texto.to_string())
}

fn gravar_ficha(ficha: &str) {
    use std::io::Write;
    use std::os::unix::fs::OpenOptionsExt;
    let caminho = caminho_da_ficha();
    if let Some(pasta) = caminho.parent() {
        let _ = std::fs::create_dir_all(pasta);
    }
    // 0600 já na criação: gravar e restringir depois deixaria um instante em
    // que outro usuário da máquina poderia ler.
    let resultado = std::fs::OpenOptions::new()
        .write(true)
        .create(true)
        .truncate(true)
        .mode(0o600)
        .open(&caminho)
        .and_then(|mut f| f.write_all(ficha.as_bytes()));
    if let Err(e) = resultado {
        crate::diario(&format!("Wayland: não consegui guardar a ficha: {e}"));
    }
}

// --- o portal -----------------------------------------------------------------

#[derive(DeserializeDict, Type, Debug)]
#[zvariant(signature = "dict")]
struct RespostaDaSessao {
    session_handle: String,
}

#[derive(DeserializeDict, Type, Debug, Default)]
#[zvariant(signature = "dict")]
struct PropriedadesDaTela {
    size: Option<(i32, i32)>,
}

#[derive(DeserializeDict, Type, Debug)]
#[zvariant(signature = "dict")]
struct RespostaDoInicio {
    streams: Option<Vec<(u32, PropriedadesDaTela)>>,
    restore_token: Option<String>,
    devices: Option<u32>,
    clipboard_enabled: Option<bool>,
}

#[derive(DeserializeDict, Type, Debug)]
#[zvariant(signature = "dict")]
struct RespostaVazia {}

fn texto_do_erro(e: impl std::fmt::Display) -> String {
    format!("portal: {e}")
}

/// Um pedido ao portal: a chamada volta na hora com o caminho de um "pedido",
/// e o resultado chega depois num sinal `Response` nesse caminho — às vezes só
/// depois de alguém clicar numa janela.
///
/// A inscrição no sinal é feita **antes** da chamada: feita depois, uma
/// resposta rápida (a da ficha, em 0,1 s) poderia chegar antes de haver quem
/// a ouvisse.
struct Pedido<T> {
    resposta: Receiver<Result<T, String>>,
}

impl<T> Pedido<T>
where
    T: for<'de> serde::Deserialize<'de> + Type + Send + 'static,
{
    fn preparar(conn: &Connection, token: &str) -> Result<Self, String> {
        let remetente = conn
            .unique_name()
            .ok_or("portal: sem nome no barramento")?
            .trim_start_matches(':')
            .replace('.', "_");
        let caminho = format!("{CAMINHO}/request/{remetente}/{token}");
        let pedido = Proxy::new(conn, PORTAL, caminho, "org.freedesktop.portal.Request")
            .map_err(texto_do_erro)?;
        let mut sinais = pedido.receive_signal("Response").map_err(texto_do_erro)?;
        let (tx, rx) = std::sync::mpsc::channel();
        // Numa thread porque a espera bloqueia, e quem chamou precisa poder
        // desistir (e avisar o celular) enquanto isso.
        std::thread::spawn(move || {
            let _manter = &pedido;
            let resultado = match sinais.next() {
                None => Err("portal: o pedido terminou sem resposta".to_string()),
                Some(msg) => match msg.body().deserialize::<(u32, T)>() {
                    Ok((0, corpo)) => Ok(corpo),
                    Ok((1, _)) => Err("o acesso foi recusado na tela do computador".to_string()),
                    Ok((codigo, _)) => Err(format!("o pedido terminou (código {codigo})")),
                    Err(e) => Err(texto_do_erro(e)),
                },
            };
            let _ = tx.send(resultado);
        });
        Ok(Self { resposta: rx })
    }

    fn esperar(self, prazo: Duration) -> Result<T, String> {
        match self.resposta.recv_timeout(prazo) {
            Ok(r) => r,
            Err(_) => Err("o portal não respondeu".to_string()),
        }
    }
}

fn opcoes(token: &str) -> HashMap<&'static str, Value<'static>> {
    let mut o = HashMap::new();
    o.insert("handle_token", Value::from(token.to_string()));
    o
}

fn novo_token() -> String {
    format!("deskside{}", rand::random::<u32>())
}

/// Uma sessão de controle aberta: a tela que o PipeWire entrega e o canal por
/// onde vão mouse e teclado.
pub struct Sessao {
    conn: Connection,
    remoto: Proxy<'static>,
    caminho: OwnedObjectPath,
    /// A área de transferência, quando o sistema a liberou nesta sessão.
    area: Option<Proxy<'static>>,
    /// O nó do PipeWire com a imagem.
    pub no: u32,
    /// Tamanho lógico da tela: é nesta régua que vão as posições do mouse.
    pub largura: u32,
    pub altura: u32,
}

/// Quem pode cancelar uma abertura em andamento — a captura que desistiu
/// (ninguém mais quer a tela) enquanto a janela de permissão ainda espera.
#[derive(Default)]
pub struct Cancelamento {
    cancelado: AtomicBool,
    sessao: Mutex<Option<(Connection, OwnedObjectPath)>>,
}

impl Cancelamento {
    pub fn cancelar(&self) {
        self.cancelado.store(true, Ordering::SeqCst);
        if let Ok(mut s) = self.sessao.lock() {
            if let Some((conn, caminho)) = s.take() {
                fechar_sessao(&conn, &caminho);
            }
        }
    }

    fn cancelado(&self) -> bool {
        self.cancelado.load(Ordering::SeqCst)
    }
}

fn fechar_sessao(conn: &Connection, caminho: &OwnedObjectPath) {
    if let Ok(sessao) = Proxy::new(
        conn,
        PORTAL,
        caminho.clone(),
        "org.freedesktop.portal.Session",
    ) {
        let _ = sessao.call_method("Close", &());
    }
}

impl Sessao {
    /// Abre uma sessão de tela e controle, usando a ficha guardada se houver.
    ///
    /// Bloqueia até o sistema responder — na primeira vez, até alguém aprovar
    /// a janela. Por isso roda numa thread própria, nunca no laço de rede.
    pub fn abrir(cancelamento: &Cancelamento) -> Result<(Sessao, OwnedFd), String> {
        let conn = Connection::session().map_err(texto_do_erro)?;
        let remoto = Proxy::new(&conn, PORTAL, CAMINHO, REMOTO).map_err(texto_do_erro)?;
        let tela = Proxy::new(&conn, PORTAL, CAMINHO, TELA).map_err(texto_do_erro)?;

        // 1. A sessão.
        let token = novo_token();
        let pedido = Pedido::<RespostaDaSessao>::preparar(&conn, &token)?;
        let mut o = opcoes(&token);
        o.insert("session_handle_token", Value::from(novo_token()));
        remoto
            .call_method("CreateSession", &(o,))
            .map_err(texto_do_erro)?;
        let caminho =
            OwnedObjectPath::try_from(pedido.esperar(Duration::from_secs(10))?.session_handle)
                .map_err(texto_do_erro)?;
        if let Ok(mut s) = cancelamento.sessao.lock() {
            *s = Some((conn.clone(), caminho.clone()));
        }
        // A partir daqui, qualquer falha fecha a sessão: deixá-la aberta
        // manteria o ícone de compartilhamento aceso por nada.
        let resultado = Self::preparar(&conn, &remoto, &tela, &caminho, cancelamento);
        if let Ok(mut s) = cancelamento.sessao.lock() {
            s.take();
        }
        match resultado {
            Ok((no, largura, altura, fd, area_liberada)) => {
                let area = if area_liberada {
                    escutar_area(&conn, &caminho)
                } else {
                    None
                };
                Ok((
                    Sessao {
                        conn,
                        remoto,
                        caminho,
                        area,
                        no,
                        largura,
                        altura,
                    },
                    fd,
                ))
            }
            Err(e) => {
                fechar_sessao(&conn, &caminho);
                Err(e)
            }
        }
    }

    fn preparar(
        conn: &Connection,
        remoto: &Proxy<'static>,
        tela: &Proxy<'static>,
        caminho: &OwnedObjectPath,
        cancelamento: &Cancelamento,
    ) -> Result<(u32, u32, u32, OwnedFd, bool), String> {
        // 2. Mouse e teclado, pedindo para lembrar — e apresentando a ficha.
        let token = novo_token();
        let pedido = Pedido::<RespostaVazia>::preparar(conn, &token)?;
        let mut o = opcoes(&token);
        o.insert("types", Value::from(TECLADO | PONTEIRO));
        o.insert("persist_mode", Value::from(LEMBRAR_ATE_REVOGAR));
        if let Some(ficha) = ler_ficha() {
            o.insert("restore_token", Value::from(ficha));
        }
        remoto
            .call_method("SelectDevices", &(caminho, o))
            .map_err(texto_do_erro)?;
        pedido.esperar(Duration::from_secs(10))?;

        // 3. A tela, com o cursor desenhado na imagem.
        let token = novo_token();
        let pedido = Pedido::<RespostaVazia>::preparar(conn, &token)?;
        let mut o = opcoes(&token);
        o.insert("types", Value::from(MONITOR));
        o.insert("multiple", Value::from(false));
        o.insert("cursor_mode", Value::from(CURSOR_NA_IMAGEM));
        tela.call_method("SelectSources", &(caminho, o))
            .map_err(texto_do_erro)?;
        pedido.esperar(Duration::from_secs(10))?;

        // A área de transferência: tem de ser pedida antes de começar. Num
        // sistema sem esse pedaço do portal, a tela e o controle seguem sem
        // ela.
        let pediu_area = Proxy::new(conn, PORTAL, CAMINHO, AREA)
            .and_then(|area| {
                area.call_method(
                    "RequestClipboard",
                    &(caminho, HashMap::<&str, Value>::new()),
                )
            })
            .map_err(|e| crate::diario(&format!("Wayland: sem área de transferência ({e})")))
            .is_ok();

        // 4. Começar. Com a ficha valendo, a resposta vem na hora; sem ela, o
        //    sistema mostra a janela e a resposta espera alguém.
        let token = novo_token();
        let pedido = Pedido::<RespostaDoInicio>::preparar(conn, &token)?;
        remoto
            .call_method("Start", &(caminho, "", opcoes(&token)))
            .map_err(texto_do_erro)?;
        let inicio = std::time::Instant::now();
        let mut avisado = false;
        let resposta = loop {
            match pedido.resposta.recv_timeout(Duration::from_millis(250)) {
                Ok(r) => break r?,
                Err(RecvTimeoutError::Disconnected) => {
                    return Err("o portal parou de responder".to_string())
                }
                Err(RecvTimeoutError::Timeout) => {}
            }
            if cancelamento.cancelado() {
                return Err("ninguém mais quer a tela".to_string());
            }
            if !avisado && inicio.elapsed() >= AVISAR_DEPOIS {
                avisado = true;
                crate::diario("Wayland: esperando alguém aprovar o acesso na tela");
                crate::aviso::avisar(PEDINDO_PERMISSAO);
            }
            if inicio.elapsed() >= DESISTIR_DEPOIS {
                return Err("ninguém aprovou o acesso na tela do computador".to_string());
            }
        };

        // A ficha nova substitui a velha, que deixou de valer.
        match &resposta.restore_token {
            Some(ficha) if !ficha.is_empty() => gravar_ficha(ficha),
            _ => crate::diario(
                "Wayland: o sistema não devolveu ficha; vai pedir permissão de novo na próxima vez",
            ),
        }
        if resposta.devices.unwrap_or(0) & PONTEIRO == 0 {
            crate::diario("Wayland: o mouse não foi liberado; só a tela vai funcionar");
        }
        let (no, propriedades) = resposta
            .streams
            .and_then(|s| s.into_iter().next())
            .ok_or("o sistema não entregou nenhuma tela")?;
        let (largura, altura) = propriedades.size.unwrap_or((1920, 1080));

        let fd: zbus::zvariant::OwnedFd = tela
            .call(
                "OpenPipeWireRemote",
                &(caminho, HashMap::<&str, Value>::new()),
            )
            .map_err(texto_do_erro)?;
        let area_liberada = pediu_area && resposta.clipboard_enabled.unwrap_or(false);
        if pediu_area && !area_liberada {
            crate::diario("Wayland: o sistema não liberou a área de transferência");
        }
        Ok((
            no,
            largura.max(1) as u32,
            altura.max(1) as u32,
            fd.into(),
            area_liberada,
        ))
    }

    fn notificar<B>(&self, metodo: &str, corpo: &B)
    where
        B: serde::Serialize + Type,
    {
        // Sem esperar resposta: são dezenas por segundo, e a ordem já é
        // garantida pela conexão.
        if let Err(e) = self.remoto.call_noreply(metodo, corpo) {
            crate::diario(&format!("Wayland: {metodo} falhou: {e}"));
        }
    }

    fn vazio() -> HashMap<&'static str, Value<'static>> {
        HashMap::new()
    }

    /// Leva o cursor a uma posição da tela, em pixels lógicos.
    pub fn mover_para(&self, x: f64, y: f64) {
        self.notificar(
            "NotifyPointerMotionAbsolute",
            &(&self.caminho, Self::vazio(), self.no, x, y),
        );
    }

    pub fn mover(&self, dx: f64, dy: f64) {
        self.notificar(
            "NotifyPointerMotion",
            &(&self.caminho, Self::vazio(), dx, dy),
        );
    }

    /// `codigo` é o do evdev (`BTN_LEFT` = 0x110).
    pub fn botao(&self, codigo: i32, apertado: bool) {
        self.notificar(
            "NotifyPointerButton",
            &(&self.caminho, Self::vazio(), codigo, apertado as u32),
        );
    }

    /// Passos de rolagem vertical; positivo desce.
    pub fn rolar(&self, passos: i32) {
        self.notificar(
            "NotifyPointerAxisDiscrete",
            &(&self.caminho, Self::vazio(), 0u32, passos),
        );
    }

    /// Uma tecla pelo símbolo (keysym do X), e não pela posição: assim um "ç"
    /// sai "ç" seja qual for o layout do teclado do computador.
    pub fn tecla(&self, simbolo: i32, apertada: bool) {
        self.notificar(
            "NotifyKeyboardKeysym",
            &(&self.caminho, Self::vazio(), simbolo, apertada as u32),
        );
    }
}

impl Drop for Sessao {
    fn drop(&mut self) {
        fechar_sessao(&self.conn, &self.caminho);
        if self.area.is_some() {
            esquecer_area();
        }
        // Fecha a conexão, que é só desta sessão: é o que termina a thread que
        // escuta a área de transferência.
        let _ = self.conn.clone().close();
    }
}

// --- a sessão em uso ----------------------------------------------------------

/// A sessão aberta agora, para o injetor mandar mouse e teclado por ela.
///
/// Uma global porque são dois donos que não se conhecem: quem abre é a
/// captura (a sessão vive enquanto alguém vê a tela), quem usa é o injetor,
/// criado pelo laço de rede.
static ATUAL: Mutex<Option<Arc<Sessao>>> = Mutex::new(None);

/// A sessão em uso, se houver.
pub fn atual() -> Option<Arc<Sessao>> {
    ATUAL.lock().ok()?.clone()
}

/// O tamanho da última tela liberada, para a lista de monitores do app.
static ULTIMO_TAMANHO: Mutex<Option<(u32, u32)>> = Mutex::new(None);

pub fn ultimo_tamanho() -> Option<(u32, u32)> {
    *ULTIMO_TAMANHO.lock().ok()?
}

// --- a área de transferência ---------------------------------------------------

/// Os tipos de texto, do preferido ao último recurso (os três últimos são os
/// nomes antigos do X11, que programas rodando pelo XWayland ainda usam).
pub const TIPOS_DE_TEXTO: [&str; 5] = [
    "text/plain;charset=utf-8",
    "text/plain",
    "UTF8_STRING",
    "STRING",
    "TEXT",
];

/// Quanto esperar o programa dono da cópia entregar os dados.
const PRAZO_DA_COPIA: Duration = Duration::from_millis(1500);

/// O que o agente pôs na área de transferência do computador, a pedido do
/// celular. Fica guardado porque no Wayland quem copia **serve** os dados a
/// cada vez que alguém cola.
#[derive(Clone, Debug, PartialEq)]
pub enum Conteudo {
    Texto(String),
    Png(Vec<u8>),
}

impl Conteudo {
    pub fn tipos(&self) -> Vec<&'static str> {
        match self {
            Conteudo::Texto(_) => TIPOS_DE_TEXTO.to_vec(),
            Conteudo::Png(_) => vec!["image/png"],
        }
    }

    pub fn dados(&self, tipo: &str) -> Option<&[u8]> {
        match self {
            Conteudo::Texto(t) if TIPOS_DE_TEXTO.contains(&tipo) => Some(t.as_bytes()),
            Conteudo::Png(p) if tipo == "image/png" => Some(p),
            _ => None,
        }
    }
}

struct Area {
    /// Liberada numa sessão aberta agora.
    liberada: bool,
    /// Os tipos que o programa dono da cópia oferece (quando não é o agente).
    tipos: Vec<String>,
    /// O texto copiado no computador, lido assim que a cópia acontece.
    texto: Option<String>,
    /// Quantas cópias o computador fez — as do agente não contam. Só cresce,
    /// de sessão em sessão: é por ele que se percebe a novidade.
    copias: u64,
    nosso: Option<Conteudo>,
}

static ESTADO_DA_AREA: Mutex<Area> = Mutex::new(Area {
    liberada: false,
    tipos: Vec::new(),
    texto: None,
    copias: 0,
    nosso: None,
});

fn esquecer_area() {
    if let Ok(mut a) = ESTADO_DA_AREA.lock() {
        a.liberada = false;
        a.tipos.clear();
        a.texto = None;
        a.nosso = None;
    }
}

/// O primeiro tipo de texto que a cópia oferece, na ordem de preferência.
pub fn tipo_de_texto(tipos: &[String]) -> Option<&'static str> {
    TIPOS_DE_TEXTO
        .iter()
        .find(|t| tipos.iter().any(|o| o == *t))
        .copied()
}

/// Lê tudo de um descritor que o portal entrega **sem bloqueio**: um `read`
/// antes de o programa dono escrever dá "tente de novo", e não "acabou". (Foi
/// o que derrubou a primeira versão do teste.)
fn ler_descritor(fd: OwnedFd, limite: usize) -> Result<Vec<u8>, String> {
    use std::io::Read;
    let mut arquivo = std::fs::File::from(fd);
    let prazo = std::time::Instant::now() + PRAZO_DA_COPIA;
    let mut dados = Vec::new();
    let mut bloco = vec![0u8; 64 * 1024];
    loop {
        match arquivo.read(&mut bloco) {
            Ok(0) => return Ok(dados),
            Ok(n) => {
                dados.extend_from_slice(&bloco[..n]);
                if dados.len() >= limite {
                    dados.truncate(limite);
                    return Ok(dados);
                }
            }
            Err(e) if e.kind() == std::io::ErrorKind::Interrupted => {}
            Err(e) if e.kind() == std::io::ErrorKind::WouldBlock => {
                if std::time::Instant::now() >= prazo {
                    return Err("o programa que copiou não entregou o conteúdo".to_string());
                }
                std::thread::sleep(Duration::from_millis(5));
            }
            Err(e) => return Err(e.to_string()),
        }
    }
}

/// O mesmo cuidado na escrita: uma imagem não cabe de uma vez num descritor
/// sem bloqueio.
fn escrever_descritor(fd: OwnedFd, dados: &[u8]) -> Result<(), String> {
    use std::io::Write;
    let mut arquivo = std::fs::File::from(fd);
    let prazo = std::time::Instant::now() + PRAZO_DA_COPIA;
    let mut resto = dados;
    while !resto.is_empty() {
        match arquivo.write(resto) {
            Ok(0) => return Err("o computador parou de receber".to_string()),
            Ok(n) => resto = &resto[n..],
            Err(e) if e.kind() == std::io::ErrorKind::Interrupted => {}
            Err(e) if e.kind() == std::io::ErrorKind::WouldBlock => {
                if std::time::Instant::now() >= prazo {
                    return Err("o programa que colou não leu a tempo".to_string());
                }
                std::thread::sleep(Duration::from_millis(5));
            }
            Err(e) => return Err(e.to_string()),
        }
    }
    Ok(())
}

fn ler_do_portal(
    area: &Proxy<'_>,
    sessao: &OwnedObjectPath,
    tipo: &str,
    limite: usize,
) -> Result<Vec<u8>, String> {
    let fd: zbus::zvariant::OwnedFd = area
        .call("SelectionRead", &(sessao, tipo))
        .map_err(texto_do_erro)?;
    ler_descritor(fd.into(), limite)
}

/// Texto lido até este teto; o que vai ao celular ainda passa pelo corte de
/// `clipboard::limited`, bem menor.
const TETO_DO_TEXTO: usize = 256 * 1024;

/// Começa a acompanhar a área de transferência de uma sessão recém-aberta.
///
/// Uma thread escuta os dois avisos do portal: alguém copiou no computador
/// (lê o texto na hora, para o aviso automático ao celular) e alguém colou o
/// que o agente pôs ali (entrega os dados). Ela termina quando a conexão da
/// sessão fecha (ver o `Drop` de `Sessao`).
fn escutar_area(conn: &Connection, sessao: &OwnedObjectPath) -> Option<Proxy<'static>> {
    let area = Proxy::new(conn, PORTAL, CAMINHO, AREA).ok()?;
    let regra = zbus::MatchRule::builder()
        .msg_type(zbus::message::Type::Signal)
        .interface(AREA)
        .ok()?
        .build();
    let sinais = match zbus::blocking::MessageIterator::for_match_rule(regra, conn, None) {
        Ok(s) => s,
        Err(e) => {
            crate::diario(&format!("Wayland: não deu para ouvir a área de transferência: {e}"));
            return None;
        }
    };
    if let Ok(mut a) = ESTADO_DA_AREA.lock() {
        a.liberada = true;
        a.tipos.clear();
        a.texto = None;
        a.nosso = None;
    }
    let (proxy, minha) = (area.clone(), sessao.clone());
    let _ = std::thread::Builder::new()
        .name("deskside-area".into())
        .spawn(move || {
            for msg in sinais {
                let Ok(msg) = msg else { break };
                let membro = msg.header().member().map(|m| m.to_string());
                match membro.as_deref() {
                    Some("SelectionOwnerChanged") => {
                        type Corpo = (OwnedObjectPath, HashMap<String, zbus::zvariant::OwnedValue>);
                        if let Ok((de, opcoes)) = msg.body().deserialize::<Corpo>() {
                            if de == minha {
                                copiaram(&proxy, &minha, &opcoes);
                            }
                        }
                    }
                    Some("SelectionTransfer") => {
                        if let Ok((de, tipo, serie)) =
                            msg.body().deserialize::<(OwnedObjectPath, String, u32)>()
                        {
                            if de == minha {
                                colaram(&proxy, &minha, &tipo, serie);
                            }
                        }
                    }
                    _ => {}
                }
            }
        });
    Some(area)
}

fn copiaram(
    area: &Proxy<'_>,
    sessao: &OwnedObjectPath,
    opcoes: &HashMap<String, zbus::zvariant::OwnedValue>,
) {
    let do_agente = opcoes
        .get("session_is_owner")
        .and_then(|v| bool::try_from(v).ok())
        .unwrap_or(false);
    if do_agente {
        return;
    }
    let tipos: Vec<String> = opcoes
        .get("mime_types")
        .and_then(|v| v.try_clone().ok())
        .and_then(|v| Vec::<String>::try_from(v).ok())
        .unwrap_or_default();
    // Lê antes de contar a cópia: contada antes, quem perguntasse no meio
    // veria "cópia nova" sem texto, e não perguntaria de novo.
    let texto = tipo_de_texto(&tipos).and_then(|tipo| {
        ler_do_portal(area, sessao, tipo, TETO_DO_TEXTO)
            .map_err(|e| crate::diario(&format!("Wayland: cópia não lida: {e}")))
            .ok()
            .map(|b| String::from_utf8_lossy(&b).into_owned())
    });
    if let Ok(mut a) = ESTADO_DA_AREA.lock() {
        a.tipos = tipos;
        a.texto = texto;
        a.nosso = None;
        a.copias += 1;
    }
}

fn colaram(area: &Proxy<'_>, sessao: &OwnedObjectPath, tipo: &str, serie: u32) {
    let dados = ESTADO_DA_AREA
        .lock()
        .ok()
        .and_then(|a| a.nosso.as_ref().and_then(|c| c.dados(tipo)).map(<[u8]>::to_vec));
    let entregue = match dados {
        None => false,
        Some(dados) => area
            .call::<_, _, zbus::zvariant::OwnedFd>("SelectionWrite", &(sessao, serie))
            .map_err(texto_do_erro)
            .and_then(|fd| escrever_descritor(fd.into(), &dados))
            .map_err(|e| crate::diario(&format!("Wayland: colar falhou: {e}")))
            .is_ok(),
    };
    let _ = area.call_method("SelectionWriteDone", &(sessao, serie, entregue));
}

/// Por que a área de transferência não está disponível agora, ou `None` se
/// está.
pub fn area_indisponivel() -> Option<&'static str> {
    if ESTADO_DA_AREA.lock().is_ok_and(|a| a.liberada) {
        return None;
    }
    Some(if atual().is_some() {
        "este Linux não liberou a área de transferência para o Deskside"
    } else {
        "no Linux, a área de transferência só funciona com a tela do computador aberta no app"
    })
}

fn area_atual() -> Option<(Proxy<'static>, OwnedObjectPath)> {
    let sessao = atual()?;
    Some((sessao.area.clone()?, sessao.caminho.clone()))
}

/// Quantas cópias o computador já fez (ver `Area::copias`).
pub fn area_copias() -> u64 {
    ESTADO_DA_AREA.lock().map(|a| a.copias).unwrap_or(0)
}

/// O texto na área de transferência agora.
pub fn area_texto() -> Option<String> {
    let (nosso, texto, viu_copia) = {
        let a = ESTADO_DA_AREA.lock().ok()?;
        if !a.liberada {
            return None;
        }
        (a.nosso.clone(), a.texto.clone(), a.copias > 0)
    };
    match nosso {
        Some(Conteudo::Texto(t)) => return Some(t),
        Some(Conteudo::Png(_)) => return None,
        None => {}
    }
    if texto.is_some() || viu_copia {
        return texto;
    }
    // Nenhuma cópia desde que a sessão abriu: o que estava copiado antes não
    // gerou aviso, então pergunta direto.
    let (area, sessao) = area_atual()?;
    TIPOS_DE_TEXTO[..2].iter().find_map(|tipo| {
        ler_do_portal(&area, &sessao, tipo, TETO_DO_TEXTO)
            .ok()
            .filter(|b| !b.is_empty())
            .map(|b| String::from_utf8_lossy(&b).into_owned())
    })
}

/// Os tipos do que está copiado agora.
pub fn area_tipos() -> Vec<String> {
    ESTADO_DA_AREA
        .lock()
        .map(|a| match &a.nosso {
            Some(c) => c.tipos().into_iter().map(str::to_string).collect(),
            None => a.tipos.clone(),
        })
        .unwrap_or_default()
}

/// Lê um tipo do que está copiado (imagem, lista de arquivos).
pub fn area_ler(tipo: &str, limite: usize) -> Result<Vec<u8>, String> {
    if let Some(dados) = ESTADO_DA_AREA.lock().ok().and_then(|a| {
        a.nosso.as_ref().and_then(|c| c.dados(tipo)).map(<[u8]>::to_vec)
    }) {
        return Ok(dados);
    }
    let (area, sessao) =
        area_atual().ok_or_else(|| area_indisponivel().unwrap_or("sem sessão").to_string())?;
    ler_do_portal(&area, &sessao, tipo, limite)
}

/// Põe algo na área de transferência do computador. Os dados ficam com o
/// agente e saem a cada Ctrl+V (ver `colaram`).
pub fn area_por(conteudo: Conteudo) -> Result<(), String> {
    if let Some(motivo) = area_indisponivel() {
        return Err(motivo.to_string());
    }
    let (area, sessao) = area_atual().ok_or("a sessão da tela acabou de fechar")?;
    let tipos = conteudo.tipos();
    if let Ok(mut a) = ESTADO_DA_AREA.lock() {
        a.nosso = Some(conteudo);
    }
    let mut opcoes = HashMap::new();
    opcoes.insert("mime_types", Value::from(tipos));
    area.call_method("SetSelection", &(&sessao, opcoes))
        .map(|_| ())
        .map_err(texto_do_erro)
}

// --- os quadros ---------------------------------------------------------------

/// Os formatos de pixel que se aceita do PipeWire.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Formato {
    Rgbx,
    Rgba,
    Bgrx,
    Bgra,
    Rgb,
    Bgr,
}

impl Formato {
    fn bytes_por_pixel(self) -> usize {
        match self {
            Formato::Rgb | Formato::Bgr => 3,
            _ => 4,
        }
    }
}

/// Converte um quadro do PipeWire em RGBA compacto.
///
/// O `stride` (bytes por linha) importa: o compositor pode alinhar cada linha
/// com bytes a mais no fim, e ler a imagem como se fosse contínua a entortaria
/// em diagonal. `None` quando os dados não cobrem o tamanho anunciado.
pub fn para_rgba(
    dados: &[u8],
    formato: Formato,
    largura: usize,
    altura: usize,
    stride: usize,
) -> Option<Vec<u8>> {
    let bpp = formato.bytes_por_pixel();
    let stride = if stride == 0 { largura * bpp } else { stride };
    if stride < largura * bpp || dados.len() < stride * (altura.saturating_sub(1)) + largura * bpp {
        return None;
    }
    let mut saida = Vec::with_capacity(largura * altura * 4);
    for y in 0..altura {
        let linha = &dados[y * stride..y * stride + largura * bpp];
        for px in linha.chunks_exact(bpp) {
            let (r, g, b) = match formato {
                Formato::Rgbx | Formato::Rgba | Formato::Rgb => (px[0], px[1], px[2]),
                Formato::Bgrx | Formato::Bgra | Formato::Bgr => (px[2], px[1], px[0]),
            };
            saida.extend_from_slice(&[r, g, b, 255]);
        }
    }
    Some(saida)
}

/// Um quadro recebido, já em RGBA.
pub struct Quadro {
    pub rgba: Vec<u8>,
    pub largura: u32,
    pub altura: u32,
}

/// Recebe os quadros de uma tela do PipeWire, numa thread própria.
struct Quadros {
    parar: Arc<AtomicBool>,
    thread: Option<std::thread::JoinHandle<()>>,
}

impl Quadros {
    fn iniciar(fd: OwnedFd, no: u32, saida: std::sync::mpsc::SyncSender<Quadro>) -> Self {
        let parar = Arc::new(AtomicBool::new(false));
        let sinal = Arc::clone(&parar);
        let thread = std::thread::Builder::new()
            .name("deskside-pipewire".into())
            .spawn(move || {
                if let Err(e) = receber(fd, no, saida, sinal) {
                    crate::diario(&format!("Wayland: PipeWire: {e}"));
                }
            })
            .ok();
        Self { parar, thread }
    }
}

impl Drop for Quadros {
    fn drop(&mut self) {
        self.parar.store(true, Ordering::SeqCst);
        if let Some(t) = self.thread.take() {
            let _ = t.join();
        }
    }
}

fn receber(
    fd: OwnedFd,
    no: u32,
    saida: std::sync::mpsc::SyncSender<Quadro>,
    parar: Arc<AtomicBool>,
) -> Result<(), String> {
    use pipewire as pw;
    use pw::spa;
    use pw::spa::param::format::{FormatProperties, MediaSubtype, MediaType};
    use pw::spa::param::video::{VideoFormat, VideoInfoRaw};
    use pw::spa::param::ParamType;
    use pw::spa::pod::{self, Pod};

    pw::init();
    let laco = pw::main_loop::MainLoopRc::new(None).map_err(|e| e.to_string())?;
    let contexto = pw::context::ContextRc::new(&laco, None).map_err(|e| e.to_string())?;
    let nucleo = contexto
        .connect_fd_rc(fd, None)
        .map_err(|e| e.to_string())?;
    let fluxo = pw::stream::StreamRc::new(
        nucleo,
        "Deskside",
        pw::properties::properties! {
            *pw::keys::MEDIA_TYPE => "Video",
            *pw::keys::MEDIA_CATEGORY => "Capture",
            *pw::keys::MEDIA_ROLE => "Screen",
        },
    )
    .map_err(|e| e.to_string())?;

    let _ouvinte = fluxo
        .add_local_listener_with_user_data(VideoInfoRaw::default())
        .param_changed(|_, formato, id, param| {
            let Some(param) = param else { return };
            if id != ParamType::Format.as_raw() {
                return;
            }
            if let Ok((MediaType::Video, MediaSubtype::Raw)) =
                pw::spa::param::format_utils::parse_format(param)
            {
                let _ = formato.parse(param);
            }
        })
        .process(move |fluxo, formato| {
            let Some(mut buffer) = fluxo.dequeue_buffer() else {
                return;
            };
            let datas = buffer.datas_mut();
            let Some(dado) = datas.first_mut() else {
                return;
            };
            let tamanho = formato.size();
            let qual = match formato.format() {
                VideoFormat::RGBx => Formato::Rgbx,
                VideoFormat::RGBA => Formato::Rgba,
                VideoFormat::BGRx => Formato::Bgrx,
                VideoFormat::BGRA => Formato::Bgra,
                VideoFormat::RGB => Formato::Rgb,
                VideoFormat::BGR => Formato::Bgr,
                _ => return,
            };
            let pedaco = dado.chunk();
            let (inicio, ocupado, stride) = (
                pedaco.offset() as usize,
                pedaco.size() as usize,
                pedaco.stride().max(0) as usize,
            );
            let Some(bytes) = dado.data() else { return };
            // Quadro vazio é o compositor dizendo "nada mudou" (só o cursor,
            // por exemplo): não há imagem a converter.
            if ocupado == 0 || inicio + ocupado > bytes.len() {
                return;
            }
            if let Some(rgba) = para_rgba(
                &bytes[inicio..inicio + ocupado],
                qual,
                tamanho.width as usize,
                tamanho.height as usize,
                stride,
            ) {
                // `try_send`: se quem consome está atrasado, este quadro some
                // e o próximo vale. Acumular seria mostrar o passado.
                let _ = saida.try_send(Quadro {
                    rgba,
                    largura: tamanho.width,
                    altura: tamanho.height,
                });
            }
        })
        .register()
        .map_err(|e| e.to_string())?;

    let objeto = pod::object!(
        spa::utils::SpaTypes::ObjectParamFormat,
        ParamType::EnumFormat,
        pod::property!(FormatProperties::MediaType, Id, MediaType::Video),
        pod::property!(FormatProperties::MediaSubtype, Id, MediaSubtype::Raw),
        pod::property!(
            FormatProperties::VideoFormat,
            Choice,
            Enum,
            Id,
            VideoFormat::BGRx,
            VideoFormat::BGRx,
            VideoFormat::RGBx,
            VideoFormat::BGRA,
            VideoFormat::RGBA,
            VideoFormat::RGB,
            VideoFormat::BGR,
        ),
        pod::property!(
            FormatProperties::VideoSize,
            Choice,
            Range,
            Rectangle,
            spa::utils::Rectangle {
                width: 1920,
                height: 1080
            },
            spa::utils::Rectangle {
                width: 1,
                height: 1
            },
            spa::utils::Rectangle {
                width: 8192,
                height: 8192
            }
        ),
        pod::property!(
            FormatProperties::VideoFramerate,
            Choice,
            Range,
            Fraction,
            spa::utils::Fraction { num: 30, denom: 1 },
            spa::utils::Fraction { num: 0, denom: 1 },
            spa::utils::Fraction { num: 60, denom: 1 }
        ),
    );
    let bytes = pod::serialize::PodSerializer::serialize(
        std::io::Cursor::new(Vec::new()),
        &pod::Value::Object(objeto),
    )
    .map_err(|e| format!("{e:?}"))?
    .0
    .into_inner();
    let mut parametros = [Pod::from_bytes(&bytes).ok_or("formato inválido")?];
    fluxo
        .connect(
            spa::utils::Direction::Input,
            Some(no),
            pw::stream::StreamFlags::AUTOCONNECT | pw::stream::StreamFlags::MAP_BUFFERS,
            &mut parametros,
        )
        .map_err(|e| e.to_string())?;

    // Em voltas curtas, e não `run()`: é como a thread percebe que é hora de
    // parar sem precisar de um canal do próprio PipeWire.
    while !parar.load(Ordering::SeqCst) {
        laco.loop_()
            .iterate(pw::loop_::Timeout::Finite(Duration::from_millis(100)));
    }
    Ok(())
}

// --- a captura, como o resto do agente a vê -----------------------------------

enum Estado {
    /// A sessão está abrindo numa thread (talvez esperando a permissão).
    Abrindo(Receiver<Result<(Sessao, OwnedFd), String>>),
    Aberta {
        _quadros: Quadros,
    },
    /// Não deu; esta captura não tenta de novo. A próxima (quando alguém abrir
    /// a tela de novo) tenta.
    Desistiu,
}

/// A tela do Wayland para a captura contínua: abre a sessão sem bloquear quem
/// chamou e entrega os quadros conforme chegam.
pub struct Captura {
    estado: Estado,
    cancelamento: Arc<Cancelamento>,
    quadros: Receiver<Quadro>,
    envio: std::sync::mpsc::SyncSender<Quadro>,
}

impl Captura {
    /// Começa a abrir. **Não bloqueia**: na primeira vez a abertura espera
    /// alguém aprovar a janela, e quem chama é o laço que mantém o computador
    /// conectado.
    pub fn iniciar() -> Self {
        let cancelamento = Arc::new(Cancelamento::default());
        let (tx, rx) = std::sync::mpsc::channel();
        let quem = Arc::clone(&cancelamento);
        let _ = std::thread::Builder::new()
            .name("deskside-portal".into())
            .spawn(move || {
                let _ = tx.send(Sessao::abrir(&quem));
            });
        let (envio, quadros) = std::sync::mpsc::sync_channel(2);
        Self {
            estado: Estado::Abrindo(rx),
            cancelamento,
            quadros,
            envio,
        }
    }

    /// O quadro mais recente, esperando até `prazo`.
    pub fn proximo(&mut self, prazo: Duration) -> Result<Option<Quadro>, String> {
        if let Estado::Abrindo(rx) = &self.estado {
            match rx.recv_timeout(prazo) {
                Err(RecvTimeoutError::Timeout) => return Ok(None),
                Err(RecvTimeoutError::Disconnected) => {
                    self.estado = Estado::Desistiu;
                    return Err("a abertura da tela morreu".to_string());
                }
                Ok(Err(e)) => {
                    self.estado = Estado::Desistiu;
                    crate::aviso::avisar(&format!("Não deu para abrir a tela do computador: {e}."));
                    return Err(e);
                }
                Ok(Ok((sessao, fd))) => {
                    crate::diario(&format!(
                        "Wayland: tela liberada ({}x{}, nó {})",
                        sessao.largura, sessao.altura, sessao.no
                    ));
                    if let Ok(mut t) = ULTIMO_TAMANHO.lock() {
                        *t = Some((sessao.largura, sessao.altura));
                    }
                    let quadros = Quadros::iniciar(fd, sessao.no, self.envio.clone());
                    if let Ok(mut a) = ATUAL.lock() {
                        *a = Some(Arc::new(sessao));
                    }
                    self.estado = Estado::Aberta { _quadros: quadros };
                }
            }
        }
        if matches!(self.estado, Estado::Desistiu) {
            std::thread::sleep(prazo);
            return Ok(None);
        }
        let mut quadro = match self.quadros.recv_timeout(prazo) {
            Ok(q) => q,
            Err(_) => return Ok(None),
        };
        while let Ok(mais_novo) = self.quadros.try_recv() {
            quadro = mais_novo;
        }
        Ok(Some(quadro))
    }
}

impl Drop for Captura {
    fn drop(&mut self) {
        // A abertura pode estar esperando a janela de permissão: fechar a
        // sessão é o que a faz desistir.
        self.cancelamento.cancelar();
        if matches!(self.estado, Estado::Aberta { .. }) {
            // Fecha a sessão (e apaga o ícone de compartilhamento) soltando a
            // última referência. O injetor que ainda tiver uma a solta no
            // próximo comando, ao ver que não há mais sessão em uso.
            if let Ok(mut a) = ATUAL.lock() {
                a.take();
            }
        }
    }
}

/// Na primeira vez, pede a permissão logo ao iniciar — quando há alguém diante
/// do computador, que é quem acabou de abrir o agente. Sem isso, o pedido
/// apareceria na primeira vez que o celular abrisse a tela, possivelmente sem
/// ninguém para aprovar.
pub fn preparar() {
    if !ativo() || ler_ficha().is_some() {
        return;
    }
    let _ = std::thread::Builder::new()
        .name("deskside-permissao".into())
        .spawn(|| {
            println!(
                "Este computador usa Wayland. Aprove o acesso na janela que vai aparecer \
                 (uma vez só: depois o sistema lembra)."
            );
            match Sessao::abrir(&Cancelamento::default()) {
                Ok(_) => println!("Acesso aprovado. A tela já pode ser vista pelo celular."),
                Err(e) => println!(
                    "O acesso não foi aprovado ({e}). Ele será pedido de novo quando o \
                     celular abrir a tela."
                ),
            }
        });
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn o_texto_que_o_agente_poe_sai_em_todos_os_tipos_de_texto() {
        let c = Conteudo::Texto("ção".into());
        for tipo in TIPOS_DE_TEXTO {
            assert_eq!(c.dados(tipo), Some("ção".as_bytes()));
        }
        assert_eq!(c.dados("image/png"), None);
        let p = Conteudo::Png(vec![1, 2]);
        assert_eq!(p.tipos(), vec!["image/png"]);
        assert_eq!(p.dados("text/plain"), None);
    }

    #[test]
    fn escolhe_o_melhor_tipo_de_texto_oferecido() {
        let tipos = |l: &[&str]| l.iter().map(|t| t.to_string()).collect::<Vec<_>>();
        assert_eq!(
            tipo_de_texto(&tipos(&["STRING", "text/plain;charset=utf-8", "image/png"])),
            Some("text/plain;charset=utf-8")
        );
        assert_eq!(tipo_de_texto(&tipos(&["UTF8_STRING"])), Some("UTF8_STRING"));
        assert_eq!(tipo_de_texto(&tipos(&["image/png"])), None);
    }

    #[test]
    fn le_o_descritor_mesmo_quando_os_dados_atrasam() {
        // O portal entrega o descritor sem bloqueio; o programa dono escreve
        // um pouco depois. Ler antes não pode ser confundido com "vazio".
        use std::io::Write;
        use std::os::fd::FromRawFd;
        let mut fds = [0i32; 2];
        extern "C" {
            fn pipe2(fds: *mut i32, flags: i32) -> i32;
        }
        const O_NONBLOCK: i32 = 0o4000;
        assert_eq!(unsafe { pipe2(fds.as_mut_ptr(), O_NONBLOCK) }, 0);
        let leitura = unsafe { OwnedFd::from_raw_fd(fds[0]) };
        let mut escrita = unsafe { std::fs::File::from_raw_fd(fds[1]) };
        let dono = std::thread::spawn(move || {
            std::thread::sleep(Duration::from_millis(50));
            escrita.write_all("ção".as_bytes()).unwrap();
        });
        assert_eq!(ler_descritor(leitura, 1024).unwrap(), "ção".as_bytes());
        dono.join().unwrap();
    }

    #[test]
    fn converte_bgrx_respeitando_o_stride() {
        // 2x2, BGRx, com 4 bytes de sobra no fim de cada linha.
        let dados = [
            1, 2, 3, 0, 4, 5, 6, 0, 9, 9, 9, 9, //
            7, 8, 9, 0, 10, 11, 12, 0, 9, 9, 9, 9,
        ];
        let rgba = para_rgba(&dados, Formato::Bgrx, 2, 2, 12).unwrap();
        assert_eq!(
            rgba,
            [3, 2, 1, 255, 6, 5, 4, 255, 9, 8, 7, 255, 12, 11, 10, 255]
        );
    }

    #[test]
    fn converte_rgb_sem_stride_informado() {
        let dados = [1, 2, 3, 4, 5, 6];
        assert_eq!(
            para_rgba(&dados, Formato::Rgb, 2, 1, 0).unwrap(),
            [1, 2, 3, 255, 4, 5, 6, 255]
        );
    }

    #[test]
    fn dados_curtos_demais_nao_viram_imagem() {
        assert!(para_rgba(&[0; 7], Formato::Rgba, 2, 1, 8).is_none());
        // Stride menor que a linha é impossível.
        assert!(para_rgba(&[0; 64], Formato::Rgba, 4, 2, 8).is_none());
    }
}
