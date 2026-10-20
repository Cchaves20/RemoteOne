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

// --- o aviso ao celular -------------------------------------------------------

static AVISO: Mutex<Option<String>> = Mutex::new(None);

pub(crate) fn avisar(texto: &str) {
    if let Ok(mut a) = AVISO.lock() {
        *a = Some(texto.to_string());
    }
}

/// O aviso pendente para o celular, se houver. Quem lê é o laço de rede.
pub fn tomar_aviso() -> Option<String> {
    AVISO.lock().ok()?.take()
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
            Ok((no, largura, altura, fd)) => Ok((
                Sessao {
                    conn,
                    remoto,
                    caminho,
                    no,
                    largura,
                    altura,
                },
                fd,
            )),
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
    ) -> Result<(u32, u32, u32, OwnedFd), String> {
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
                avisar(PEDINDO_PERMISSAO);
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
        Ok((no, largura.max(1) as u32, altura.max(1) as u32, fd.into()))
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
                    avisar(&format!("Não deu para abrir a tela do computador: {e}."));
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
