//! O codificador Opus do Mac, sem C nenhum.
//!
//! No Windows o Opus vem pronto do `audiopus`. No Mac aquele pacote compila o
//! libopus com autotools, e não para as duas arquiteturas do pacote universal
//! (Apple Silicon e Intel) de uma vez. O `unsafe-libopus` é o **mesmo** libopus
//! 1.3.1, convertido do C para Rust: compila como qualquer código Rust, para
//! qualquer processador, e por isso também é testado aqui, no Linux.
//!
//! As escolhas de codificação são as do Windows (ver `audio.rs`): 96 kbps em
//! estéreo, correção de erro embutida supondo 10% de perda, complexidade 5.

use unsafe_libopus::{
    opus_encode_float, opus_encoder_create, opus_encoder_ctl, opus_encoder_destroy, OpusEncoder,
    OPUS_APPLICATION_AUDIO, OPUS_SET_BITRATE_REQUEST, OPUS_SET_COMPLEXITY_REQUEST,
    OPUS_SET_INBAND_FEC_REQUEST, OPUS_SET_PACKET_LOSS_PERC_REQUEST,
};

use crate::audio::{CHANNELS, FRAME_INTERLEAVED, SAMPLE_RATE};

/// 96 kbps em estéreo, como no Windows.
const BITRATE: i32 = 96_000;

/// Um codificador Opus para quadros de 20 ms em 48 kHz estéreo.
pub struct Codificador {
    estado: *mut OpusEncoder,
}

// O codificador é só memória dele; quem o usa de outra thread é sempre um de
// cada vez (ele vive atrás de um `Mutex` na captura).
unsafe impl Send for Codificador {}

impl Codificador {
    pub fn novo() -> Result<Self, String> {
        let mut erro = 0i32;
        let estado = unsafe {
            opus_encoder_create(
                SAMPLE_RATE as i32,
                CHANNELS as i32,
                OPUS_APPLICATION_AUDIO,
                &mut erro,
            )
        };
        if estado.is_null() || erro != 0 {
            return Err(format!("codificador Opus não abriu (erro {erro})"));
        }
        let c = Self { estado };
        c.ajustar(OPUS_SET_BITRATE_REQUEST, BITRATE, "taxa")?;
        // Ver `audio.rs`: o SDP anuncia `useinbandfec=1`, e anunciar sem
        // produzir faria o telefone contar com uma recuperação que não existe.
        c.ajustar(OPUS_SET_INBAND_FEC_REQUEST, 1, "FEC")?;
        c.ajustar(OPUS_SET_PACKET_LOSS_PERC_REQUEST, 10, "perda esperada")?;
        c.ajustar(OPUS_SET_COMPLEXITY_REQUEST, 5, "complexidade")?;
        Ok(c)
    }

    fn ajustar(&self, pedido: i32, valor: i32, nome: &str) -> Result<(), String> {
        let r = unsafe { opus_encoder_ctl!(self.estado, pedido, valor) };
        if r == 0 {
            Ok(())
        } else {
            Err(format!("Opus recusou a {nome} (erro {r})"))
        }
    }

    /// Codifica um quadro de 20 ms (960 amostras por canal, intercaladas).
    /// Devolve quantos bytes foram escritos em `saida`.
    pub fn codificar(&mut self, quadro: &[f32], saida: &mut [u8]) -> Result<usize, String> {
        if quadro.len() != FRAME_INTERLEAVED {
            return Err(format!(
                "quadro de {} amostras; o Opus quer {FRAME_INTERLEAVED}",
                quadro.len()
            ));
        }
        let n = unsafe {
            opus_encode_float(
                self.estado,
                quadro.as_ptr(),
                (FRAME_INTERLEAVED / CHANNELS) as i32,
                saida.as_mut_ptr(),
                saida.len() as i32,
            )
        };
        if n < 0 {
            Err(format!("Opus falhou ao codificar (erro {n})"))
        } else {
            Ok(n as usize)
        }
    }
}

impl Drop for Codificador {
    fn drop(&mut self) {
        unsafe { opus_encoder_destroy(self.estado) };
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use unsafe_libopus::{opus_decode_float, opus_decoder_create, opus_decoder_destroy};

    /// Um lá (440 Hz) em estéreo, um quadro por vez.
    fn seno(quadro: usize) -> Vec<f32> {
        let por_canal = FRAME_INTERLEAVED / CHANNELS;
        (0..por_canal)
            .flat_map(|i| {
                let t = (quadro * por_canal + i) as f32 / SAMPLE_RATE as f32;
                let v = (t * 440.0 * std::f32::consts::TAU).sin() * 0.5;
                [v, v]
            })
            .collect()
    }

    #[test]
    fn o_som_vai_e_volta_pelo_opus() {
        let mut c = Codificador::novo().unwrap();
        let mut erro = 0;
        let d = unsafe { opus_decoder_create(SAMPLE_RATE as i32, CHANNELS as i32, &mut erro) };
        assert!(!d.is_null() && erro == 0);

        let mut pacote = vec![0u8; 4000];
        let mut volta = vec![0f32; FRAME_INTERLEAVED];
        let mut energia = 0f32;
        for q in 0..25 {
            let n = c.codificar(&seno(q), &mut pacote).unwrap();
            // 96 kbps em 20 ms dão uns 240 bytes; um pacote vazio ou do tamanho
            // do quadro cru seria sinal de configuração errada.
            assert!(n > 20 && n < 1000, "pacote de {n} bytes");
            let amostras = unsafe {
                opus_decode_float(
                    d,
                    pacote.as_ptr(),
                    n as i32,
                    volta.as_mut_ptr(),
                    (FRAME_INTERLEAVED / CHANNELS) as i32,
                    0,
                )
            };
            assert_eq!(amostras as usize, FRAME_INTERLEAVED / CHANNELS);
            if q > 5 {
                // Depois do atraso inicial do codificador, o som tem de voltar.
                energia += volta.iter().map(|v| v * v).sum::<f32>();
            }
        }
        unsafe { opus_decoder_destroy(d) };
        assert!(energia > 100.0, "o som não voltou: energia {energia}");
    }

    #[test]
    fn quadro_do_tamanho_errado_e_recusado() {
        let mut c = Codificador::novo().unwrap();
        let mut saida = vec![0u8; 4000];
        assert!(c.codificar(&[0.0; 100], &mut saida).is_err());
    }
}
