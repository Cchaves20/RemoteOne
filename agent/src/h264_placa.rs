//! H.264 na placa de vídeo, no Windows, pelo Media Foundation.
//!
//! O openh264 codifica no processador e custa ~40 ms por quadro em 1280 px no
//! Dell de testes: a imagem fica presa em ~20 fps, e cada quadro chega com esse
//! atraso. As placas de vídeo (NVIDIA, Intel, AMD) têm um circuito só para isso,
//! e o Windows o oferece a qualquer programa como um "transform" do Media
//! Foundation. É o que se usa aqui, sem biblioteca de fabricante nenhum.
//!
//! ## Nunca pior que antes
//!
//! Tudo aqui pode falhar de jeitos que só aparecem numa máquina de verdade:
//! placa sem o circuito, driver velho, resolução que ele recusa. Por isso:
//!
//! - **Abrir falhou** → `abrir` devolve `None`, e o `h264::Encoder` usa o
//!   openh264, como sempre.
//! - **Codificar falhou no meio** → o `Encoder` troca para o openh264 na hora,
//!   e `desistir` impede tentar a placa de novo até o agente reiniciar.
//! - `DESKSIDE_VIDEO_ENCODER=cpu` na configuração força o openh264.
//!
//! O diário diz qual está em uso e, se a placa saiu, por quê.
//!
//! ## Como o transform funciona
//!
//! Os da placa são **assíncronos**: em vez de "entra um quadro, sai um
//! quadro", eles avisam por eventos quando querem um quadro novo
//! (`METransformNeedInput`) e quando há um codificado pronto
//! (`METransformHaveOutput`). Aqui o fluxo é mantido um-a-um — cada `encode`
//! entrega um quadro e espera o seu resultado, com prazo —, que é o que o
//! resto do agente espera. Com o modo de baixa latência ligado, a placa
//! devolve cada quadro antes de pedir o próximo.

use std::mem::ManuallyDrop;
use std::sync::atomic::{AtomicBool, Ordering};
use std::time::{Duration, Instant};

use windows::core::Interface;
use windows::Win32::Media::MediaFoundation::*;
use windows::Win32::System::Com::{CoInitializeEx, CoTaskMemFree, COINIT_MULTITHREADED};
use windows::Win32::System::Variant::{VARIANT, VT_BOOL, VT_UI4};

use crate::h264::EncodedFrame;

/// A placa falhou nesta execução: não tenta de novo até o agente reiniciar.
static DESISTIU: AtomicBool = AtomicBool::new(false);
/// O diário diz uma vez só qual codificador está em uso.
static AVISOU: AtomicBool = AtomicBool::new(false);

/// Quanto esperar a placa devolver um quadro. Bem acima dos poucos
/// milissegundos esperados, e bem abaixo do que se perceberia como trava.
const PRAZO: Duration = Duration::from_millis(200);

/// Abre o codificador da placa, ou `None` para usar o openh264.
pub fn abrir(largura: u32, altura: u32, fps: u32, taxa: u32) -> Option<Placa> {
    if DESISTIU.load(Ordering::Relaxed) {
        return None;
    }
    let cfg = crate::load_config();
    if crate::config::resolve(&cfg, "DESKSIDE_VIDEO_ENCODER")
        .is_some_and(|v| v.trim().eq_ignore_ascii_case("cpu"))
    {
        avisar_uma_vez("Vídeo: codificando no processador (DESKSIDE_VIDEO_ENCODER=cpu)");
        return None;
    }
    match Placa::new(largura, altura, fps, taxa) {
        Ok(placa) => {
            avisar_uma_vez(&format!("Vídeo: codificando na placa de vídeo ({})", placa.nome));
            Some(placa)
        }
        Err(e) => {
            desistir(&format!("não abriu: {e}"));
            None
        }
    }
}

/// A placa falhou: o openh264 assume, e ela não é tentada de novo.
pub fn desistir(motivo: &str) {
    if !DESISTIU.swap(true, Ordering::Relaxed) {
        crate::diario(&format!(
            "Vídeo: placa de vídeo fora ({motivo}); codificando no processador"
        ));
    }
}

fn avisar_uma_vez(texto: &str) {
    if !AVISOU.swap(true, Ordering::Relaxed) {
        crate::diario(texto);
    }
}

fn texto(e: windows::core::Error) -> String {
    format!("{e}")
}

/// O COM desta thread. A codificação roda em threads do `spawn_blocking` do
/// tokio, que mudam de um quadro para o outro; o transform foi criado no
/// modo multithread (MTA), que vale para todas elas, mas cada uma precisa
/// entrar nele. Chamar de novo numa thread que já entrou não custa nada.
fn com() {
    unsafe {
        let _ = CoInitializeEx(None, COINIT_MULTITHREADED);
    }
}

fn media_foundation() -> Result<(), String> {
    static INICIO: std::sync::OnceLock<Result<(), String>> = std::sync::OnceLock::new();
    INICIO
        .get_or_init(|| unsafe { MFStartup(MF_VERSION, MFSTARTUP_FULL) }.map_err(texto))
        .clone()
        .map_err(|e| format!("Media Foundation: {e}"))
}

fn numero(valor: u32) -> VARIANT {
    let mut v = VARIANT::default();
    unsafe {
        let dentro = &mut *v.Anonymous.Anonymous;
        dentro.vt = VT_UI4;
        dentro.Anonymous.ulVal = valor;
    }
    v
}

fn sim() -> VARIANT {
    let mut v = VARIANT::default();
    unsafe {
        let dentro = &mut *v.Anonymous.Anonymous;
        dentro.vt = VT_BOOL;
        dentro.Anonymous.boolVal = windows::Win32::Foundation::VARIANT_TRUE;
    }
    v
}

fn par(alto: u32, baixo: u32) -> u64 {
    ((alto as u64) << 32) | baixo as u64
}

/// O codificador da placa, aberto e configurado.
pub struct Placa {
    ativador: IMFActivate,
    mft: IMFTransform,
    /// Só nos transforms assíncronos (os de placa quase sempre são).
    eventos: Option<IMFMediaEventGenerator>,
    codec: Option<ICodecAPI>,
    entrada: u32,
    saida: u32,
    largura: u32,
    altura: u32,
    fps: u32,
    nv12: Vec<u8>,
    /// Pedidos de quadro (`METransformNeedInput`) ainda não atendidos.
    pedidos: u32,
    pede_chave: bool,
    /// SPS e PPS vistos, para quadros-chave que vierem sem eles.
    parametros: Vec<u8>,
    pub nome: String,
}

// Os objetos COM foram criados no modo multithread (MTA), em que valem em
// qualquer thread; e o `Encoder` que guarda isto vive atrás de um `Mutex`,
// então é usado por uma thread de cada vez.
unsafe impl Send for Placa {}

impl Placa {
    fn new(largura: u32, altura: u32, fps: u32, taxa: u32) -> Result<Self, String> {
        com();
        media_foundation()?;
        let mut ultimo_erro = "nenhum codificador H.264 de placa de vídeo".to_string();
        for ativador in candidatos()? {
            let nome = nome_de(&ativador);
            match Self::configurar(&ativador, &nome, largura, altura, fps, taxa) {
                Ok(placa) => return Ok(placa),
                Err(e) => {
                    ultimo_erro = format!("{nome}: {e}");
                    unsafe {
                        let _ = ativador.ShutdownObject();
                    }
                }
            }
        }
        Err(ultimo_erro)
    }

    fn configurar(
        ativador: &IMFActivate,
        nome: &str,
        largura: u32,
        altura: u32,
        fps: u32,
        taxa: u32,
    ) -> Result<Self, String> {
        let fps = fps.max(1);
        unsafe {
            let mft: IMFTransform = ativador.ActivateObject().map_err(texto)?;
            // Os assíncronos só aceitam ser usados depois deste destravamento.
            let atributos = mft.GetAttributes().ok();
            let assincrono = atributos
                .as_ref()
                .and_then(|a| a.GetUINT32(&MF_TRANSFORM_ASYNC).ok())
                .unwrap_or(0)
                == 1;
            if let Some(a) = &atributos {
                if assincrono {
                    a.SetUINT32(&MF_TRANSFORM_ASYNC_UNLOCK, 1).map_err(texto)?;
                }
            }

            // Fluxos de número fixo (0 e 0) devolvem "não implementado" aqui.
            let (mut entradas, mut saidas) = ([0u32], [0u32]);
            let (entrada, saida) = match mft.GetStreamIDs(&mut entradas, &mut saidas) {
                Ok(()) => (entradas[0], saidas[0]),
                Err(_) => (0, 0),
            };

            // Antes dos tipos: alguns só aceitam o modo de taxa nesta ordem.
            // Falhas aqui não impedem: cada placa aceita um subconjunto.
            let codec = mft.cast::<ICodecAPI>().ok();
            if let Some(c) = &codec {
                let _ = c.SetValue(&CODECAPI_AVLowLatencyMode, &sim());
                let _ = c.SetValue(
                    &CODECAPI_AVEncCommonRateControlMode,
                    &numero(eAVEncCommonRateControlMode_CBR.0 as u32),
                );
                let _ = c.SetValue(&CODECAPI_AVEncCommonMeanBitRate, &numero(taxa));
                // Sem quadros B: eles exigem esperar quadros futuros.
                let _ = c.SetValue(&CODECAPI_AVEncMPVDefaultBPictureCount, &numero(0));
                // Quadro-chave a cada ~10 s; fora isso, só quando o celular
                // pede (ver `request_keyframe`).
                let _ = c.SetValue(&CODECAPI_AVEncMPVGOPSize, &numero(fps * 10));
            }

            // Para codificadores, o tipo de saída vem antes do de entrada.
            let tipo_saida = MFCreateMediaType().map_err(texto)?;
            tipo_saida.SetGUID(&MF_MT_MAJOR_TYPE, &MFMediaType_Video).map_err(texto)?;
            tipo_saida.SetGUID(&MF_MT_SUBTYPE, &MFVideoFormat_H264).map_err(texto)?;
            tipo_saida.SetUINT32(&MF_MT_AVG_BITRATE, taxa).map_err(texto)?;
            tipo_saida
                .SetUINT64(&MF_MT_FRAME_SIZE, par(largura, altura))
                .map_err(texto)?;
            tipo_saida.SetUINT64(&MF_MT_FRAME_RATE, par(fps, 1)).map_err(texto)?;
            tipo_saida
                .SetUINT32(&MF_MT_INTERLACE_MODE, MFVideoInterlace_Progressive.0 as u32)
                .map_err(texto)?;
            tipo_saida
                .SetUINT64(&MF_MT_PIXEL_ASPECT_RATIO, par(1, 1))
                .map_err(texto)?;
            // Perfil básico: o mesmo do openh264 e o que o celular negocia.
            tipo_saida
                .SetUINT32(&MF_MT_MPEG2_PROFILE, eAVEncH264VProfile_Base.0 as u32)
                .map_err(texto)?;
            mft.SetOutputType(saida, &tipo_saida, 0)
                .map_err(|e| format!("tipo de saída recusado: {e}"))?;

            let tipo_entrada = MFCreateMediaType().map_err(texto)?;
            tipo_entrada.SetGUID(&MF_MT_MAJOR_TYPE, &MFMediaType_Video).map_err(texto)?;
            tipo_entrada.SetGUID(&MF_MT_SUBTYPE, &MFVideoFormat_NV12).map_err(texto)?;
            tipo_entrada
                .SetUINT64(&MF_MT_FRAME_SIZE, par(largura, altura))
                .map_err(texto)?;
            tipo_entrada.SetUINT64(&MF_MT_FRAME_RATE, par(fps, 1)).map_err(texto)?;
            tipo_entrada
                .SetUINT32(&MF_MT_INTERLACE_MODE, MFVideoInterlace_Progressive.0 as u32)
                .map_err(texto)?;
            tipo_entrada
                .SetUINT64(&MF_MT_PIXEL_ASPECT_RATIO, par(1, 1))
                .map_err(texto)?;
            tipo_entrada.SetUINT32(&MF_MT_DEFAULT_STRIDE, largura).map_err(texto)?;
            mft.SetInputType(entrada, &tipo_entrada, 0)
                .map_err(|e| format!("tipo de entrada recusado: {e}"))?;

            let eventos = if assincrono {
                Some(mft.cast::<IMFMediaEventGenerator>().map_err(texto)?)
            } else {
                None
            };
            mft.ProcessMessage(MFT_MESSAGE_NOTIFY_BEGIN_STREAMING, 0)
                .map_err(texto)?;
            mft.ProcessMessage(MFT_MESSAGE_NOTIFY_START_OF_STREAM, 0)
                .map_err(texto)?;

            Ok(Self {
                ativador: ativador.clone(),
                mft,
                eventos,
                codec,
                entrada,
                saida,
                largura,
                altura,
                fps,
                nv12: Vec::new(),
                pedidos: 0,
                pede_chave: true,
                parametros: Vec::new(),
                nome: nome.to_string(),
            })
        }
    }

    pub fn request_keyframe(&mut self) {
        self.pede_chave = true;
    }

    /// Codifica um quadro RGB. Devolve vazio se a placa ainda não entregou
    /// (o próximo `encode` traz o atrasado junto).
    pub fn encode(
        &mut self,
        rgb: &[u8],
        largura: u32,
        altura: u32,
        decorrido: Duration,
    ) -> Result<EncodedFrame, String> {
        if (largura, altura) != (self.largura, self.altura) {
            return Err("tamanho do quadro mudou".to_string());
        }
        com();
        crate::h264::rgb_para_nv12(rgb, largura as usize, altura as usize, &mut self.nv12);
        let amostra = self.amostra(decorrido)?;
        if std::mem::take(&mut self.pede_chave) {
            if let Some(c) = &self.codec {
                unsafe {
                    let _ = c.SetValue(&CODECAPI_AVEncVideoForceKeyFrame, &numero(1));
                }
            }
        }
        let mut prontos = Vec::new();
        match self.eventos.clone() {
            Some(eventos) => self.encode_assincrono(&eventos, &amostra, &mut prontos)?,
            None => self.encode_sincrono(&amostra, &mut prontos)?,
        }
        let mut dados = Vec::new();
        let mut chave = false;
        for (bytes, eh_chave) in prontos {
            dados.extend_from_slice(&bytes);
            chave |= eh_chave;
        }
        let dados = crate::h264::com_parametros(dados, &mut self.parametros);
        let chave = chave || crate::h264::unidades(&dados).iter().any(|(t, _)| *t == 5);
        Ok(EncodedFrame {
            data: dados,
            keyframe: chave,
        })
    }

    fn amostra(&self, decorrido: Duration) -> Result<IMFSample, String> {
        unsafe {
            let tamanho = self.nv12.len() as u32;
            let buffer = MFCreateMemoryBuffer(tamanho).map_err(texto)?;
            let mut destino: *mut u8 = std::ptr::null_mut();
            buffer.Lock(&mut destino, None, None).map_err(texto)?;
            std::ptr::copy_nonoverlapping(self.nv12.as_ptr(), destino, self.nv12.len());
            buffer.Unlock().map_err(texto)?;
            buffer.SetCurrentLength(tamanho).map_err(texto)?;
            let amostra = MFCreateSample().map_err(texto)?;
            amostra.AddBuffer(&buffer).map_err(texto)?;
            // Em unidades de 100 ns.
            amostra
                .SetSampleTime((decorrido.as_nanos() / 100) as i64)
                .map_err(texto)?;
            amostra
                .SetSampleDuration(10_000_000 / self.fps as i64)
                .map_err(texto)?;
            Ok(amostra)
        }
    }

    fn encode_assincrono(
        &mut self,
        eventos: &IMFMediaEventGenerator,
        amostra: &IMFSample,
        prontos: &mut Vec<(Vec<u8>, bool)>,
    ) -> Result<(), String> {
        let prazo = Instant::now() + PRAZO;
        // Espera a placa pedir um quadro, recolhendo o que ela entregar antes.
        while self.pedidos == 0 {
            match proximo_evento(eventos, prazo)? {
                Some(tipo) if tipo == METransformNeedInput.0 as u32 => self.pedidos += 1,
                Some(tipo) if tipo == METransformHaveOutput.0 as u32 => {
                    if let Some(q) = self.tirar()? {
                        prontos.push(q);
                    }
                }
                Some(_) => {}
                None => return Err("a placa parou de pedir quadros".to_string()),
            }
        }
        unsafe {
            self.mft
                .ProcessInput(self.entrada, amostra, 0)
                .map_err(texto)?;
        }
        self.pedidos -= 1;
        // E espera o resultado deste quadro.
        let prazo = Instant::now() + PRAZO;
        loop {
            match proximo_evento(eventos, prazo)? {
                Some(tipo) if tipo == METransformHaveOutput.0 as u32 => {
                    if let Some(q) = self.tirar()? {
                        prontos.push(q);
                    }
                    return Ok(());
                }
                Some(tipo) if tipo == METransformNeedInput.0 as u32 => self.pedidos += 1,
                Some(_) => {}
                // Não veio a tempo: segue, e o atrasado sai no próximo.
                None => return Ok(()),
            }
        }
    }

    fn encode_sincrono(
        &mut self,
        amostra: &IMFSample,
        prontos: &mut Vec<(Vec<u8>, bool)>,
    ) -> Result<(), String> {
        unsafe {
            self.mft
                .ProcessInput(self.entrada, amostra, 0)
                .map_err(texto)?;
        }
        while let Some(q) = self.tirar()? {
            prontos.push(q);
        }
        Ok(())
    }

    /// Recolhe um quadro codificado: `(bytes, é quadro-chave)`, ou `None` se
    /// não havia.
    fn tirar(&mut self) -> Result<Option<(Vec<u8>, bool)>, String> {
        unsafe {
            let info = self.mft.GetOutputStreamInfo(self.saida).map_err(texto)?;
            let da_placa = info.dwFlags & MFT_OUTPUT_STREAM_PROVIDES_SAMPLES.0 as u32 != 0;
            let nossa = if da_placa {
                None
            } else {
                let buffer = MFCreateMemoryBuffer(info.cbSize.max(1024 * 1024)).map_err(texto)?;
                let amostra = MFCreateSample().map_err(texto)?;
                amostra.AddBuffer(&buffer).map_err(texto)?;
                Some(amostra)
            };
            let mut saida = [MFT_OUTPUT_DATA_BUFFER {
                dwStreamID: self.saida,
                pSample: ManuallyDrop::new(nossa),
                dwStatus: 0,
                pEvents: ManuallyDrop::new(None),
            }];
            let mut estado = 0u32;
            let resultado = self.mft.ProcessOutput(0, &mut saida, &mut estado);
            let amostra = ManuallyDrop::take(&mut saida[0].pSample);
            drop(ManuallyDrop::take(&mut saida[0].pEvents));
            match resultado {
                Ok(()) => {}
                Err(e) if e.code() == MF_E_TRANSFORM_NEED_MORE_INPUT => return Ok(None),
                // A placa mudou o formato da saída (raro; alguns drivers fazem
                // na largada): aceita o novo e segue.
                Err(e) if e.code() == MF_E_TRANSFORM_STREAM_CHANGE => {
                    let novo = self
                        .mft
                        .GetOutputAvailableType(self.saida, 0)
                        .map_err(texto)?;
                    self.mft.SetOutputType(self.saida, &novo, 0).map_err(texto)?;
                    return Ok(None);
                }
                Err(e) => return Err(texto(e)),
            }
            let Some(amostra) = amostra else {
                return Ok(None);
            };
            let chave = amostra
                .GetUINT32(&MFSampleExtension_CleanPoint)
                .unwrap_or(0)
                == 1;
            let buffer = amostra.ConvertToContiguousBuffer().map_err(texto)?;
            let mut origem: *mut u8 = std::ptr::null_mut();
            let mut tamanho = 0u32;
            buffer
                .Lock(&mut origem, None, Some(&mut tamanho))
                .map_err(texto)?;
            let bytes = std::slice::from_raw_parts(origem, tamanho as usize).to_vec();
            buffer.Unlock().map_err(texto)?;
            Ok(Some((bytes, chave)))
        }
    }
}

impl Drop for Placa {
    fn drop(&mut self) {
        com();
        unsafe {
            let _ = self.mft.ProcessMessage(MFT_MESSAGE_NOTIFY_END_OF_STREAM, 0);
            let _ = self.mft.ProcessMessage(MFT_MESSAGE_NOTIFY_END_STREAMING, 0);
            let _ = self.ativador.ShutdownObject();
        }
    }
}

/// O próximo evento do transform, esperando até `prazo`. `None` se não veio.
fn proximo_evento(eventos: &IMFMediaEventGenerator, prazo: Instant) -> Result<Option<u32>, String> {
    loop {
        match unsafe { eventos.GetEvent(MF_EVENT_FLAG_NO_WAIT) } {
            Ok(evento) => return unsafe { evento.GetType() }.map(Some).map_err(texto),
            Err(e) if e.code() == MF_E_NO_EVENTS_AVAILABLE => {
                if Instant::now() >= prazo {
                    return Ok(None);
                }
                std::thread::sleep(Duration::from_millis(1));
            }
            Err(e) => return Err(texto(e)),
        }
    }
}

/// Os codificadores H.264 de placa de vídeo deste computador, do preferido
/// pelo Windows ao último.
fn candidatos() -> Result<Vec<IMFActivate>, String> {
    let entrada = MFT_REGISTER_TYPE_INFO {
        guidMajorType: MFMediaType_Video,
        guidSubtype: MFVideoFormat_NV12,
    };
    let saida = MFT_REGISTER_TYPE_INFO {
        guidMajorType: MFMediaType_Video,
        guidSubtype: MFVideoFormat_H264,
    };
    let mut lista: *mut Option<IMFActivate> = std::ptr::null_mut();
    let mut quantos = 0u32;
    unsafe {
        MFTEnumEx(
            MFT_CATEGORY_VIDEO_ENCODER,
            MFT_ENUM_FLAG_HARDWARE | MFT_ENUM_FLAG_SORTANDFILTER,
            Some(&entrada),
            Some(&saida),
            &mut lista,
            &mut quantos,
        )
        .map_err(texto)?;
        if lista.is_null() {
            return Ok(Vec::new());
        }
        let ativadores = std::slice::from_raw_parts_mut(lista, quantos as usize)
            .iter_mut()
            .filter_map(Option::take)
            .collect();
        CoTaskMemFree(Some(lista as *const _));
        Ok(ativadores)
    }
}

/// O nome que o fabricante deu ao codificador, para o diário.
fn nome_de(ativador: &IMFActivate) -> String {
    unsafe {
        let mut texto = windows::core::PWSTR::null();
        let mut tamanho = 0u32;
        if ativador
            .GetAllocatedString(&MFT_FRIENDLY_NAME_Attribute, &mut texto, &mut tamanho)
            .is_err()
        {
            return "codificador da placa".to_string();
        }
        let nome = texto.to_string().unwrap_or_default();
        CoTaskMemFree(Some(texto.0 as *const _));
        nome
    }
}
