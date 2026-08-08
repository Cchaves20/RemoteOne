//! Protocolo de mensagens do WebSocket agente ↔ backend.
//!
//! O formato de fio precisa ser idêntico ao do backend em
//! `backend/app/protocol.py`. Os testes abaixo fixam o JSON exato.

use serde::{Deserialize, Serialize};

use crate::apps::{AppInfo, AppKind};
use crate::files::Listing;
use crate::input::{InputAction, MediaAction};
use crate::system_info::SystemSnapshot;

/// Um servidor ICE como o WebRTC o espera.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize, Default)]
pub struct IceServer {
    pub urls: Vec<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub username: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub credential: Option<String>,
}

/// Ganho padrão do áudio: o som como o computador o entregou.
fn ganho_neutro() -> f32 {
    1.0
}

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
    /// Resposta a um `list_monitors`: as telas deste computador.
    MonitorList {
        request_id: String,
        monitors: Vec<crate::capture::MonitorInfo>,
        /// Qual está sendo capturada agora. `None` = ninguém escolheu, e vale
        /// o principal.
        #[serde(default, skip_serializing_if = "Option::is_none")]
        selected: Option<u32>,
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
    /// Resposta a um `clipboard_get`: o que está na área de transferência.
    Clipboard {
        request_id: String,
        #[serde(default)]
        text: String,
        /// Arquivos copiados no computador. Copiar um vídeo no Explorer põe o
        /// **caminho** dele aqui, não os bytes - e quem sabe buscar por
        /// caminho é a transferência de arquivos, que já existe.
        #[serde(default)]
        files: Vec<crate::files::FileEntry>,
        /// Quantos caminhos copiados foram recusados por estarem fora da pasta
        /// do usuário. Sem este número, "copiei três arquivos de `D:\`" e
        /// "não copiei nada" chegam ao telefone iguais.
        #[serde(default)]
        ignored: usize,
        /// A imagem copiada, em base64, quando há uma.
        ///
        /// Vai só na resposta a um pedido, nunca no aviso automático de cópia:
        /// texto custa quilobytes e uma captura de tela custa megabytes, e
        /// mandar isso sem ninguém pedir gastaria a rede de quem copiou uma
        /// imagem para colar no próprio computador.
        #[serde(default, skip_serializing_if = "Option::is_none")]
        image: Option<String>,
        /// `image/png` ou `image/jpeg`. O app precisa saber o que gravar
        /// quando a pessoa manda o arquivo para outro aplicativo.
        #[serde(default, skip_serializing_if = "Option::is_none")]
        image_mime: Option<String>,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        image_width: Option<u32>,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        image_height: Option<u32>,
    },
    /// Aviso de que alguém copiou algo novo no computador. Sai sem pedido, e
    /// só enquanto a sincronia automática estiver ligada.
    ClipboardChanged {
        text: String,
    },
    /// Resposta a um `keep_awake_info`: se o computador está sendo mantido
    /// pronto para controle remoto.
    ///
    /// São **três** informações, e não uma, porque "desligado" e "ligado mas
    /// solto agora" são estados diferentes e o usuário precisa distinguir os
    /// dois. Um notebook na bateria com a opção ligada não está segurando
    /// nada, e mostrar só a chave ligada faria parecer que ele vai continuar
    /// alcançável — que é justamente a promessa que ele não pode cumprir.
    KeepAwakeState {
        request_id: String,
        /// O que o usuário escolheu.
        enabled: bool,
        /// Se o pedido está de pé neste instante.
        holding: bool,
        /// Por que não está, quando não está.
        source: crate::awake::PowerSource,
    },
    /// Resposta a um `launch_many`: o que aconteceu com cada programa.
    ///
    /// A lista volta na **mesma ordem** do pedido, e cada item carrega o
    /// identificador que veio — é o que permite ao app dizer *qual* dos quatro
    /// não abriu, em vez de "algo falhou".
    LaunchManyResult {
        request_id: String,
        results: Vec<crate::lote::Resultado>,
    },
    /// Resposta a um `brightness`: o brilho depois do ajuste.
    ///
    /// Tem resposta, e as teclas de mídia não têm, porque as duas coisas falham
    /// de maneiras diferentes. Volume mexe no sistema e funciona em qualquer
    /// máquina; brilho por software só funciona no **painel embutido** de um
    /// notebook. Num computador de mesa com monitor externo não há o que
    /// ajustar, e sem resposta o toque simplesmente não faria nada - o pior
    /// tipo de falha, a que não deixa rastro.
    BrightnessState {
        request_id: String,
        /// O nível resultante, de 0 a 100. Ausente quando não deu.
        #[serde(default, skip_serializing_if = "Option::is_none")]
        level: Option<u8>,
        /// Por que não deu, quando não deu.
        #[serde(default, skip_serializing_if = "Option::is_none")]
        error: Option<String>,
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
        /// Servidores ICE (STUN e, quando houver, TURN com credencial
        /// temporária). Vem do backend porque a credencial expira - fixá-la
        /// na configuração do agente obrigaria a reinstalar a cada rodízio.
        /// Ausente em backends antigos, daí o `default`.
        #[serde(default)]
        ice_servers: Vec<IceServer>,
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
    /// Pede a lista de monitores. O agente responde com `monitor_list`.
    ListMonitors {
        request_id: String,
    },
    /// Escolhe qual monitor capturar. `None` volta ao principal.
    SetMonitor {
        #[serde(default)]
        monitor: Option<u32>,
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
    /// Pede o que está na área de transferência do computador.
    ClipboardGet {
        request_id: String,
    },
    /// Escreve na área de transferência do computador.
    ClipboardSet {
        text: String,
    },
    /// Liga ou desliga o aviso automático de cópia nova no computador.
    ClipboardSync {
        enabled: bool,
    },
    /// Liga ou desliga o "manter o computador pronto para controle remoto".
    /// A escolha é gravada no `agent.conf`: ela precisa valer no próximo login.
    KeepAwake {
        enabled: bool,
    },
    /// Pergunta se o computador está sendo mantido pronto. O agente responde
    /// com `keep_awake_state` carregando o mesmo `request_id`.
    KeepAwakeInfo {
        request_id: String,
    },
    /// Ajusta o brilho da tela do computador.
    ///
    /// Duas formas na mesma mensagem, e nunca as duas juntas: `level` põe num
    /// valor absoluto (0–100), `delta` anda um passo a partir do que está.
    ///
    /// O passo relativo existe para a barra de perfis, e ele é resolvido **no
    /// computador**. Fazer o telefone ler, somar e escrever custaria duas idas
    /// e voltas por toque, e dois toques rápidos se atropelariam: os dois
    /// leriam o mesmo valor antigo e o segundo desfaria o primeiro.
    Brightness {
        request_id: String,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        level: Option<u8>,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        delta: Option<i16>,
    },
    /// Liga ou desliga o envio do som do computador. Mão única: o resultado
    /// aparece (ou não) no telefone, e um erro aqui não tem o que responder.
    Audio {
        enabled: bool,
        /// Multiplicador do volume antes de codificar. 1.0 = como veio do
        /// computador. Ausente em agentes/servidores antigos, daí o padrão.
        #[serde(default = "ganho_neutro")]
        gain: f32,
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
    /// Abre vários aplicativos de uma vez — o "abrir todos" de um perfil.
    ///
    /// Uma mensagem só, e não N pedidos de `launch_app`, por causa do iOS: quem
    /// aperta o botão e bloqueia a tela teria a lista interrompida no meio, com
    /// o primeiro programa aberto e o resto não. Com a lista inteira aqui, o
    /// telefone pode sair da frente no instante seguinte ao toque.
    ///
    /// Tem `request_id` porque **tem resposta**: o resultado de cada programa
    /// volta em `launch_many_result`. Abrir quatro e não dizer que um falhou é
    /// o defeito que este projeto já corrigiu meia dúzia de vezes.
    /// A lista de programas em `apps`, e as zonas em `zones` **em paralelo**.
    ///
    /// Dois vetores paralelos são normalmente um cheiro ruim, e aqui são
    /// deliberados: é o que faz um agente antigo continuar funcionando. Ele não
    /// conhece `zones`, ignora o campo e abre os programas como sempre - a
    /// degradação certa, porque "abriu sem posicionar" é exatamente o
    /// comportamento anterior. Trocar `apps` por uma lista de objetos quebraria
    /// o "abrir todos" em todo computador que ainda não tivesse atualizado.
    ///
    /// Quando `zones` vem, tem o mesmo tamanho de `apps`; quem garante isso é o
    /// backend, antes de a mensagem sair.
    LaunchMany {
        request_id: String,
        apps: Vec<String>,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        zones: Option<Vec<Option<crate::janelas::Zona>>>,
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
                server_version: "0.1.0".into(),
                // Backend antigo não manda a lista; o agente segue com o STUN
                // dele mesmo em vez de recusar a mensagem.
                ice_servers: Vec::new(),
            }
        );
    }

    #[test]
    fn welcome_com_servidores_ice_traz_a_credencial() {
        // É por aqui que o TURN chega ao agente: sem `username`/`credential` o
        // servidor de relay recusa, e a falha aparece só como "não conectou".
        let json = r#"{"type":"welcome","server_version":"0.1.0","ice_servers":[
            {"urls":["stun:a:19302"]},
            {"urls":["turn:b:3478?transport=udp"],"username":"1:u","credential":"x"}
        ]}"#;
        let ServerMessage::Welcome { ice_servers, .. } = serde_json::from_str(json).unwrap()
        else {
            panic!("esperava welcome");
        };
        assert_eq!(ice_servers.len(), 2);
        assert!(ice_servers[0].username.is_none());
        assert_eq!(ice_servers[1].username.as_deref(), Some("1:u"));
        assert_eq!(ice_servers[1].credential.as_deref(), Some("x"));
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
                // Vazio aqui de propósito: o teste fixa o formato no fio, e
                // atalhos ausentes não devem aparecer no JSON.
                shortcuts: Vec::new(),
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
                // Um computador de mesa sem GPU dedicada e sem sensor: as
                // medidas opcionais não aparecem no JSON, e é isso que este
                // teste fixa - elas viajam a cada 2 segundos, e cinco campos
                // nulos por leitura seriam peso puro.
                gpu_percent: None,
                gpu_name: None,
                temperature_celsius: None,
                network_rx_bps: 1_024,
                network_tx_bps: 512,
                battery_percent: None,
                on_battery: None,
            },
        })
        .unwrap();
        assert_eq!(
            json,
            r#"{"type":"system_stats","request_id":"r1","stats":{"cpu_percent":37.4,"memory_used":8000000000,"memory_total":16000000000,"disk_used":300000000000,"disk_total":500000000000,"disk_name":"C:","uptime_seconds":3600,"network_rx_bps":1024,"network_tx_bps":512}}"#
        );
    }

    #[test]
    fn system_stats_leva_as_medidas_novas_quando_existem() {
        // O outro lado do teste acima: num notebook com GPU, sensor e bateria,
        // os cinco campos precisam chegar ao app com o nome que ele espera.
        let json = serde_json::to_string(&ClientMessage::SystemStats {
            request_id: "r1".into(),
            stats: SystemSnapshot {
                cpu_percent: 10.0,
                memory_used: 1,
                memory_total: 2,
                disk_used: 1,
                disk_total: 2,
                disk_name: "C:".into(),
                uptime_seconds: 1,
                gpu_percent: Some(42.5),
                gpu_name: Some("Intel Iris Xe".into()),
                temperature_celsius: Some(51.2),
                network_rx_bps: 0,
                network_tx_bps: 0,
                battery_percent: Some(87),
                on_battery: Some(true),
            },
        })
        .unwrap();
        for campo in [
            r#""gpu_percent":42.5"#,
            r#""gpu_name":"Intel Iris Xe""#,
            r#""temperature_celsius":51.2"#,
            r#""battery_percent":87"#,
            r#""on_battery":true"#,
        ] {
            assert!(json.contains(campo), "faltou {campo} em {json}");
        }
    }
}
