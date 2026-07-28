//! Protocolo de mensagens do WebSocket agente ↔ backend.
//!
//! O formato de fio precisa ser idêntico ao do backend em
//! `backend/app/protocol.py`. Os testes abaixo fixam o JSON exato.

use serde::{Deserialize, Serialize};

use crate::apps::{AppInfo, AppKind};
use crate::files::Listing;
use crate::input::{InputAction, MediaAction};
use crate::system_info::SystemSnapshot;

/// Mensagens que o agente envia ao backend.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(tag = "type", rename_all = "snake_case")]
pub enum ClientMessage {
    Hello {
        device_id: String,
        hostname: String,
        os: String,
        agent_version: String,
        /// MAC da placa de rede local, para Wake-on-LAN. Opcional (nem toda
        /// máquina resolve; o backend guarda quando presente).
        #[serde(default, skip_serializing_if = "Option::is_none")]
        mac: Option<String>,
    },
    Heartbeat,
    /// Resposta a um `list_apps`: a lista pedida, com o mesmo `request_id`
    /// para o backend casar com quem está esperando.
    AppList {
        request_id: String,
        apps: Vec<AppInfo>,
    },
    /// Resposta a um `system_info`: as métricas do computador, com o mesmo
    /// `request_id` do pedido.
    SystemStats {
        request_id: String,
        stats: SystemSnapshot,
    },
    /// Resposta a um `foreground`: o programa em primeiro plano, ou nada
    /// quando não deu para descobrir (o app fica com os ícones genéricos).
    ForegroundApp {
        request_id: String,
        /// Caminho completo do tipo: aqui `ForegroundApp` é o nome da
        /// variante, e importar o tipo com o mesmo nome só confundiria.
        #[serde(default, skip_serializing_if = "Option::is_none")]
        app: Option<crate::foreground::ForegroundApp>,
    },
    /// Resposta a um `list_files`: o conteúdo da pasta, **ou** o motivo de não
    /// ter conseguido. Uma pasta sem permissão não pode chegar ao app como
    /// pasta vazia — são coisas diferentes para quem procura um arquivo.
    FileList {
        request_id: String,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        listing: Option<Listing>,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        error: Option<String>,
    },
    /// Um pedaço de um arquivo que o app pediu para baixar. `data` é base64.
    ///
    /// A sequência existe para o backend detectar pedaço fora de ordem em vez de
    /// montar um arquivo corrompido em silêncio.
    FileChunk {
        transfer_id: String,
        seq: u64,
        data: String,
    },
    /// O fim de uma transferência, nos dois sentidos: `ok` diz se deu certo, e
    /// `detail` traz o caminho salvo (envio) ou o motivo da falha.
    FileDone {
        transfer_id: String,
        ok: bool,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        detail: Option<String>,
        /// Tamanho total, para o app baixando saber quanto esperar.
        #[serde(default, skip_serializing_if = "Option::is_none")]
        size: Option<u64>,
    },
    /// Resposta SDP à oferta de um app (negociação de vídeo por WebRTC).
    WebrtcAnswer {
        session_id: String,
        sdp: String,
    },
    /// Um candidato ICE. Mesmo formato nos dois sentidos.
    WebrtcIce {
        session_id: String,
        candidate: String,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        sdp_mid: Option<String>,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        sdp_mline_index: Option<u32>,
    },
}

/// Mensagens que o backend envia ao agente.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(tag = "type", rename_all = "snake_case")]
pub enum ServerMessage {
    Welcome {
        server_version: String,
    },
    Ack,
    Error {
        message: String,
    },
    /// Código de pareamento a ser exibido ao usuário (dispositivo não pareado).
    PairCode {
        code: String,
        expires_in_seconds: u64,
    },
    /// O dispositivo foi vinculado a uma conta.
    Paired {
        user_email: String,
    },
    /// Comando de entrada a ser injetado no computador (Etapa 6).
    Input {
        action: InputAction,
    },
    /// Inicia a transmissão da tela (Etapa 7). `quality` e `max_width` são
    /// opcionais: quando presentes, o app está ajustando qualidade/desempenho.
    StartStream {
        max_fps: u32,
        #[serde(default)]
        quality: Option<u8>,
        #[serde(default)]
        max_width: Option<u32>,
    },
    /// Encerra a transmissão da tela.
    StopStream,
    /// Comando de energia: desligar, reiniciar ou suspender o computador.
    Power {
        action: PowerAction,
    },
    /// Pede a este agente que acorde (Wake-on-LAN) uma máquina vizinha da LAN
    /// enviando o pacote mágico para o MAC informado.
    Wake {
        mac: String,
    },
    /// Pede a lista de aplicativos (instalados ou em execução). O agente
    /// responde com `app_list` carregando o mesmo `request_id`.
    ListApps {
        request_id: String,
        kind: AppKind,
    },
    /// Pede as métricas do computador (CPU, memória, disco). O agente responde
    /// com `system_stats` carregando o mesmo `request_id`.
    SystemInfo {
        request_id: String,
    },
    /// Pergunta qual programa está em primeiro plano. O agente responde com
    /// `foreground_app` carregando o mesmo `request_id`.
    ForegroundInfo {
        request_id: String,
    },
    /// Aciona uma tecla de mídia (play/pause, faixa, volume). Mão única: não há
    /// resposta a esperar.
    Media {
        action: MediaAction,
    },
    /// Pede o conteúdo de uma pasta. Caminho vazio = a pasta do usuário.
    ListFiles {
        request_id: String,
        #[serde(default)]
        path: String,
    },
    /// Pede que o agente leia um arquivo e o mande em pedaços (`file_chunk`).
    ReadFile {
        transfer_id: String,
        path: String,
    },
    /// Começa a receber um arquivo vindo do celular.
    WriteFileBegin {
        transfer_id: String,
        name: String,
        /// Tamanho anunciado, para recusar antes de gastar disco.
        size: u64,
    },
    /// Um pedaço do arquivo que está sendo enviado ao computador (base64).
    WriteFileChunk {
        transfer_id: String,
        seq: u64,
        data: String,
    },
    /// Fim do envio: o agente publica o arquivo e responde com `file_done`.
    WriteFileEnd {
        transfer_id: String,
    },
    /// Desiste de uma transferência em curso (app fechou, rede caiu).
    CancelTransfer {
        transfer_id: String,
    },
    /// Abre um aplicativo (id = caminho do atalho).
    LaunchApp {
        id: String,
    },
    /// Encerra um aplicativo em execução (id = PID).
    CloseApp {
        id: String,
    },
    /// Oferta SDP de um app querendo receber a tela por WebRTC. O `session_id`
    /// identifica o app: o mesmo agente pode negociar com vários ao mesmo
    /// tempo, e a resposta tem que voltar carregando este mesmo id.
    WebrtcOffer {
        session_id: String,
        sdp: String,
    },
    /// Candidato ICE vindo de um app. `candidate` vazio significa que os
    /// candidatos daquele lado acabaram.
    WebrtcIce {
        session_id: String,
        candidate: String,
        #[serde(default)]
        sdp_mid: Option<String>,
        #[serde(default)]
        sdp_mline_index: Option<u32>,
    },
    /// O app saiu: a conexão WebRTC daquela sessão pode ser descartada.
    WebrtcClose {
        session_id: String,
    },
}

/// Ações de energia suportadas pelo agente.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum PowerAction {
    Shutdown,
    Restart,
    Suspend,
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn hello_serializes_with_type_tag() {
        let hello = ClientMessage::Hello {
            device_id: "dev-1".into(),
            hostname: "dell-g5".into(),
            os: "windows".into(),
            agent_version: "0.1.0".into(),
            mac: Some("01:23:45:AB:CD:EF".into()),
        };
        let value: serde_json::Value = serde_json::to_value(&hello).unwrap();
        assert_eq!(value["type"], "hello");
        assert_eq!(value["device_id"], "dev-1");
        assert_eq!(value["os"], "windows");
        assert_eq!(value["mac"], "01:23:45:AB:CD:EF");
    }

    #[test]
    fn heartbeat_serializes_to_just_the_tag() {
        let json = serde_json::to_string(&ClientMessage::Heartbeat).unwrap();
        assert_eq!(json, r#"{"type":"heartbeat"}"#);
    }

    #[test]
    fn deserializes_welcome() {
        let msg: ServerMessage =
            serde_json::from_str(r#"{"type":"welcome","server_version":"0.1.0"}"#).unwrap();
        assert_eq!(
            msg,
            ServerMessage::Welcome {
                server_version: "0.1.0".into()
            }
        );
    }

    #[test]
    fn deserializes_ack_and_error() {
        let ack: ServerMessage = serde_json::from_str(r#"{"type":"ack"}"#).unwrap();
        assert_eq!(ack, ServerMessage::Ack);

        let err: ServerMessage =
            serde_json::from_str(r#"{"type":"error","message":"xis"}"#).unwrap();
        assert_eq!(
            err,
            ServerMessage::Error {
                message: "xis".into()
            }
        );
    }

    #[test]
    fn deserializes_pair_code_and_paired() {
        let pc: ServerMessage = serde_json::from_str(
            r#"{"type":"pair_code","code":"ABC23XYZK","expires_in_seconds":600}"#,
        )
        .unwrap();
        assert_eq!(
            pc,
            ServerMessage::PairCode {
                code: "ABC23XYZK".into(),
                expires_in_seconds: 600
            }
        );

        let paired: ServerMessage =
            serde_json::from_str(r#"{"type":"paired","user_email":"caio@example.com"}"#).unwrap();
        assert_eq!(
            paired,
            ServerMessage::Paired {
                user_email: "caio@example.com".into()
            }
        );
    }

    #[test]
    fn deserializes_start_stream_with_and_without_quality() {
        // Formato antigo (só fps): quality/max_width ausentes viram None.
        let basic: ServerMessage =
            serde_json::from_str(r#"{"type":"start_stream","max_fps":3}"#).unwrap();
        assert_eq!(
            basic,
            ServerMessage::StartStream {
                max_fps: 3,
                quality: None,
                max_width: None,
            }
        );

        // Formato novo: app ajustando qualidade/desempenho.
        let tuned: ServerMessage = serde_json::from_str(
            r#"{"type":"start_stream","max_fps":10,"quality":70,"max_width":1600}"#,
        )
        .unwrap();
        assert_eq!(
            tuned,
            ServerMessage::StartStream {
                max_fps: 10,
                quality: Some(70),
                max_width: Some(1600),
            }
        );
    }

    #[test]
    fn deserializes_wake() {
        let msg: ServerMessage =
            serde_json::from_str(r#"{"type":"wake","mac":"01:23:45:AB:CD:EF"}"#).unwrap();
        assert_eq!(
            msg,
            ServerMessage::Wake {
                mac: "01:23:45:AB:CD:EF".into()
            }
        );
    }

    #[test]
    fn deserializes_power_actions() {
        for (json, expected) in [
            (
                r#"{"type":"power","action":"shutdown"}"#,
                PowerAction::Shutdown,
            ),
            (
                r#"{"type":"power","action":"restart"}"#,
                PowerAction::Restart,
            ),
            (
                r#"{"type":"power","action":"suspend"}"#,
                PowerAction::Suspend,
            ),
        ] {
            let msg: ServerMessage = serde_json::from_str(json).unwrap();
            assert_eq!(msg, ServerMessage::Power { action: expected });
        }
    }

    #[test]
    fn deserializes_webrtc_offer_and_close() {
        let offer: ServerMessage =
            serde_json::from_str(r#"{"type":"webrtc_offer","session_id":"s1","sdp":"v=0\r\n"}"#)
                .unwrap();
        assert_eq!(
            offer,
            ServerMessage::WebrtcOffer {
                session_id: "s1".into(),
                sdp: "v=0\r\n".into(),
            }
        );

        let close: ServerMessage =
            serde_json::from_str(r#"{"type":"webrtc_close","session_id":"s1"}"#).unwrap();
        assert_eq!(
            close,
            ServerMessage::WebrtcClose {
                session_id: "s1".into()
            }
        );
    }

    #[test]
    fn deserializes_webrtc_ice_with_and_without_optionals() {
        let full: ServerMessage = serde_json::from_str(
            r#"{"type":"webrtc_ice","session_id":"s1","candidate":"candidate:1 1 udp 1 10.0.0.2 5000 typ host","sdp_mid":"0","sdp_mline_index":0}"#,
        )
        .unwrap();
        assert_eq!(
            full,
            ServerMessage::WebrtcIce {
                session_id: "s1".into(),
                candidate: "candidate:1 1 udp 1 10.0.0.2 5000 typ host".into(),
                sdp_mid: Some("0".into()),
                sdp_mline_index: Some(0),
            }
        );

        // Fim dos candidatos: candidato vazio, opcionais ausentes. O backend
        // manda `null` nesses campos, e `null` tem que virar None.
        let end: ServerMessage = serde_json::from_str(
            r#"{"type":"webrtc_ice","session_id":"s1","candidate":"","sdp_mid":null,"sdp_mline_index":null}"#,
        )
        .unwrap();
        assert_eq!(
            end,
            ServerMessage::WebrtcIce {
                session_id: "s1".into(),
                candidate: String::new(),
                sdp_mid: None,
                sdp_mline_index: None,
            }
        );
    }

    #[test]
    fn webrtc_answer_serializes_for_the_backend() {
        let json = serde_json::to_string(&ClientMessage::WebrtcAnswer {
            session_id: "s1".into(),
            sdp: "v=0".into(),
        })
        .unwrap();
        assert_eq!(
            json,
            r#"{"type":"webrtc_answer","session_id":"s1","sdp":"v=0"}"#
        );
    }

    #[test]
    fn webrtc_ice_omits_absent_optionals_when_serializing() {
        // Mensagem menor no fio, e o backend aceita os campos ausentes.
        let json = serde_json::to_string(&ClientMessage::WebrtcIce {
            session_id: "s1".into(),
            candidate: String::new(),
            sdp_mid: None,
            sdp_mline_index: None,
        })
        .unwrap();
        assert_eq!(
            json,
            r#"{"type":"webrtc_ice","session_id":"s1","candidate":""}"#
        );
    }

    #[test]
    fn deserializes_file_commands() {
        let listar: ServerMessage =
            serde_json::from_str(r#"{"type":"list_files","request_id":"r1","path":"C:\\Users"}"#)
                .unwrap();
        assert_eq!(
            listar,
            ServerMessage::ListFiles {
                request_id: "r1".into(),
                path: "C:\\Users".into()
            }
        );
        // `path` ausente = a pasta do usuário: é como o app abre a tela.
        let raiz: ServerMessage =
            serde_json::from_str(r#"{"type":"list_files","request_id":"r1"}"#).unwrap();
        assert_eq!(
            raiz,
            ServerMessage::ListFiles {
                request_id: "r1".into(),
                path: String::new()
            }
        );
        let inicio: ServerMessage = serde_json::from_str(
            r#"{"type":"write_file_begin","transfer_id":"t1","name":"foto.png","size":10}"#,
        )
        .unwrap();
        assert_eq!(
            inicio,
            ServerMessage::WriteFileBegin {
                transfer_id: "t1".into(),
                name: "foto.png".into(),
                size: 10
            }
        );
    }

    #[test]
    fn file_chunk_and_done_wire_format() {
        let chunk = serde_json::to_string(&ClientMessage::FileChunk {
            transfer_id: "t1".into(),
            seq: 3,
            data: "AAECAw==".into(),
        })
        .unwrap();
        assert_eq!(
            chunk,
            r#"{"type":"file_chunk","transfer_id":"t1","seq":3,"data":"AAECAw=="}"#
        );
        // Campos ausentes ficam fora do fio; o backend aceita os dois formatos.
        let done = serde_json::to_string(&ClientMessage::FileDone {
            transfer_id: "t1".into(),
            ok: true,
            detail: None,
            size: Some(2048),
        })
        .unwrap();
        assert_eq!(
            done,
            r#"{"type":"file_done","transfer_id":"t1","ok":true,"size":2048}"#
        );
    }

    #[test]
    fn file_list_carrega_erro_ou_conteudo() {
        let erro = serde_json::to_value(&ClientMessage::FileList {
            request_id: "r1".into(),
            listing: None,
            error: Some("fora da pasta do usuário".into()),
        })
        .unwrap();
        assert_eq!(erro["error"], "fora da pasta do usuário");
        assert!(erro.get("listing").is_none(), "sem listagem no fio");

        let ok = serde_json::to_value(&ClientMessage::FileList {
            request_id: "r1".into(),
            listing: Some(crate::files::Listing {
                path: "/home/caio".into(),
                parent: None,
                entries: vec![crate::files::FileEntry {
                    name: "nota.txt".into(),
                    path: "/home/caio/nota.txt".into(),
                    is_dir: false,
                    size: 12,
                }],
            }),
            error: None,
        })
        .unwrap();
        assert_eq!(ok["listing"]["entries"][0]["name"], "nota.txt");
        assert_eq!(ok["listing"]["entries"][0]["is_dir"], false);
        assert!(ok["listing"].get("parent").is_none(), "raiz não volta");
    }

    #[test]
    fn deserializes_system_info_and_media() {
        let info: ServerMessage =
            serde_json::from_str(r#"{"type":"system_info","request_id":"r1"}"#).unwrap();
        assert_eq!(
            info,
            ServerMessage::SystemInfo {
                request_id: "r1".into()
            }
        );
        let media: ServerMessage =
            serde_json::from_str(r#"{"type":"media","action":"play_pause"}"#).unwrap();
        assert_eq!(
            media,
            ServerMessage::Media {
                action: MediaAction::PlayPause
            }
        );
    }

    #[test]
    fn system_stats_serializes_for_the_backend() {
        let json = serde_json::to_string(&ClientMessage::SystemStats {
            request_id: "r1".into(),
            stats: SystemSnapshot {
                cpu_percent: 37.4,
                memory_used: 8_000_000_000,
                memory_total: 16_000_000_000,
                disk_used: 300_000_000_000,
                disk_total: 500_000_000_000,
                disk_name: "C:".into(),
                uptime_seconds: 3600,
            },
        })
        .unwrap();
        assert_eq!(
            json,
            r#"{"type":"system_stats","request_id":"r1","stats":{"cpu_percent":37.4,"memory_used":8000000000,"memory_total":16000000000,"disk_used":300000000000,"disk_total":500000000000,"disk_name":"C:","uptime_seconds":3600}}"#
        );
    }
}
