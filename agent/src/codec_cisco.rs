//! O codificador H.264 por software: o binário do OpenH264 que a **Cisco**
//! publica, baixado por este computador na primeira vez que for preciso.
//!
//! ## Por que baixar, e não trazer junto
//!
//! O H.264 é coberto por patentes (o pool da MPEG LA, hoje Via LA). A Cisco
//! paga essas licenças pelo binário dela, mas só sob quatro condições
//! (`LICENCA-OPENH264-CISCO.txt`, na íntegra):
//!
//! 1. o binário é **baixado à parte** para o computador de quem usa, e não vem
//!    dentro do nosso instalador;
//! 2. a pessoa pode **ligar, desligar e religar** o uso dele;
//! 3. onde ela faz isso aparece "OpenH264 Video Codec provided by Cisco
//!    Systems, Inc." ([`AVISO`]);
//! 4. o texto da licença vai junto das outras licenças.
//!
//! Antes o agente compilava o código do OpenH264 para dentro do executável, e
//! aí a licença das patentes seria problema nosso. Agora o executável não traz
//! codec nenhum: este módulo baixa o binário da Cisco, confere o SHA-256 contra
//! a lista que a crate `openh264` traz, e só então o carrega.
//!
//! Os testes continuam compilando o OpenH264 da fonte (`[dev-dependencies]`):
//! isso fica no binário de teste, que não é distribuído.
//!
//! ## Quando não há o binário
//!
//! Enquanto ele baixa, com o uso desligado, ou onde a Cisco não publica nada
//! (Windows em ARM), [`api`] devolve erro. O vídeo então vem da placa de vídeo
//! (Windows) ou cai para o JPEG — ver `client.rs`, `sem_h264`.
//!
//! ## No Mac
//!
//! O binário da Cisco não é assinado por nós. Com o "hardened runtime" da
//! assinatura Developer ID, o macOS só carrega biblioteca da mesma equipe; por
//! isso o `mac/deskside.entitlements` pede
//! `com.apple.security.cs.disable-library-validation`.

use std::io::Read;
use std::path::PathBuf;
use std::sync::atomic::{AtomicBool, Ordering};

use openh264::OpenH264API;
use sha2::{Digest, Sha256};

/// O texto que a Cisco exige onde a pessoa liga e desliga o codec (condição 3).
pub const AVISO: &str = "OpenH264 Video Codec provided by Cisco Systems, Inc.";

/// A chave do `agent.conf`. `desligado` desliga; ausente ou qualquer outro
/// valor, ligado.
pub const CHAVE: &str = "DESKSIDE_OPENH264";

/// A versão que a crate `openh264` 0.9.7 sabe carregar. Trocar de versão da
/// crate pode exigir trocar esta, junto com os resumos abaixo (que vêm do
/// `src/blobs/hashes.txt` da `openh264-sys2`).
pub const VERSAO: &str = "2.6.0";

/// O servidor da Cisco. Só HTTP na lista oficial de versões (`RELEASES`); o
/// HTTPS é tentado antes, e a integridade não depende de nenhum dos dois: o
/// arquivo só é aceito se o resumo bater com [`BINARIO`].
const SERVIDOR: &str = "ciscobinary.openh264.org";

/// O teto do download. Os binários têm ~1 MB comprimidos.
const LIMITE: u64 = 16 * 1024 * 1024;

/// O binário deste sistema: nome no servidor da Cisco (sem o `.bz2`) e o
/// SHA-256 do arquivo já descomprimido. `None` onde a Cisco não publica.
pub const BINARIO: Option<(&str, &str)> = binario_do_sistema();

const fn binario_do_sistema() -> Option<(&'static str, &'static str)> {
    if cfg!(all(target_os = "windows", target_arch = "x86_64")) {
        Some((
            "openh264-2.6.0-win64.dll",
            "2076cb5675ec6c1a4c70e7a2a322552f547b6eeed649d6dfcd9e02a543b24691",
        ))
    } else if cfg!(all(target_os = "macos", target_arch = "aarch64")) {
        Some((
            "libopenh264-2.6.0-mac-arm64.dylib",
            "052e98bfcf7a9167d22f3bbb3f5988ef79065591f36af8b52924b22b13624551",
        ))
    } else if cfg!(all(target_os = "macos", target_arch = "x86_64")) {
        Some((
            "libopenh264-2.6.0-mac-x64.dylib",
            "e3dc8bc01fe69363f61fd3c02fd27798537a585eadd38cd808f303d1ee505a19",
        ))
    } else if cfg!(all(target_os = "linux", target_arch = "x86_64")) {
        Some((
            "libopenh264-2.6.0-linux64.8.so",
            "2f0cde7c6a6abcf5cae76942894ea42897fa677bce4ed6c91a24dd1b041d5f04",
        ))
    } else if cfg!(all(target_os = "linux", target_arch = "aarch64")) {
        Some((
            "libopenh264-2.6.0-linux-arm64.8.so",
            "12e7b33623667cdab0e575170c147b1b36eadb77d0d2aa7ceb5afd3e58902140",
        ))
    } else {
        // Windows em ARM (o MateBook) e o resto: a Cisco não publica.
        None
    }
}

/// Todos os binários, para o teste do CI que baixa cada um de verdade.
pub const TODOS: [(&str, &str); 5] = [
    (
        "openh264-2.6.0-win64.dll",
        "2076cb5675ec6c1a4c70e7a2a322552f547b6eeed649d6dfcd9e02a543b24691",
    ),
    (
        "libopenh264-2.6.0-mac-arm64.dylib",
        "052e98bfcf7a9167d22f3bbb3f5988ef79065591f36af8b52924b22b13624551",
    ),
    (
        "libopenh264-2.6.0-mac-x64.dylib",
        "e3dc8bc01fe69363f61fd3c02fd27798537a585eadd38cd808f303d1ee505a19",
    ),
    (
        "libopenh264-2.6.0-linux64.8.so",
        "2f0cde7c6a6abcf5cae76942894ea42897fa677bce4ed6c91a24dd1b041d5f04",
    ),
    (
        "libopenh264-2.6.0-linux-arm64.8.so",
        "12e7b33623667cdab0e575170c147b1b36eadb77d0d2aa7ceb5afd3e58902140",
    ),
];

/// Em que pé está o codec, para a janela e o diário.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Situacao {
    /// A pessoa desligou.
    Desligado,
    /// A Cisco não publica para este computador.
    SemBinario,
    /// Ligado e ainda não baixado (ou baixando).
    Baixando,
    /// O último download falhou; tenta de novo na próxima vez que precisar.
    Falhou(String),
    /// Pronto para usar.
    Pronto,
}

static BAIXANDO: AtomicBool = AtomicBool::new(false);
static ULTIMA_FALHA: std::sync::Mutex<Option<String>> = std::sync::Mutex::new(None);

/// Se a pessoa deixou o codec ligado (condição 2). Ligado por padrão.
pub fn ligado() -> bool {
    !desligado_em(crate::config::resolve(&crate::load_config(), CHAVE).as_deref())
}

fn desligado_em(valor: Option<&str>) -> bool {
    valor.is_some_and(|v| {
        matches!(
            v.trim().to_ascii_lowercase().as_str(),
            "desligado" | "nao" | "não" | "0" | "false" | "off"
        )
    })
}

/// Liga ou desliga, e grava. Ligar dispara o download se ainda não houver o
/// binário.
pub fn definir(ligar: bool) -> Result<(), String> {
    let mut cfg = crate::load_config();
    // Ligado é o padrão: gravar só o "desligado" deixa o arquivo limpo.
    cfg.set(CHAVE, if ligar { "" } else { "desligado" });
    crate::save_config(&cfg)?;
    crate::diario(&format!(
        "Vídeo: codec OpenH264 da Cisco {}",
        if ligar { "ligado" } else { "desligado" }
    ));
    if ligar {
        preparar();
    }
    Ok(())
}

/// Onde o binário fica: a pasta de configuração do agente, que é da pessoa e
/// sobrevive às atualizações do executável.
pub fn caminho() -> Option<PathBuf> {
    let (nome, _) = BINARIO?;
    Some(crate::config_dir().join("codec").join(nome))
}

pub fn situacao() -> Situacao {
    if !ligado() {
        return Situacao::Desligado;
    }
    let Some(caminho) = caminho() else {
        return Situacao::SemBinario;
    };
    if caminho.exists() {
        return Situacao::Pronto;
    }
    if !BAIXANDO.load(Ordering::Relaxed) {
        if let Some(erro) = ULTIMA_FALHA.lock().ok().and_then(|f| f.clone()) {
            return Situacao::Falhou(erro);
        }
    }
    Situacao::Baixando
}

/// Garante o binário, baixando em segundo plano se faltar. Não espera: quem
/// chama segue, e o vídeo usa o codec assim que ele aparecer.
pub fn preparar() {
    if !ligado() {
        return;
    }
    let Some(caminho) = caminho() else { return };
    if caminho.exists() || BAIXANDO.swap(true, Ordering::SeqCst) {
        return;
    }
    std::thread::spawn(move || {
        let resultado = baixar_para(&caminho);
        match &resultado {
            Ok(()) => crate::diario("Vídeo: codec OpenH264 da Cisco baixado"),
            Err(e) => crate::diario(&format!("Vídeo: não baixei o codec OpenH264 da Cisco: {e}")),
        }
        if let Ok(mut falha) = ULTIMA_FALHA.lock() {
            *falha = resultado.err();
        }
        BAIXANDO.store(false, Ordering::SeqCst);
    });
}

/// O codec para o `h264::Encoder`, ou o motivo de não haver.
#[cfg(not(test))]
pub fn api() -> Result<OpenH264API, String> {
    match situacao() {
        Situacao::Pronto => {}
        Situacao::Desligado => return Err("o codec OpenH264 está desligado".into()),
        Situacao::SemBinario => {
            return Err("a Cisco não publica o OpenH264 para este computador".into())
        }
        Situacao::Baixando | Situacao::Falhou(_) => {
            preparar();
            return Err("o codec OpenH264 ainda está sendo baixado".into());
        }
    }
    let caminho = caminho().expect("Pronto implica binário");
    // `from_blob_path` confere o resumo de novo, contra a lista da crate: um
    // arquivo trocado na pasta depois do download não é carregado.
    OpenH264API::from_blob_path(&caminho).map_err(|e| {
        // Arquivo estragado: apaga, para o próximo pedido baixar outro.
        let _ = std::fs::remove_file(&caminho);
        format!("não carreguei o codec OpenH264: {e}")
    })
}

/// Nos testes, o OpenH264 compilado da fonte (`[dev-dependencies]`): o teste
/// não depende de rede, e nada disso é distribuído.
#[cfg(test)]
pub fn api() -> Result<OpenH264API, String> {
    Ok(OpenH264API::from_source())
}

/// Baixa, descomprime, confere e grava. Grava num nome temporário e só então
/// renomeia: um download pela metade nunca fica no lugar do certo.
fn baixar_para(destino: &std::path::Path) -> Result<(), String> {
    let (nome, resumo) = BINARIO.ok_or("sem binário para este computador")?;
    let comprimido = baixar_comprimido(nome)?;
    let aberto = descomprimir(&comprimido)?;
    conferir(&aberto, resumo)?;
    let pasta = destino.parent().ok_or("caminho sem pasta")?;
    std::fs::create_dir_all(pasta).map_err(|e| format!("não criei {}: {e}", pasta.display()))?;
    let temporario = destino.with_extension("baixando");
    std::fs::write(&temporario, &aberto)
        .map_err(|e| format!("não gravei {}: {e}", temporario.display()))?;
    std::fs::rename(&temporario, destino)
        .map_err(|e| format!("não gravei {}: {e}", destino.display()))
}

/// O `.bz2` do servidor da Cisco: HTTPS primeiro, HTTP se o HTTPS falhar.
pub fn baixar_comprimido(nome: &str) -> Result<Vec<u8>, String> {
    let caminho = format!("/{nome}.bz2");
    let mut corpo = Vec::new();
    let https = crate::atualizacao::Origem {
        host: SERVIDOR.into(),
        porta: 443,
    };
    match crate::atualizacao::baixar_de(&https, &caminho, LIMITE, &mut corpo) {
        Ok(_) => return Ok(corpo),
        Err(e) => crate::diario(&format!("Vídeo: HTTPS da Cisco falhou ({e}); tento HTTP")),
    }
    corpo.clear();
    let http = crate::atualizacao::Origem {
        host: SERVIDOR.into(),
        porta: 80,
    };
    crate::atualizacao::baixar_sem_tls(&http, &caminho, LIMITE, &mut corpo)?;
    Ok(corpo)
}

pub fn descomprimir(comprimido: &[u8]) -> Result<Vec<u8>, String> {
    let mut aberto = Vec::new();
    bzip2::read::BzDecoder::new(comprimido)
        .take(LIMITE)
        .read_to_end(&mut aberto)
        .map_err(|e| format!("o arquivo da Cisco não abriu: {e}"))?;
    Ok(aberto)
}

pub fn conferir(bytes: &[u8], esperado: &str) -> Result<(), String> {
    let resumo: String = Sha256::digest(bytes)
        .iter()
        .map(|b| format!("{b:02x}"))
        .collect();
    if resumo == esperado {
        Ok(())
    } else {
        Err(format!(
            "o resumo não confere (veio {resumo}, esperava {esperado})"
        ))
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn so_desliga_com_um_valor_claro() {
        assert!(!desligado_em(None));
        assert!(!desligado_em(Some("")));
        assert!(!desligado_em(Some("ligado")));
        assert!(desligado_em(Some("desligado")));
        assert!(desligado_em(Some(" Desligado ")));
        assert!(desligado_em(Some("0")));
        assert!(desligado_em(Some("não")));
    }

    #[test]
    fn o_binario_do_sistema_esta_entre_todos() {
        if let Some(b) = BINARIO {
            assert!(TODOS.contains(&b));
        }
    }

    #[test]
    fn descomprime_e_confere() {
        use std::io::Write;
        let original = b"um binario de mentira".to_vec();
        let mut z = bzip2::write::BzEncoder::new(Vec::new(), bzip2::Compression::default());
        z.write_all(&original).unwrap();
        let comprimido = z.finish().unwrap();
        let aberto = descomprimir(&comprimido).unwrap();
        assert_eq!(aberto, original);
        let resumo: String = Sha256::digest(&original)
            .iter()
            .map(|b| format!("{b:02x}"))
            .collect();
        assert!(conferir(&aberto, &resumo).is_ok());
        assert!(conferir(&aberto, &"0".repeat(64)).is_err());
    }

    #[test]
    fn lixo_nao_descomprime() {
        assert!(descomprimir(b"isto nao e bzip2").is_err());
    }

    #[test]
    fn o_aviso_e_o_texto_exato_da_cisco() {
        let licenca = include_str!("../LICENCA-OPENH264-CISCO.txt");
        assert!(licenca.contains(&format!("\"{AVISO}\"")));
    }

    /// Baixa de verdade, do servidor da Cisco, todos os binários que o agente
    /// pode pedir, e confere cada resumo. O deste sistema ainda é carregado e
    /// codifica um quadro: é a prova de que o caminho inteiro funciona.
    ///
    /// Ignorado no `cargo test` comum, que não deve depender de rede; o CI roda
    /// com `--ignored` (ver `.github/workflows/agent.yml`).
    #[test]
    #[ignore = "baixa do servidor da Cisco"]
    fn baixa_confere_e_carrega_os_binarios_da_cisco() {
        use openh264::encoder::{Encoder, EncoderConfig};
        use openh264::formats::YUVBuffer;

        for (nome, resumo) in TODOS {
            let comprimido = baixar_comprimido(nome).unwrap_or_else(|e| panic!("{nome}: {e}"));
            let aberto = descomprimir(&comprimido).unwrap_or_else(|e| panic!("{nome}: {e}"));
            conferir(&aberto, resumo).unwrap_or_else(|e| panic!("{nome}: {e}"));
            println!("{nome}: {} bytes, resumo confere", aberto.len());

            if BINARIO == Some((nome, resumo)) {
                let pasta = std::env::temp_dir().join("deskside-codec-teste");
                std::fs::create_dir_all(&pasta).unwrap();
                let arquivo = pasta.join(nome);
                std::fs::write(&arquivo, &aberto).unwrap();
                let api = OpenH264API::from_blob_path(&arquivo).expect("a crate aceita o binário");
                let mut codificador =
                    Encoder::with_api_config(api, EncoderConfig::new()).expect("codificador abre");
                let quadro = YUVBuffer::new(64, 64);
                let saida = codificador.encode(&quadro).expect("codifica um quadro");
                assert!(!saida.to_vec().is_empty());
                println!("{nome}: carregado e codificou um quadro");
            }
        }
    }
}
