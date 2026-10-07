//! TURN por TCP — acrescentado pelo Deskside, não existe no webrtc-rs 0.17.2.
//!
//! O cliente TURN do webrtc-rs (`turn::client::Client`) fala com o servidor
//! por qualquer coisa que implemente `util::Conn`, uma interface de
//! **datagramas**: cada `recv_from` devolve uma mensagem inteira. Por UDP isso
//! vem de graça. Por TCP não: o fluxo é contínuo, e uma mensagem pode chegar
//! partida em dois `read`, ou duas grudadas num só.
//!
//! Este arquivo é a ponte: um `Conn` sobre um `TcpStream` que remonta as
//! mensagens. O enquadramento é o da RFC 5766, §2.1 e §11.5 — sem cabeçalho
//! próprio, as mensagens vão uma atrás da outra, e o tamanho de cada uma sai
//! dela mesma:
//!
//! - **STUN** (os dois primeiros bits `00`): 20 bytes de cabeçalho mais o
//!   comprimento do campo nos bytes 2–3.
//! - **ChannelData** (os dois primeiros bits `01`): 4 bytes de cabeçalho mais
//!   o comprimento, **completado até múltiplo de 4** — por TCP o preenchimento
//!   é obrigatório, e o cliente TURN do webrtc-rs, feito para UDP, não o põe.
//!
//! A alocação continua sendo de **UDP** no servidor: o que muda é só o trecho
//! entre este computador e o TURN. É o que basta para a rede que bloqueia UDP
//! para fora — o servidor é que repassa o vídeo, por UDP, ao celular.

use std::any::Any;
use std::io;
use std::net::SocketAddr;
use std::time::Duration;

use async_trait::async_trait;
use tokio::io::{AsyncReadExt, AsyncWriteExt};
use tokio::net::tcp::{OwnedReadHalf, OwnedWriteHalf};
use tokio::net::TcpStream;
use tokio::sync::Mutex;
use util::Conn;

/// Quanto esperar pela conexão TCP com o servidor TURN.
const PRAZO_DE_CONEXAO: Duration = Duration::from_secs(5);

/// O tamanho de uma mensagem a partir dos 4 primeiros bytes dela.
///
/// Devolve `(tamanho útil, tamanho no fio)`: o segundo inclui o preenchimento
/// do ChannelData. `None` quando os bytes não começam nem STUN nem
/// ChannelData — o fluxo se perdeu, e não há como achar a próxima mensagem.
pub(crate) fn tamanho_da_mensagem(inicio: &[u8]) -> Option<(usize, usize)> {
    if inicio.len() < 4 {
        return None;
    }
    let comprimento = u16::from_be_bytes([inicio[2], inicio[3]]) as usize;
    match inicio[0] >> 6 {
        0b00 => Some((20 + comprimento, 20 + comprimento)),
        0b01 => {
            let util = 4 + comprimento;
            Some((util, (util + 3) & !3))
        }
        _ => None,
    }
}

/// Quantos zeros faltam depois desta mensagem para ela ir pelo TCP.
pub(crate) fn preenchimento(mensagem: &[u8]) -> usize {
    if mensagem.first().is_some_and(|b| b >> 6 == 0b01) {
        (4 - mensagem.len() % 4) % 4
    } else {
        0
    }
}

struct Leitura {
    metade: OwnedReadHalf,
    /// O que já chegou e ainda não formou uma mensagem inteira.
    pendente: Vec<u8>,
}

/// Uma conexão TCP com o servidor TURN, vista como datagramas.
pub struct TurnTcpConn {
    leitura: Mutex<Leitura>,
    escrita: Mutex<OwnedWriteHalf>,
    local: SocketAddr,
    servidor: SocketAddr,
}

impl TurnTcpConn {
    pub async fn conectar(servidor: SocketAddr) -> io::Result<Self> {
        let fluxo = tokio::time::timeout(PRAZO_DE_CONEXAO, TcpStream::connect(servidor))
            .await
            .map_err(|_| io::Error::new(io::ErrorKind::TimedOut, "o servidor TURN não respondeu"))??;
        Self::sobre(fluxo)
    }

    /// Sobre um fluxo já aberto. Serve também ao lado do servidor nos testes.
    pub fn sobre(fluxo: TcpStream) -> io::Result<Self> {
        // Sem Nagle: as mensagens do TURN são pequenas e esperam resposta, e
        // segurá-las para juntar com a próxima só acrescentaria atraso.
        fluxo.set_nodelay(true)?;
        let local = fluxo.local_addr()?;
        let servidor = fluxo.peer_addr()?;
        let (leitura, escrita) = fluxo.into_split();
        Ok(Self {
            leitura: Mutex::new(Leitura {
                metade: leitura,
                pendente: Vec::with_capacity(4096),
            }),
            escrita: Mutex::new(escrita),
            local,
            servidor,
        })
    }
}

#[async_trait]
impl Conn for TurnTcpConn {
    async fn connect(&self, _addr: SocketAddr) -> util::Result<()> {
        Err(util::Error::Other("TURN por TCP: a conexão já está aberta".into()))
    }

    async fn recv(&self, buf: &mut [u8]) -> util::Result<usize> {
        self.recv_from(buf).await.map(|(n, _)| n)
    }

    async fn recv_from(&self, buf: &mut [u8]) -> util::Result<(usize, SocketAddr)> {
        let mut l = self.leitura.lock().await;
        loop {
            match tamanho_da_mensagem(&l.pendente) {
                Some((util, total)) if l.pendente.len() >= total => {
                    let n = util.min(buf.len());
                    buf[..n].copy_from_slice(&l.pendente[..n]);
                    l.pendente.drain(..total);
                    return Ok((n, self.servidor));
                }
                None if l.pendente.len() >= 4 => {
                    return Err(util::Error::Other(
                        "TURN por TCP: chegou algo que não é STUN nem ChannelData".into(),
                    ));
                }
                _ => {}
            }
            let mut pedaco = [0u8; 4096];
            let n = l.metade.read(&mut pedaco).await?;
            if n == 0 {
                return Err(io::Error::new(
                    io::ErrorKind::UnexpectedEof,
                    "o servidor TURN fechou a conexão",
                )
                .into());
            }
            l.pendente.extend_from_slice(&pedaco[..n]);
        }
    }

    async fn send(&self, buf: &[u8]) -> util::Result<usize> {
        let zeros = [0u8; 3];
        let mut e = self.escrita.lock().await;
        e.write_all(buf).await?;
        e.write_all(&zeros[..preenchimento(buf)]).await?;
        Ok(buf.len())
    }

    async fn send_to(&self, buf: &[u8], _alvo: SocketAddr) -> util::Result<usize> {
        // Uma conexão só, com um destino só: o servidor TURN.
        self.send(buf).await
    }

    fn local_addr(&self) -> util::Result<SocketAddr> {
        Ok(self.local)
    }

    fn remote_addr(&self) -> Option<SocketAddr> {
        Some(self.servidor)
    }

    async fn close(&self) -> util::Result<()> {
        let _ = self.escrita.lock().await.shutdown().await;
        Ok(())
    }

    fn as_any(&self) -> &(dyn Any + Send + Sync) {
        self
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn stun(comprimento: u16) -> Vec<u8> {
        let mut m = vec![0x00, 0x01];
        m.extend_from_slice(&comprimento.to_be_bytes());
        m.extend_from_slice(&[0x21, 0x12, 0xA4, 0x42]);
        m.extend_from_slice(&[7u8; 12]);
        m.extend(std::iter::repeat(9u8).take(comprimento as usize));
        m
    }

    fn channel_data(dados: &[u8]) -> Vec<u8> {
        let mut m = vec![0x40, 0x00];
        m.extend_from_slice(&(dados.len() as u16).to_be_bytes());
        m.extend_from_slice(dados);
        m
    }

    #[test]
    fn tamanho_de_stun_e_de_channel_data() {
        assert_eq!(tamanho_da_mensagem(&stun(8)), Some((28, 28)));
        // 4 + 5 = 9 úteis, 12 no fio.
        assert_eq!(tamanho_da_mensagem(&channel_data(&[1, 2, 3, 4, 5])), Some((9, 12)));
        assert_eq!(tamanho_da_mensagem(&[0x00, 0x01]), None, "incompleto");
        assert_eq!(tamanho_da_mensagem(&[0xC0, 0, 0, 0]), None, "nem STUN nem ChannelData");
    }

    #[test]
    fn so_channel_data_e_completado() {
        assert_eq!(preenchimento(&channel_data(&[1, 2, 3, 4, 5])), 3);
        assert_eq!(preenchimento(&channel_data(&[1, 2, 3, 4])), 0);
        assert_eq!(preenchimento(&stun(8)), 0);
    }

    async fn par() -> (TurnTcpConn, TcpStream) {
        let ouvinte = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
        let endereco = ouvinte.local_addr().unwrap();
        let (cliente, aceito) = tokio::join!(TurnTcpConn::conectar(endereco), ouvinte.accept());
        (cliente.unwrap(), aceito.unwrap().0)
    }

    #[tokio::test]
    async fn remonta_mensagens_partidas_e_grudadas() {
        let (conn, mut outro) = par().await;
        let a = stun(8);
        let b = channel_data(&[1, 2, 3, 4, 5]);
        let mut fio = a.clone();
        fio.extend_from_slice(&b);
        fio.extend_from_slice(&[0, 0, 0]); // o preenchimento do ChannelData
        // Partido no meio da primeira mensagem, e a segunda grudada no resto.
        outro.write_all(&fio[..10]).await.unwrap();
        outro.flush().await.unwrap();
        tokio::time::sleep(Duration::from_millis(20)).await;
        outro.write_all(&fio[10..]).await.unwrap();

        let mut buf = [0u8; 1500];
        let (n, de) = conn.recv_from(&mut buf).await.unwrap();
        assert_eq!(&buf[..n], &a[..]);
        assert_eq!(de, conn.remote_addr().unwrap());
        let n = conn.recv(&mut buf).await.unwrap();
        // Sem o preenchimento: quem lê é o cliente TURN, que conta pelo campo.
        assert_eq!(&buf[..n], &b[..]);
    }

    #[tokio::test]
    async fn envia_channel_data_com_preenchimento() {
        let (conn, mut outro) = par().await;
        let m = channel_data(&[1, 2, 3, 4, 5]);
        conn.send_to(&m, "1.2.3.4:5".parse().unwrap()).await.unwrap();
        conn.close().await.unwrap();
        let mut recebido = Vec::new();
        outro.read_to_end(&mut recebido).await.unwrap();
        assert_eq!(recebido.len(), 12);
        assert_eq!(&recebido[..9], &m[..]);
        assert_eq!(&recebido[9..], &[0, 0, 0]);
    }

    #[tokio::test]
    async fn lixo_no_fluxo_vira_erro_e_nao_laco() {
        let (conn, mut outro) = par().await;
        outro.write_all(&[0xC0, 1, 2, 3, 4]).await.unwrap();
        let mut buf = [0u8; 64];
        assert!(conn.recv(&mut buf).await.is_err());
    }

    #[tokio::test]
    async fn servidor_que_fecha_vira_erro() {
        let (conn, outro) = par().await;
        drop(outro);
        let mut buf = [0u8; 64];
        assert!(conn.recv(&mut buf).await.is_err());
    }

    /// De ponta a ponta: um servidor TURN de verdade (o do próprio webrtc-rs)
    /// atrás de TCP, e o agente ICE juntando um caminho de repasse por ele.
    ///
    /// Sem o ramo novo em `agent_gather.rs`, a URL `?transport=tcp` é
    /// ignorada com um aviso e nenhum candidato `relay` aparece.
    #[tokio::test]
    async fn o_agente_consegue_repasse_por_tcp() {
        use std::net::IpAddr;
        use std::sync::Arc;

        use crate::agent::agent_config::AgentConfig;
        use crate::agent::agent_vnet_test::TestAuthHandler;
        use crate::agent::Agent;
        use crate::candidate::{Candidate, CandidateType};
        use crate::network_type::NetworkType;
        use crate::url::Url;

        // O servidor TURN, escutando TCP no loopback.
        let ouvinte = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
        let porta = ouvinte.local_addr().unwrap().port();
        let servidor = tokio::spawn(async move {
            let (fluxo, _) = ouvinte.accept().await.unwrap();
            let conn = TurnTcpConn::sobre(fluxo).unwrap();
            turn::server::Server::new(turn::server::config::ServerConfig {
                conn_configs: vec![turn::server::config::ConnConfig {
                    conn: Arc::new(conn),
                    relay_addr_generator: Box::new(
                        turn::relay::relay_static::RelayAddressGeneratorStatic {
                            relay_address: IpAddr::from([127, 0, 0, 1]),
                            address: "127.0.0.1".to_owned(),
                            net: Arc::new(util::vnet::net::Net::new(None)),
                        },
                    ),
                }],
                realm: "webrtc.rs".to_owned(),
                auth_handler: Arc::new(TestAuthHandler::new()),
                channel_bind_timeout: Duration::from_secs(0),
                alloc_close_notify: None,
            })
            .await
            .unwrap()
        });

        let mut url = Url::parse_url(&format!("turn:127.0.0.1:{porta}?transport=tcp")).unwrap();
        url.username = "user".to_owned();
        url.password = "pass".to_owned();
        let agente = Agent::new(AgentConfig {
            urls: vec![url],
            network_types: vec![NetworkType::Udp4],
            candidate_types: vec![CandidateType::Relay],
            ..Default::default()
        })
        .await
        .unwrap();

        let (fim_tx, mut fim_rx) = tokio::sync::mpsc::channel::<()>(1);
        let fim_tx = Arc::new(Mutex::new(Some(fim_tx)));
        agente.on_candidate(Box::new(
            move |c: Option<Arc<dyn Candidate + Send + Sync>>| {
                let fim_tx = Arc::clone(&fim_tx);
                Box::pin(async move {
                    if c.is_none() {
                        fim_tx.lock().await.take();
                    }
                })
            },
        ));
        agente.gather_candidates().unwrap();
        tokio::time::timeout(Duration::from_secs(10), fim_rx.recv())
            .await
            .expect("a coleta de caminhos não terminou");

        let candidatos = agente.get_local_candidates().await.unwrap();
        assert!(
            candidatos
                .iter()
                .any(|c| c.candidate_type() == CandidateType::Relay && c.address() == "127.0.0.1"),
            "nenhum repasse pelo TURN por TCP: {:?}",
            candidatos.iter().map(|c| c.to_string()).collect::<Vec<_>>()
        );

        agente.close().await.unwrap();
        servidor.await.unwrap().close().await.unwrap();
    }
}
