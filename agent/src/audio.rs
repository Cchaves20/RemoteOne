//! Som do computador indo para o telefone.
//!
//! O caminho é o mesmo do vídeo: captura → Opus → faixa de áudio da conexão
//! WebRTC já existente. Só isso permite ouvir no celular sem plugin nenhum: o
//! Opus é obrigatório em WebRTC, e o app toca a faixa que chega sem precisar de
//! um tocador próprio.
//!
//! O que o Windows entrega (o "loopback" da placa de som) quase nunca é o que o
//! Opus aceita: vem na taxa da placa, com o número de canais dela, em blocos de
//! tamanho arbitrário. O [`Shaper`] resolve isso e é **puro** — roda e é testado
//! em qualquer sistema. A captura em si e o codificador são só do Windows.

use std::time::Duration;

/// Taxa de amostragem enviada. 48 kHz é o que o Opus usa internamente e o que a
/// placa de som do Windows entrega na maioria das máquinas.
pub const SAMPLE_RATE: u32 = 48_000;

/// Dois canais: o que se está mandando é música e vídeo, não voz.
pub const CHANNELS: usize = 2;

/// Duração de um quadro. 20 ms é o padrão do WebRTC: menos aumenta o custo por
/// byte de cabeçalho, mais aumenta a latência.
pub const FRAME: Duration = Duration::from_millis(20);

/// Amostras por canal em um quadro (48 000 / 1000 × 20).
pub const FRAME_SAMPLES: usize = 960;

/// Amostras intercaladas em um quadro (os dois canais).
pub const FRAME_INTERLEAVED: usize = FRAME_SAMPLES * CHANNELS;

/// Ganho aplicado ao som antes de codificar, compartilhado com a thread da
/// placa de som.
///
/// Existe para uma ideia simples: deixar o computador quase mudo (volume no
/// mínimo, **sem** silenciar) e recuperar o volume no telefone. O Windows
/// aplica o volume mestre na mistura que o loopback entrega, então o que se
/// captura de um computador baixinho é um sinal baixinho; multiplicar por 20
/// devolve o que se esperava ouvir.
///
/// **Antes** de codificar, e isso não é detalhe: o Opus distribui o ruído de
/// codificação em proporção ao sinal que recebe. Mandar um sinal fraquinho e
/// amplificar no telefone amplificaria o ruído junto, e o resultado seria um
/// chiado. Amplificando aqui, o codificador vê um sinal de nível normal.
///
/// `f32` guardado como bits num atômico: a thread da placa não pode esperar
/// por cadeado nenhum.
#[derive(Debug)]
pub struct Gain(std::sync::atomic::AtomicU32);

impl Gain {
    /// Teto de 32x (+30 dB). Acima disso o que se amplifica já é mais ruído do
    /// que som, e uma mensagem adulterada não pode estourar o alto-falante.
    pub const MAX: f32 = 32.0;

    pub fn new(value: f32) -> Self {
        let gain = Self(std::sync::atomic::AtomicU32::new(0));
        gain.set(value);
        gain
    }

    pub fn set(&self, value: f32) {
        let limitado = if value.is_finite() {
            value.clamp(0.0, Self::MAX)
        } else {
            1.0
        };
        self.0
            .store(limitado.to_bits(), std::sync::atomic::Ordering::Relaxed);
    }

    pub fn get(&self) -> f32 {
        f32::from_bits(self.0.load(std::sync::atomic::Ordering::Relaxed))
    }
}

/// Multiplica as amostras pelo ganho, cortando o que passar do limite.
///
/// Devolve `true` se algo foi cortado. O corte é seco, e é a escolha certa
/// aqui: um limitador suave disfarçaria o excesso, e o que se quer é que a
/// pessoa perceba que o ganho está alto demais para o volume do computador.
pub fn apply_gain(samples: &mut [f32], gain: f32) -> bool {
    if gain == 1.0 {
        return false;
    }
    let mut clipped = false;
    for s in samples.iter_mut() {
        let amplificado = *s * gain;
        if amplificado > 1.0 {
            *s = 1.0;
            clipped = true;
        } else if amplificado < -1.0 {
            *s = -1.0;
            clipped = true;
        } else {
            *s = amplificado;
        }
    }
    clipped
}

/// Quadros de som que a rede não deu conta de levar.
///
/// A thread da placa nunca espera: quando o canal está cheio, o quadro é
/// descartado. Sem contar isso, "o som está picotando" não tem como virar
/// diagnóstico - o descarte aqui e a perda no caminho até o telefone produzem
/// exatamente o mesmo sintoma, e a correção de cada um é diferente.
pub static DROPPED: std::sync::atomic::AtomicU64 = std::sync::atomic::AtomicU64::new(0);

/// Quantos quadros foram descartados desde a última pergunta (e zera).
pub fn take_dropped() -> u64 {
    DROPPED.swap(0, std::sync::atomic::Ordering::Relaxed)
}

/// Um quadro já codificado, pronto para a faixa de áudio.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Packet {
    pub data: Vec<u8>,
    pub duration: Duration,
}

/// Converte o que a placa de som entrega no que o Opus aceita: 48 kHz, dois
/// canais, em quadros de 20 ms exatos.
///
/// Guarda estado entre um bloco e outro de propósito. Os blocos chegam com
/// tamanhos irregulares, e tratar cada um isoladamente produziria um estalo na
/// emenda (o reamostrador precisa da última amostra do bloco anterior) e um
/// quadro incompleto no fim (o Opus recusa quadros de tamanho errado).
pub struct Shaper {
    input_rate: u32,
    input_channels: usize,
    /// Quantos quadros de entrada cabem em um de saída.
    ratio: f64,
    /// Posição do próximo quadro de saída, em quadros de entrada, contada a
    /// partir do início do bloco atual. Pode ser negativa: aí a amostra vem do
    /// bloco anterior (`prev`).
    pos: f64,
    /// Último quadro do bloco anterior (esquerdo, direito).
    prev: [f32; CHANNELS],
    /// Amostras já em 48 kHz que ainda não completaram um quadro.
    pending: Vec<f32>,
}

impl Shaper {
    /// `channels` é o número de canais da **entrada**; a saída é sempre estéreo.
    pub fn new(input_rate: u32, input_channels: usize) -> Self {
        let canais = input_channels.max(1);
        Self {
            input_rate,
            input_channels: canais,
            ratio: input_rate as f64 / SAMPLE_RATE as f64,
            pos: 0.0,
            prev: [0.0; CHANNELS],
            pending: Vec::with_capacity(FRAME_INTERLEAVED * 2),
        }
    }

    /// Se a entrada já está do jeito que o Opus quer (aí o caminho é uma cópia).
    pub fn passthrough(&self) -> bool {
        self.input_rate == SAMPLE_RATE && self.input_channels == CHANNELS
    }

    /// Empurra um bloco de amostras intercaladas e acrescenta a `out` os
    /// **quadros completos** que saírem. O resto fica guardado para a próxima.
    pub fn push(&mut self, input: &[f32], out: &mut Vec<f32>) {
        let canais = self.input_channels;
        let quadros = input.len() / canais;
        if quadros == 0 {
            return;
        }

        // Cópia local do quadro anterior: a função abaixo não pode segurar um
        // empréstimo de `self`, porque o laço mexe em `self.pending`.
        let prev = self.prev;
        // Pega um quadro da entrada já reduzido a estéreo. Índice -1 é o último
        // quadro do bloco anterior.
        let frame = |i: isize| -> [f32; CHANNELS] {
            if i < 0 {
                return prev;
            }
            let base = (i as usize) * canais;
            let esquerdo = input[base];
            // Mono vira estéreo repetindo; 5.1 e afins ficam nos dois primeiros
            // canais, que no Windows são justamente esquerdo e direito.
            let direito = if canais > 1 { input[base + 1] } else { esquerdo };
            [esquerdo, direito]
        };

        while self.pos < quadros as f64 {
            let i = self.pos.floor();
            let frac = (self.pos - i) as f32;
            let a = frame(i as isize);
            let proximo = i as isize + 1;
            // No último quadro do bloco não há "próximo" ainda: segura o valor.
            // O erro é de uma amostra e some na emenda com o bloco seguinte.
            let b = if (proximo as usize) < quadros {
                frame(proximo)
            } else {
                a
            };
            self.pending.push(a[0] + (b[0] - a[0]) * frac);
            self.pending.push(a[1] + (b[1] - a[1]) * frac);
            self.pos += self.ratio;
        }
        // Rebase para o próximo bloco: o que sobrou de `pos` continua valendo.
        self.pos -= quadros as f64;
        self.prev = frame(quadros as isize - 1);

        let completos = self.pending.len() / FRAME_INTERLEAVED * FRAME_INTERLEAVED;
        if completos > 0 {
            out.extend_from_slice(&self.pending[..completos]);
            self.pending.drain(..completos);
        }
    }
}

#[cfg(windows)]
mod imp {
    use std::sync::atomic::{AtomicBool, Ordering};
    use std::sync::Arc;
    use std::time::Duration;

    use audiopus::coder::Encoder;
    use audiopus::{Application, Bitrate, Channels, SampleRate};
    use cpal::traits::{DeviceTrait, HostTrait, StreamTrait};

    use super::{Packet, Shaper, FRAME, FRAME_INTERLEAVED};

    /// 96 kbps em estéreo: transparente o bastante para música e barato o
    /// bastante para 4G. O vídeo, ao lado, usa muito mais que isso.
    const BITRATE: i32 = 96_000;

    /// Captura em curso. Cair fora de escopo para a captura.
    pub struct Capture {
        stop: Arc<AtomicBool>,
        thread: Option<std::thread::JoinHandle<()>>,
    }

    impl Drop for Capture {
        fn drop(&mut self) {
            self.stop.store(true, Ordering::Relaxed);
            if let Some(t) = self.thread.take() {
                let _ = t.join();
            }
        }
    }

    /// Liga a captura do som que **sai** pelo alto-falante.
    ///
    /// A thread própria não é enfeite: o fluxo do WASAPI não é `Send`, então
    /// precisa nascer e morrer na mesma thread. Ela fica parada esperando o
    /// sinal de desligar - quem trabalha é a chamada de retorno da placa.
    pub fn start(
        tx: tokio::sync::mpsc::Sender<Packet>,
        gain: Arc<super::Gain>,
    ) -> Result<Capture, String> {
        let stop = Arc::new(AtomicBool::new(false));
        let sinal = Arc::clone(&stop);
        let (pronto_tx, pronto_rx) = std::sync::mpsc::channel::<Result<(), String>>();

        let thread = std::thread::spawn(move || match build_stream(tx, gain) {
            Err(e) => {
                let _ = pronto_tx.send(Err(e));
            }
            Ok(stream) => {
                let _ = pronto_tx.send(Ok(()));
                while !sinal.load(Ordering::Relaxed) {
                    std::thread::sleep(Duration::from_millis(100));
                }
                drop(stream);
            }
        });

        match pronto_rx.recv_timeout(Duration::from_secs(5)) {
            Ok(Ok(())) => Ok(Capture {
                stop,
                thread: Some(thread),
            }),
            Ok(Err(e)) => Err(e),
            Err(_) => Err("a placa de som não respondeu".to_string()),
        }
    }

    fn build_stream(
        tx: tokio::sync::mpsc::Sender<Packet>,
        gain: Arc<super::Gain>,
    ) -> Result<cpal::Stream, String> {
        let host = cpal::default_host();
        // O truque do loopback: **abrir o dispositivo de saída como entrada**.
        // O cpal liga o AUDCLNT_STREAMFLAGS_LOOPBACK sozinho nesse caso, e o
        // que chega é a mistura que iria para o alto-falante.
        let device = host
            .default_output_device()
            .ok_or("nenhum dispositivo de som encontrado")?;
        let suportado = device
            .default_output_config()
            .map_err(|e| format!("configuração de som: {e}"))?;

        if suportado.sample_format() != cpal::SampleFormat::F32 {
            // O modo compartilhado do WASAPI mistura em float; qualquer outra
            // coisa é fora do comum, e um palpite errado aqui viraria ruído.
            return Err(format!(
                "formato de som não suportado: {:?}",
                suportado.sample_format()
            ));
        }

        let taxa = suportado.sample_rate();
        let canais = suportado.channels() as usize;
        println!("Áudio: capturando a {taxa} Hz, {canais} canal(is)");

        let mut shaper = Shaper::new(taxa, canais);
        let encoder = Encoder::new(SampleRate::Hz48000, Channels::Stereo, Application::Audio)
            .map_err(|e| format!("codificador Opus: {e}"))?;
        let mut encoder = encoder;
        encoder
            .set_bitrate(Bitrate::BitsPerSecond(BITRATE))
            .map_err(|e| format!("taxa do Opus: {e}"))?;
        // Correção de erro embutida. O SDP já anunciava `useinbandfec=1` e o
        // codificador nunca a ligava - anunciar sem produzir é pior do que não
        // anunciar: o telefone conta com uma recuperação que não existe.
        //
        // Com ela, cada quadro leva uma versão comprimida do anterior, e um
        // pacote perdido é reconstruído em vez de virar buraco. Custa uns
        // poucos kbps e é exatamente o que falta numa rede móvel passando por
        // relay, onde perder pacote é rotina.
        encoder
            .set_inband_fec(true)
            .map_err(|e| format!("FEC do Opus: {e}"))?;
        // A perda que o codificador deve *supor*. Zero desliga a FEC na
        // prática; 10% é o meio-termo usado em telefonia móvel - protege sem
        // gastar metade da banda com redundância.
        encoder
            .set_packet_loss_perc(10)
            .map_err(|e| format!("perda esperada do Opus: {e}"))?;
        // Complexidade 5 em vez do padrão 10. A codificação roda na thread da
        // placa de som, que tem prazo de milissegundos: estourá-lo faz o
        // Windows descartar o bloco, e o que se ouve é picote. A 96 kbps
        // estéreo a diferença de qualidade entre 5 e 10 é inaudível; a de
        // custo de CPU é de duas a três vezes - e esta máquina está
        // codificando vídeo 1080p ao mesmo tempo.
        encoder
            .set_complexity(5)
            .map_err(|e| format!("complexidade do Opus: {e}"))?;

        let mut quadros: Vec<f32> = Vec::with_capacity(FRAME_INTERLEAVED * 4);
        // Um aviso por captura: um por bloco encheria o console 50 vezes por
        // segundo, que é ruído, não informação.
        let mut avisou_corte = false;
        // Teto folgado para um quadro de 20 ms a 96 kbps (~240 bytes).
        let mut saida = vec![0u8; 4000];

        let stream = device
            .build_input_stream(
                suportado.config(),
                move |data: &[f32], _: &cpal::InputCallbackInfo| {
                    shaper.push(data, &mut quadros);
                    // O ganho é lido a cada bloco: mexer no controle do
                    // telefone tem efeito imediato, sem reabrir a captura.
                    if super::apply_gain(&mut quadros, gain.get()) && !avisou_corte {
                        avisou_corte = true;
                        eprintln!(
                            "Áudio: o ganho está alto demais para o volume do \
                             computador e o som está sendo cortado."
                        );
                    }
                    for quadro in quadros.chunks_exact(FRAME_INTERLEAVED) {
                        match encoder.encode_float(quadro, &mut saida) {
                            Ok(n) => {
                                // `try_send`, nunca `send`: esta é a thread da
                                // placa de som. Bloquear aqui engasga o áudio
                                // do computador inteiro - melhor perder um
                                // quadro quando a rede não acompanha.
                                if tx
                                    .try_send(Packet {
                                        data: saida[..n].to_vec(),
                                        duration: FRAME,
                                    })
                                    .is_err()
                                {
                                    super::DROPPED
                                        .fetch_add(1, std::sync::atomic::Ordering::Relaxed);
                                }
                            }
                            Err(e) => eprintln!("Falha ao codificar áudio: {e}"),
                        }
                    }
                    quadros.clear();
                },
                |e| eprintln!("Erro no fluxo de áudio: {e}"),
                None,
            )
            .map_err(|e| format!("não consegui abrir o som: {e}"))?;

        stream.play().map_err(|e| format!("som parado: {e}"))?;
        Ok(stream)
    }
}

#[cfg(not(windows))]
mod imp {
    use super::Packet;

    /// Sem captura fora do Windows (é a única plataforma com agente real).
    pub struct Capture;

    pub fn start(
        _tx: tokio::sync::mpsc::Sender<Packet>,
        _gain: std::sync::Arc<super::Gain>,
    ) -> Result<Capture, String> {
        Err("captura de som só no Windows".to_string())
    }
}

pub use imp::{start, Capture};

#[cfg(test)]
mod tests {
    use super::*;

    /// Um bloco de `frames` quadros com um valor por canal, para conferir de
    /// onde cada amostra veio.
    fn bloco(frames: usize, canais: usize) -> Vec<f32> {
        let mut v = Vec::with_capacity(frames * canais);
        for i in 0..frames {
            for c in 0..canais {
                v.push(i as f32 + c as f32 / 10.0);
            }
        }
        v
    }

    #[test]
    fn ja_na_taxa_certa_o_som_passa_igual() {
        let mut shaper = Shaper::new(48_000, 2);
        assert!(shaper.passthrough());
        let entrada = bloco(FRAME_SAMPLES, 2);
        let mut saida = Vec::new();
        shaper.push(&entrada, &mut saida);
        assert_eq!(saida.len(), FRAME_INTERLEAVED);
        // Sem reamostragem, as amostras têm que ser as mesmas - qualquer
        // "quase igual" aqui seria distorção introduzida à toa.
        assert_eq!(saida[0], 0.0);
        assert_eq!(saida[1], 0.1);
        assert_eq!(saida[2], 1.0);
    }

    #[test]
    fn quadro_incompleto_espera_o_proximo_bloco() {
        // A placa entrega blocos de tamanho arbitrário; o Opus só aceita
        // quadros exatos. Meio quadro não pode virar quadro.
        let mut shaper = Shaper::new(48_000, 2);
        let mut saida = Vec::new();
        shaper.push(&bloco(FRAME_SAMPLES / 2, 2), &mut saida);
        assert!(saida.is_empty(), "meio quadro não devia sair");
        shaper.push(&bloco(FRAME_SAMPLES / 2, 2), &mut saida);
        assert_eq!(saida.len(), FRAME_INTERLEAVED);
    }

    #[test]
    fn bloco_grande_vira_varios_quadros() {
        let mut shaper = Shaper::new(48_000, 2);
        let mut saida = Vec::new();
        shaper.push(&bloco(FRAME_SAMPLES * 3, 2), &mut saida);
        assert_eq!(saida.len(), FRAME_INTERLEAVED * 3);
    }

    #[test]
    fn mono_vira_estereo() {
        // Placa mono existe, e mandar um canal só onde o Opus espera dois
        // faria o som sair pela metade (ou virar ruído).
        let mut shaper = Shaper::new(48_000, 1);
        assert!(!shaper.passthrough());
        let mut saida = Vec::new();
        shaper.push(&bloco(FRAME_SAMPLES, 1), &mut saida);
        assert_eq!(saida.len(), FRAME_INTERLEAVED);
        assert_eq!(saida[0], saida[1], "os dois canais deviam ser iguais");
        assert_eq!(saida[2], saida[3]);
    }

    #[test]
    fn cinco_pontos_um_fica_nos_dois_primeiros_canais() {
        let mut shaper = Shaper::new(48_000, 6);
        let mut saida = Vec::new();
        shaper.push(&bloco(FRAME_SAMPLES, 6), &mut saida);
        assert_eq!(saida.len(), FRAME_INTERLEAVED);
        assert_eq!(saida[0], 0.0);
        assert_eq!(saida[1], 0.1);
    }

    #[test]
    fn quarenta_e_quatro_vira_quarenta_e_oito() {
        // 44,1 kHz é a outra taxa comum. Sem reamostrar, o Opus recusaria o
        // quadro - e se aceitasse, o som sairia com o tom errado.
        let mut shaper = Shaper::new(44_100, 2);
        assert!(!shaper.passthrough());
        let mut saida = Vec::new();
        // Um segundo de som: 44 100 quadros de entrada devem virar ~48 000 de
        // saída (só saem os quadros completos, então o resto fica guardado).
        shaper.push(&bloco(44_100, 2), &mut saida);
        let quadros_saida = saida.len() / CHANNELS;
        assert!(
            (47_000..=48_000).contains(&quadros_saida),
            "esperava ~48 000 quadros, saíram {quadros_saida}"
        );
    }

    #[test]
    fn a_reamostragem_continua_entre_blocos() {
        // O erro clássico: reiniciar a fase a cada bloco, o que faz o som
        // ganhar um estalo periódico. Dois blocos seguidos têm que render o
        // mesmo total que um bloco do dobro do tamanho.
        let mut um = Shaper::new(44_100, 2);
        let mut a = Vec::new();
        um.push(&bloco(1000, 2), &mut a);
        um.push(&bloco(1000, 2), &mut a);

        let mut outro = Shaper::new(44_100, 2);
        let mut b = Vec::new();
        outro.push(&bloco(2000, 2), &mut b);

        assert_eq!(a.len(), b.len());
    }

    #[test]
    fn bloco_vazio_nao_quebra() {
        let mut shaper = Shaper::new(48_000, 2);
        let mut saida = Vec::new();
        shaper.push(&[], &mut saida);
        assert!(saida.is_empty());
    }

    #[test]
    fn ganho_neutro_nao_toca_no_som() {
        let mut som = vec![0.5, -0.25, 0.125];
        assert!(!apply_gain(&mut som, 1.0));
        assert_eq!(som, vec![0.5, -0.25, 0.125]);
    }

    #[test]
    fn ganho_amplifica_o_computador_baixinho() {
        // O caso de uso: computador no volume mínimo, telefone no volume certo.
        let mut som = vec![0.02, -0.02];
        assert!(!apply_gain(&mut som, 20.0));
        assert!((som[0] - 0.4).abs() < 1e-6, "{som:?}");
        assert!((som[1] + 0.4).abs() < 1e-6, "{som:?}");
    }

    #[test]
    fn ganho_alto_demais_corta_e_avisa() {
        // Sem o corte, o valor passaria de 1.0 e o Opus receberia lixo.
        let mut som = vec![0.5, -0.5, 0.1];
        assert!(apply_gain(&mut som, 4.0), "devia avisar o corte");
        assert_eq!(som[0], 1.0);
        assert_eq!(som[1], -1.0);
        assert!((som[2] - 0.4).abs() < 1e-6);
    }

    #[test]
    fn ganho_zero_silencia() {
        let mut som = vec![0.9, -0.9];
        assert!(!apply_gain(&mut som, 0.0));
        assert_eq!(som, vec![0.0, -0.0]);
    }

    #[test]
    fn ganho_recusa_valor_impossivel() {
        // Mensagem adulterada não pode virar estouro no ouvido de ninguém.
        let g = Gain::new(1.0);
        g.set(1000.0);
        assert_eq!(g.get(), Gain::MAX);
        g.set(-5.0);
        assert_eq!(g.get(), 0.0);
        g.set(f32::NAN);
        assert_eq!(g.get(), 1.0);
        g.set(3.5);
        assert_eq!(g.get(), 3.5);
    }

    #[test]
    fn um_quadro_tem_vinte_milissegundos() {
        // Se estes números discordarem, o áudio chega com o relógio errado e
        // o app o toca acelerado ou lento.
        assert_eq!(FRAME_SAMPLES as u32 * 1000 / SAMPLE_RATE, FRAME.as_millis() as u32);
        assert_eq!(FRAME_INTERLEAVED, FRAME_SAMPLES * CHANNELS);
    }
}
