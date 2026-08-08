//! Área de transferência do computador.
//!
//! Duas direções, e elas não são simétricas:
//!
//! - **Computador → telefone** pode ser automático. O Windows tem um contador
//!   que muda a cada cópia ([`raw::seq_num`]), então dá para perceber que algo
//!   novo foi copiado sem ficar lendo o conteúdo o tempo todo.
//! - **Telefone → computador** é sempre a pedido. Não por falta de vontade: o
//!   iOS avisa na tela toda vez que um app lê a área de transferência, e um app
//!   que faz isso sozinho a cada segundo vira um incômodo (e um problema de
//!   privacidade).
//!
//! Real no Windows; nas demais plataformas, stub.

/// Teto do que atravessa a rede. Copiar um arquivo de log inteiro é comum, e
/// isso não pode virar uma mensagem de megabytes no WebSocket — o que passar
/// daqui é cortado, com o começo preservado (é o que se costuma querer ver).
pub const MAX_BYTES: usize = 64 * 1024;

/// Corta o texto no teto, sem partir um caractere no meio.
///
/// Cortar por bytes num texto com acento partiria o caractere e produziria
/// lixo do outro lado; por isso o recuo até a fronteira.
pub fn limited(text: &str) -> String {
    if text.len() <= MAX_BYTES {
        return text.to_string();
    }
    let mut fim = MAX_BYTES;
    while fim > 0 && !text.is_char_boundary(fim) {
        fim -= 1;
    }
    text[..fim].to_string()
}

/// Lembra o último texto visto, para não repetir o que já foi dito.
///
/// Serve a dois problemas de uma vez: o contador do Windows muda por motivos
/// que não interessam (um programa que copia e recopia o mesmo texto), e o que
/// **nós** escrevemos na área de transferência também mexe no contador — sem
/// esta memória, o texto que veio do telefone voltaria para ele em eco.
#[derive(Debug, Default)]
pub struct Tracker {
    last: Option<String>,
}

impl Tracker {
    pub fn new() -> Self {
        Self::default()
    }

    /// Registra um texto e devolve-o **apenas se for novidade**.
    pub fn accept(&mut self, text: String) -> Option<String> {
        if self.last.as_deref() == Some(text.as_str()) {
            return None;
        }
        self.last = Some(text.clone());
        Some(text)
    }

    /// Marca um texto como já conhecido, sem devolvê-lo. É o que impede o eco
    /// depois de escrevermos na área de transferência do computador.
    pub fn remember(&mut self, text: &str) {
        self.last = Some(text.to_string());
    }
}

/// Teto do que uma imagem copiada pode ocupar depois de codificada.
///
/// Dois megabytes, contra os 64 KB do texto, porque as duas coisas não têm o
/// mesmo tamanho natural: um texto copiado quase nunca passa de alguns
/// quilobytes, e uma captura de tela nasce com milhões de pixels. Ainda assim é
/// um teto — a mensagem atravessa o WebSocket em base64, que infla um terço, e
/// a imagem passa por um servidor de 1 GB de memória.
pub const MAX_IMAGE_BYTES: usize = 2 * 1024 * 1024;

/// Maior lado depois da redução.
///
/// Uma captura de uma tela 4K tem 3840 px de largura. No telefone ela aparece
/// num espaço de 400 px, e mandar os 3840 seria pagar rede e memória por
/// detalhe que ninguém vê. 1600 ainda permite ler texto pequeno ao ampliar.
pub const MAX_IMAGE_SIDE: u32 = 1600;

/// Uma imagem pronta para o fio.
#[derive(Debug, Clone, PartialEq)]
pub struct Imagem {
    pub bytes: Vec<u8>,
    /// `image/png` ou `image/jpeg`. Vai junto porque o app precisa saber o que
    /// gravar quando a pessoa manda o arquivo para outro aplicativo.
    pub mime: &'static str,
    pub width: u32,
    pub height: u32,
}

/// Converte a imagem crua da área de transferência no que vai ao telefone.
///
/// Pura, e é a única parte disto que dá para testar fora do Windows — o resto é
/// API do sistema. Recebe um BMP (que é como o Windows entrega) e devolve PNG
/// ou JPEG.
///
/// ## Por que PNG primeiro e JPEG depois
///
/// A imagem copiada mais comum, de longe, é uma **captura de tela**: texto,
/// janelas, linhas retas. Nisso o PNG ganha do JPEG em tamanho *e* em
/// qualidade, porque não borra as bordas das letras. Já uma foto colada do
/// navegador comprime mal em PNG e pode passar do teto — aí vale trocar por
/// JPEG, que é exatamente o formato feito para ela.
///
/// Tentar os dois e ficar com o que couber é mais simples, e mais certo, do que
/// adivinhar o tipo de imagem pelo conteúdo.
pub fn preparar_imagem(bruta: &[u8]) -> Result<Imagem, String> {
    let mut img = image::load_from_memory(bruta)
        .map_err(|e| format!("não consegui ler a imagem copiada: {e}"))?;

    // Reduz antes de tentar codificar: é o que resolve o caso comum de uma vez,
    // e codificar 8 milhões de pixels para depois descartar seria trabalho puro.
    let (mut largura, mut altura) = (img.width(), img.height());
    if largura.max(altura) > MAX_IMAGE_SIDE {
        img = img.resize(
            MAX_IMAGE_SIDE,
            MAX_IMAGE_SIDE,
            image::imageops::FilterType::Triangle,
        );
        largura = img.width();
        altura = img.height();
    }

    // Três rodadas no máximo. Sem limite, uma imagem patológica prenderia o
    // agente reduzindo para sempre; com ele, o pior caso é uma imagem de 200 px
    // — feia, mas entregue.
    for rodada in 0..3 {
        if let Ok(png) = codificar(&img, image::ImageFormat::Png) {
            if png.len() <= MAX_IMAGE_BYTES {
                return Ok(Imagem {
                    bytes: png,
                    mime: "image/png",
                    width: largura,
                    height: altura,
                });
            }
        }
        if let Ok(jpeg) = codificar_jpeg(&img) {
            if jpeg.len() <= MAX_IMAGE_BYTES {
                return Ok(Imagem {
                    bytes: jpeg,
                    mime: "image/jpeg",
                    width: largura,
                    height: altura,
                });
            }
        }
        // Ainda não coube: metade do lado, um quarto dos pixels.
        if rodada < 2 {
            img = img.resize(
                (largura / 2).max(1),
                (altura / 2).max(1),
                image::imageops::FilterType::Triangle,
            );
            largura = img.width();
            altura = img.height();
        }
    }
    Err("a imagem copiada é grande demais para caber na mensagem".to_string())
}

fn codificar(img: &image::DynamicImage, formato: image::ImageFormat) -> Result<Vec<u8>, String> {
    let mut buf = std::io::Cursor::new(Vec::new());
    img.write_to(&mut buf, formato)
        .map_err(|e| format!("não consegui codificar a imagem: {e}"))?;
    Ok(buf.into_inner())
}

/// JPEG a 80: a qualidade em que a diferença deixa de ser visível numa tela de
/// telefone, e o arquivo já é uma fração do PNG.
///
/// Converte para RGB antes porque **JPEG não tem canal alfa**. Sem a conversão a
/// codificação falha, e um recorte com fundo transparente é justamente o tipo
/// de imagem que se copia.
fn codificar_jpeg(img: &image::DynamicImage) -> Result<Vec<u8>, String> {
    let mut buf = std::io::Cursor::new(Vec::new());
    let mut enc = image::codecs::jpeg::JpegEncoder::new_with_quality(&mut buf, 80);
    enc.encode_image(&img.to_rgb8())
        .map_err(|e| format!("não consegui codificar a imagem: {e}"))?;
    Ok(buf.into_inner())
}

/// O que estava copiado como arquivo — e quantos ficaram de fora.
///
/// A contagem existe porque o zero tem dois significados muito diferentes:
/// "ninguém copiou nada" e "copiaram três arquivos de `D:\`, que estão fora do
/// que o agente pode buscar". Sem ela, os dois casos chegam ao telefone como
/// uma lista vazia, e a pessoa fica olhando para uma tela que não explica nada.
#[derive(Debug, Default)]
pub struct CopiedFiles {
    pub entries: Vec<crate::files::FileEntry>,
    pub ignored: usize,
}

#[cfg(windows)]
mod imp {
    use super::{limited, CopiedFiles, Tracker};
    use crate::files::FileEntry;

    /// Acompanha a área de transferência do Windows.
    pub struct Clipboard {
        tracker: Tracker,
        /// Último valor do contador do sistema. Enquanto ele não muda, ninguém
        /// copiou nada e não há por que ler o conteúdo.
        last_seq: Option<u32>,
    }

    impl Default for Clipboard {
        fn default() -> Self {
            Self::new()
        }
    }

    impl Clipboard {
        pub fn new() -> Self {
            Self {
                tracker: Tracker::new(),
                last_seq: clipboard_win::raw::seq_num().map(|n| n.get()),
            }
        }

        /// O texto que está na área de transferência agora.
        pub fn read(&mut self) -> Option<String> {
            let texto = clipboard_win::get_clipboard_string().ok()?;
            let texto = limited(&texto);
            // Ler também atualiza a memória: o que o usuário acabou de ver não
            // precisa voltar como "novidade" no próximo aviso automático.
            self.tracker.remember(&texto);
            Some(texto)
        }

        /// Escreve na área de transferência do computador.
        pub fn write(&mut self, text: &str) -> Result<(), String> {
            let texto = limited(text);
            clipboard_win::set_clipboard_string(&texto)
                .map_err(|e| format!("não consegui escrever na área de transferência: {e}"))?;
            // O contador do Windows acabou de mudar por nossa causa; sem estas
            // duas linhas, o texto voltaria ao telefone como se fosse novo.
            self.last_seq = clipboard_win::raw::seq_num().map(|n| n.get());
            self.tracker.remember(&texto);
            Ok(())
        }

        /// Os arquivos que estão copiados no computador.
        ///
        /// Copiar um vídeo no Explorer **não** põe o vídeo na área de
        /// transferência - põe o caminho dele. É por isso que "área de
        /// transferência de vídeo" não existe em lugar nenhum: o que existe é
        /// uma lista de caminhos, e quem sabe buscar arquivo por caminho aqui
        /// é a transferência de arquivos, que já existe.
        ///
        /// Só volta o que está dentro da pasta do usuário: é o mesmo limite do
        /// download, e mostrar o que não dá para buscar seria oferecer um
        /// botão que falha.
        pub fn files(&mut self) -> CopiedFiles {
            // Não ter arquivo copiado é o caso comum (quem copiou um texto cai
            // aqui também). Perguntar antes separa isso de um erro de verdade -
            // e esta pergunta, ao contrário da leitura, não exige abrir nada.
            if !clipboard_win::raw::is_format_avail(clipboard_win::formats::CF_HDROP) {
                return CopiedFiles::default();
            }
            // `get_clipboard` e **não** `get`: o `get` cru pressupõe que a área
            // de transferência já foi aberta por esta thread. Ler sem abrir
            // falha sempre, e como o erro era engolido a lista voltava vazia em
            // toda situação - inclusive com um arquivo copiado à vista.
            //
            // `Vec<String>` e não `Vec<PathBuf>`: a biblioteca tem uma
            // implementação para cada, e o caminho como texto é o que segue
            // para o `resolve` de qualquer forma.
            let caminhos: Vec<String> =
                match clipboard_win::get_clipboard(clipboard_win::formats::FileList) {
                    Ok(lista) => lista,
                    Err(e) => {
                        println!(
                            "Área de transferência: não consegui ler os arquivos \
                             copiados: {e}"
                        );
                        return CopiedFiles::default();
                    }
                };
            let mut fora = 0usize;
            let mut entradas = Vec::new();
            for texto in caminhos {
                let Ok(real) = crate::files::resolve(&texto) else {
                    fora += 1;
                    continue;
                };
                let meta = std::fs::metadata(&real).ok();
                entradas.push(FileEntry {
                    name: real
                        .file_name()
                        .map(|n| n.to_string_lossy().to_string())
                        .unwrap_or_else(|| texto.clone()),
                    path: real.to_string_lossy().to_string(),
                    is_dir: meta.as_ref().is_some_and(|m| m.is_dir()),
                    size: meta.as_ref().map(|m| m.len()).unwrap_or(0),
                });
            }
            if fora > 0 {
                println!(
                    "Área de transferência: {fora} arquivo(s) copiado(s) fora da \
                     pasta do usuário, ignorado(s)"
                );
            }
            CopiedFiles {
                entries: entradas,
                ignored: fora,
            }
        }

        /// A imagem que está na área de transferência agora, se houver.
        ///
        /// Só a pedido, e nunca no aviso automático de cópia. A diferença é de
        /// ordem de grandeza: o aviso de texto custa alguns quilobytes e sai
        /// sozinho a cada cópia, enquanto uma captura de tela custa megabytes.
        /// Mandar isso sem ninguém ter pedido gastaria a rede de quem copiou
        /// uma imagem só para colar no próprio computador.
        pub fn image(&mut self) -> Option<super::Imagem> {
            // Perguntar antes de abrir: quem copiou um texto passa por aqui
            // também, e este teste não exige abrir a área de transferência.
            if !clipboard_win::raw::is_format_avail(clipboard_win::formats::CF_BITMAP) {
                return None;
            }
            let bruta: Vec<u8> =
                match clipboard_win::get_clipboard(clipboard_win::formats::Bitmap) {
                    Ok(bytes) => bytes,
                    Err(e) => {
                        crate::diario(&format!(
                            "Área de transferência: não consegui ler a imagem copiada: {e}"
                        ));
                        return None;
                    }
                };
            match super::preparar_imagem(&bruta) {
                Ok(img) => Some(img),
                Err(motivo) => {
                    // Registrado e não devolvido: o app já mostra o texto e os
                    // arquivos, e uma imagem grande demais não pode derrubar a
                    // resposta inteira.
                    crate::diario(&format!("Área de transferência: {motivo}"));
                    None
                }
            }
        }

        /// Novidade desde a última chamada, se houver.
        ///
        /// Barato o suficiente para chamar de segundo em segundo: só lê o
        /// conteúdo quando o contador do sistema mudou.
        pub fn changed(&mut self) -> Option<String> {
            let seq = clipboard_win::raw::seq_num().map(|n| n.get());
            if seq == self.last_seq {
                return None;
            }
            self.last_seq = seq;
            let texto = clipboard_win::get_clipboard_string().ok()?;
            self.tracker.accept(limited(&texto))
        }
    }
}

#[cfg(not(windows))]
mod imp {
    use super::{CopiedFiles, Tracker};

    /// Stub: sem área de transferência fora do Windows.
    #[derive(Default)]
    pub struct Clipboard {
        #[allow(dead_code)]
        tracker: Tracker,
    }

    impl Clipboard {
        pub fn new() -> Self {
            Self::default()
        }

        pub fn read(&mut self) -> Option<String> {
            None
        }

        pub fn write(&mut self, text: &str) -> Result<(), String> {
            println!("[clipboard-stub] escreveria {} bytes", text.len());
            Ok(())
        }

        pub fn changed(&mut self) -> Option<String> {
            None
        }

        pub fn files(&mut self) -> CopiedFiles {
            CopiedFiles::default()
        }

        pub fn image(&mut self) -> Option<super::Imagem> {
            None
        }
    }
}

pub use imp::Clipboard;

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn texto_curto_passa_inteiro() {
        assert_eq!(limited("olá mundo"), "olá mundo");
    }

    #[test]
    fn texto_gigante_e_cortado_no_teto() {
        let grande = "a".repeat(MAX_BYTES * 2);
        assert_eq!(limited(&grande).len(), MAX_BYTES);
    }

    #[test]
    fn o_corte_nao_parte_um_caractere() {
        // "é" ocupa 2 bytes: cortar no meio produziria lixo do outro lado.
        let texto = "é".repeat(MAX_BYTES);
        let cortado = limited(&texto);
        assert!(cortado.len() <= MAX_BYTES);
        // Se tivesse partido, isto não seria um texto válido em UTF-8 - e o
        // próprio tipo `String` já garante que não partiu; o que se confere
        // aqui é que o corte caiu numa fronteira e não perdeu meio caractere.
        assert!(cortado.chars().all(|c| c == 'é'));
    }

    #[test]
    fn o_mesmo_texto_nao_e_novidade_duas_vezes() {
        let mut t = Tracker::new();
        assert_eq!(t.accept("um".into()), Some("um".into()));
        assert_eq!(t.accept("um".into()), None);
        assert_eq!(t.accept("dois".into()), Some("dois".into()));
    }

    #[test]
    fn o_que_escrevemos_nao_volta_em_eco() {
        // O caso real: o telefone manda um texto, o agente escreve na área de
        // transferência, o contador do Windows muda por causa disso - e sem o
        // `remember` o mesmo texto voltaria ao telefone como novidade.
        let mut t = Tracker::new();
        t.remember("vindo do telefone");
        assert_eq!(t.accept("vindo do telefone".into()), None);
    }

    /// Um BMP de verdade, do tamanho pedido, como o Windows entregaria.
    ///
    /// Gerado e não fixo em disco: o que se testa aqui é o comportamento com
    /// imagens de tamanhos diferentes, e um arquivo por caso encheria o
    /// repositório de binário.
    fn bmp(largura: u32, altura: u32, ruido: bool) -> Vec<u8> {
        let mut img = image::RgbImage::new(largura, altura);
        for (x, y, p) in img.enumerate_pixels_mut() {
            *p = if ruido {
                // Ruído comprime mal: é assim que se força o PNG a estourar o
                // teto, que é o caminho que leva ao JPEG. A mistura precisa ser
                // boa de verdade - um padrão que se repete por linha o PNG
                // comprime bem, e o teste passaria a medir outra coisa.
                let mut s = (y as u64) << 32 | x as u64;
                s ^= s << 13;
                s ^= s >> 7;
                s = s.wrapping_mul(0x9E37_79B9_7F4A_7C15);
                s ^= s >> 31;
                image::Rgb([s as u8, (s >> 8) as u8, (s >> 16) as u8])
            } else {
                image::Rgb([200, 210, 220])
            };
        }
        let mut buf = std::io::Cursor::new(Vec::new());
        image::DynamicImage::ImageRgb8(img)
            .write_to(&mut buf, image::ImageFormat::Bmp)
            .unwrap();
        buf.into_inner()
    }

    #[test]
    fn captura_de_tela_vai_como_png() {
        // O caso comum: texto, janelas, linhas retas. PNG ganha do JPEG em
        // tamanho e em qualidade, porque não borra a borda das letras.
        let img = preparar_imagem(&bmp(800, 600, false)).unwrap();
        assert_eq!(img.mime, "image/png");
        assert_eq!((img.width, img.height), (800, 600));
        assert!(img.bytes.len() <= MAX_IMAGE_BYTES);
    }

    #[test]
    fn imagem_gigante_e_reduzida() {
        // Uma captura de uma tela 4K tem 3840 px. No telefone ela aparece num
        // espaço de 400, e mandar os 3840 seria pagar rede por detalhe que
        // ninguém vê.
        let img = preparar_imagem(&bmp(3840, 2160, false)).unwrap();
        assert!(img.width <= MAX_IMAGE_SIDE, "largura {}", img.width);
        assert!(img.height <= MAX_IMAGE_SIDE, "altura {}", img.height);
        // A proporção tem que sobreviver: 16:9 esticado viraria outra imagem.
        let proporcao = img.width as f32 / img.height as f32;
        assert!((proporcao - 3840.0 / 2160.0).abs() < 0.02, "{proporcao}");
    }

    #[test]
    fn imagem_que_nao_cabe_em_png_cai_para_jpeg() {
        // Ruído não comprime: neste tamanho o PNG passa dos 2 MB (~3 MB) e o
        // JPEG cabe (~1,3 MB). É o caminho da foto colada do navegador - e o
        // que se preserva aqui é que a imagem chega **do tamanho original**,
        // trocando de formato em vez de encolher.
        let img = preparar_imagem(&bmp(1000, 1000, true)).unwrap();
        assert!(img.bytes.len() <= MAX_IMAGE_BYTES, "{} bytes", img.bytes.len());
        assert_eq!(img.mime, "image/jpeg");
        assert_eq!((img.width, img.height), (1000, 1000));
    }

    #[test]
    fn quando_nenhum_formato_cabe_a_imagem_encolhe() {
        // Ruído em 1600x1600 estoura os dois formatos (PNG ~7,7 MB, JPEG
        // ~3,5 MB). A saída é reduzir e tentar de novo - entregar uma imagem
        // menor é melhor que não entregar nada, e é o pior caso previsto.
        let img = preparar_imagem(&bmp(1600, 1600, true)).unwrap();
        assert!(img.bytes.len() <= MAX_IMAGE_BYTES, "{} bytes", img.bytes.len());
        assert!(img.width < 1600, "não encolheu: {}", img.width);
    }

    #[test]
    fn o_resultado_e_uma_imagem_valida() {
        // O app decodifica isto. Se o que sai daqui não for legível, o erro
        // aparece no telefone, longe da causa.
        let img = preparar_imagem(&bmp(300, 200, false)).unwrap();
        let volta = image::load_from_memory(&img.bytes).unwrap();
        assert_eq!((volta.width(), volta.height()), (img.width, img.height));
    }

    #[test]
    fn lixo_no_lugar_da_imagem_vira_erro_e_nao_panico() {
        assert!(preparar_imagem(b"isto nao e uma imagem").is_err());
        assert!(preparar_imagem(&[]).is_err());
    }

    #[test]
    fn imagem_com_transparencia_atravessa() {
        // Um recorte com fundo transparente é justamente o tipo de imagem que
        // se copia. Se o caminho do JPEG for usado sem tirar o canal alfa, a
        // codificação falha - e este teste é o que pega isso.
        let mut img = image::RgbaImage::new(64, 64);
        for p in img.pixels_mut() {
            *p = image::Rgba([10, 20, 30, 0]);
        }
        let mut buf = std::io::Cursor::new(Vec::new());
        image::DynamicImage::ImageRgba8(img)
            .write_to(&mut buf, image::ImageFormat::Png)
            .unwrap();
        let pronta = preparar_imagem(&buf.into_inner()).unwrap();
        assert_eq!((pronta.width, pronta.height), (64, 64));
    }

    #[test]
    fn fora_do_windows_nao_ha_o_que_ler() {
        let mut c = Clipboard::new();
        #[cfg(not(windows))]
        {
            assert!(c.read().is_none());
            assert!(c.changed().is_none());
            assert!(c.write("x").is_ok());
            assert!(c.files().entries.is_empty());
            assert_eq!(c.files().ignored, 0);
        }
        #[cfg(windows)]
        let _ = c.changed();
    }
}
