//! Excluir um arquivo pelo celular — para a Lixeira, nunca de vez.
//!
//! ## Por que a Lixeira, e por que isso não é detalhe
//!
//! Quem exclui pelo celular está olhando uma lista num aparelho pequeno, longe
//! do computador, e um toque no item errado é fácil. Na Lixeira o erro custa
//! dois cliques no computador ("Restaurar"); apagado de vez, custa o arquivo.
//! O app diz, na pergunta de confirmação, onde ele vai parar — e essa frase só
//! pode ser dita se for verdade **sempre**.
//!
//! ## O caso em que o Windows apaga de vez sem avisar
//!
//! Pedir "mande para a Lixeira" ao Windows (`FOF_ALLOWUNDO`) não garante que
//! ele mande. Se o arquivo for maior que o espaço da Lixeira daquele disco, ou
//! se a Lixeira estiver configurada para "não mover para a Lixeira", ele
//! **apaga direto** — e, sem janela de confirmação, calado. Por isso duas
//! guardas:
//!
//! 1. Antes, o agente lê a configuração da Lixeira do disco e **recusa** o
//!    que ela não comporta, dizendo por quê. O arquivo continua lá, e quem
//!    quiser mesmo apagá-lo faz isso no computador, sabendo o que faz.
//! 2. Se mesmo assim o Windows decidir apagar de vez, o pedido leva
//!    `FOF_WANTNUKEWARNING`: em vez de apagar calado, o Windows pergunta na
//!    tela do computador. Ninguém respondendo, nada é apagado, e o celular
//!    recebe "o computador pediu confirmação na tela".
//!
//! ## O que pode ser excluído
//!
//! Só **arquivos** dentro da pasta do usuário — a mesma fronteira da
//! navegação e do download (`files::resolve`). Pastas não: um toque apagaria
//! tudo o que há dentro, e a lista do celular não mostra o que é. Atalhos
//! simbólicos também não: o caminho resolvido é o do alvo, e excluir "o
//! atalho" apagaria o arquivo para onde ele aponta.

use std::path::{Path, PathBuf};

use crate::files;

const MB: u64 = 1024 * 1024;

/// O que a Lixeira de um disco aceita.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
pub struct Configuracao {
    /// "Não mover arquivos para a Lixeira": excluir apaga de vez.
    pub apaga_direto: bool,
    /// O tamanho máximo da Lixeira, em MB, quando o Windows diz.
    pub capacidade_mb: Option<u64>,
}

/// Se a Lixeira aceita um arquivo deste tamanho. Pura, para os testes.
pub fn cabe(tamanho: u64, config: Configuracao) -> Result<(), String> {
    if config.apaga_direto {
        return Err(
            "a Lixeira deste computador está configurada para apagar direto, \
                    e excluído por aqui o arquivo sumiria de vez. \
                    Se quiser mesmo apagá-lo, faça isso no computador"
                .into(),
        );
    }
    if let Some(capacidade) = config.capacidade_mb {
        if tamanho > capacidade.saturating_mul(MB) {
            return Err(format!(
                "o arquivo ({} MB) é maior que a Lixeira deste computador ({capacidade} MB), \
                 e excluído por aqui ele sumiria de vez. \
                 Se quiser mesmo apagá-lo, faça isso no computador",
                tamanho.div_ceil(MB)
            ));
        }
    }
    Ok(())
}

/// Confere o pedido e devolve o arquivo a excluir, com o tamanho.
///
/// Separado do ato de excluir para ser testado em qualquer sistema: é aqui
/// que mora a fronteira.
pub fn alvo(caminho: &str) -> Result<(PathBuf, u64), String> {
    if caminho.trim().is_empty() {
        return Err("nenhum arquivo indicado".into());
    }
    // Antes de resolver: `resolve` segue o atalho até o alvo, e aí já não
    // daria para saber que era um.
    if std::fs::symlink_metadata(Path::new(caminho)).is_ok_and(|m| m.file_type().is_symlink()) {
        return Err("é um atalho simbólico; exclua-o no computador".into());
    }
    let real = files::resolve(caminho)?;
    let meta = std::fs::metadata(&real).map_err(|e| format!("não consegui ler o arquivo: {e}"))?;
    if meta.is_dir() {
        return Err("pastas não são excluídas pelo celular, só arquivos".into());
    }
    if !meta.is_file() {
        return Err("não é um arquivo".into());
    }
    Ok((real, meta.len()))
}

/// Manda um arquivo para a Lixeira. Devolve o nome, para a mensagem do app.
pub fn mandar(caminho: &str) -> Result<String, String> {
    let (arquivo, tamanho) = alvo(caminho)?;
    cabe(tamanho, imp::configuracao(&arquivo))?;
    imp::mandar(&arquivo)?;
    // Conferido, e não presumido: um "deu certo" do Windows com o arquivo
    // ainda no lugar faria o app dizer que excluiu o que não excluiu.
    if arquivo.exists() {
        return Err(
            "o Windows não moveu o arquivo; ele pode estar aberto em algum programa".into(),
        );
    }
    let nome = arquivo
        .file_name()
        .map(|n| n.to_string_lossy().to_string())
        .unwrap_or_default();
    crate::diario(&format!(
        "arquivo mandado para a Lixeira pelo celular: {nome}"
    ));
    Ok(nome)
}

/// Tira o `{GUID}` do nome de volume que o Windows devolve
/// (`\\?\Volume{...}\`). É por ele que a configuração da Lixeira é guardada.
#[cfg_attr(not(windows), allow(dead_code))]
fn guid_do_volume(nome: &str) -> Option<&str> {
    let inicio = nome.find('{')?;
    let fim = nome[inicio..].find('}')? + inicio;
    Some(&nome[inicio..=fim])
}

#[cfg(windows)]
mod imp {
    use super::Configuracao;
    use std::ffi::c_void;
    use std::path::Path;
    use std::time::Duration;

    const HKEY_CURRENT_USER: isize = 0x8000_0001u32 as i32 as isize;
    const RRF_RT_REG_DWORD: u32 = 0x0000_0010;

    const FO_DELETE: u32 = 3;
    const FOF_SILENT: u16 = 0x0004;
    const FOF_NOCONFIRMATION: u16 = 0x0010;
    const FOF_ALLOWUNDO: u16 = 0x0040;
    const FOF_NOERRORUI: u16 = 0x0400;
    const FOF_WANTNUKEWARNING: u16 = 0x4000;

    const COINIT_APARTMENTTHREADED: u32 = 0x2;
    const COINIT_DISABLE_OLE1DDE: u32 = 0x4;

    /// Quanto esperar pelo Windows. Passando disto, ele está esperando alguém
    /// responder a uma pergunta na tela do computador.
    const PRAZO: Duration = Duration::from_secs(20);

    /// `SHFILEOPSTRUCTW`. No Windows de 64 bits o alinhamento é o natural —
    /// o empacotamento de 1 byte do `shellapi.h` vale só para 32 bits, que o
    /// Deskside não publica.
    #[repr(C)]
    struct Operacao {
        janela: isize,
        funcao: u32,
        de: *const u16,
        para: *const u16,
        bandeiras: u16,
        abortou: i32,
        mapeamentos: *mut c_void,
        titulo: *const u16,
    }

    #[link(name = "shell32")]
    extern "system" {
        fn SHFileOperationW(operacao: *mut Operacao) -> i32;
    }

    #[link(name = "ole32")]
    extern "system" {
        fn CoInitializeEx(reservado: *mut c_void, modo: u32) -> i32;
        fn CoUninitialize();
    }

    #[link(name = "kernel32")]
    extern "system" {
        fn GetVolumePathNameW(arquivo: *const u16, volume: *mut u16, tamanho: u32) -> i32;
        fn GetVolumeNameForVolumeMountPointW(
            ponto: *const u16,
            nome: *mut u16,
            tamanho: u32,
        ) -> i32;
    }

    #[link(name = "advapi32")]
    extern "system" {
        fn RegGetValueW(
            chave: isize,
            subchave: *const u16,
            valor: *const u16,
            flags: u32,
            tipo: *mut u32,
            dados: *mut c_void,
            tamanho: *mut u32,
        ) -> i32;
    }

    fn largo(texto: &str) -> Vec<u16> {
        texto.encode_utf16().chain(std::iter::once(0)).collect()
    }

    fn texto(buffer: &[u16]) -> String {
        let fim = buffer.iter().position(|&c| c == 0).unwrap_or(buffer.len());
        String::from_utf16_lossy(&buffer[..fim])
    }

    fn dword(subchave: &str, valor: &str) -> Option<u32> {
        let (subchave, valor) = (largo(subchave), largo(valor));
        let mut dados = 0u32;
        let mut tamanho = 4u32;
        let r = unsafe {
            RegGetValueW(
                HKEY_CURRENT_USER,
                subchave.as_ptr(),
                valor.as_ptr(),
                RRF_RT_REG_DWORD,
                std::ptr::null_mut(),
                &mut dados as *mut u32 as *mut c_void,
                &mut tamanho,
            )
        };
        (r == 0).then_some(dados)
    }

    /// A configuração da Lixeira do disco onde o arquivo está.
    ///
    /// Sem conseguir ler, volta o padrão ("aceita"): a segunda guarda, a
    /// pergunta do Windows na tela, continua valendo.
    pub fn configuracao(arquivo: &Path) -> Configuracao {
        let caminho = largo(&arquivo.display().to_string());
        let mut ponto = [0u16; 512];
        if unsafe { GetVolumePathNameW(caminho.as_ptr(), ponto.as_mut_ptr(), ponto.len() as u32) }
            == 0
        {
            return Configuracao::default();
        }
        let mut nome = [0u16; 128];
        if unsafe {
            GetVolumeNameForVolumeMountPointW(ponto.as_ptr(), nome.as_mut_ptr(), nome.len() as u32)
        } == 0
        {
            return Configuracao::default();
        }
        let nome = texto(&nome);
        let Some(guid) = super::guid_do_volume(&nome) else {
            return Configuracao::default();
        };
        let chave =
            format!(r"Software\Microsoft\Windows\CurrentVersion\Explorer\BitBucket\Volume\{guid}");
        Configuracao {
            apaga_direto: dword(&chave, "NukeOnDelete").is_some_and(|v| v != 0),
            capacidade_mb: dword(&chave, "MaxCapacity").map(u64::from),
        }
    }

    /// A chamada ao Windows, numa thread própria.
    ///
    /// Própria por dois motivos: o shell quer COM inicializado como
    /// apartamento de thread única, e as threads do `tokio` não são; e, se o
    /// Windows parar para perguntar algo na tela, é esta thread que fica
    /// presa, não o agente.
    pub fn mandar(arquivo: &Path) -> Result<(), String> {
        // Lista de caminhos terminada por **dois** zeros: é o formato do
        // `pFrom`. Com um só, o Windows leria memória adiante até achar outro.
        let mut de: Vec<u16> = arquivo.display().to_string().encode_utf16().collect();
        de.extend([0, 0]);

        let (envia, recebe) = std::sync::mpsc::channel();
        std::thread::Builder::new()
            .name("deskside-lixeira".into())
            .spawn(move || {
                let com = unsafe {
                    CoInitializeEx(
                        std::ptr::null_mut(),
                        COINIT_APARTMENTTHREADED | COINIT_DISABLE_OLE1DDE,
                    )
                };
                let mut operacao = Operacao {
                    janela: 0,
                    funcao: FO_DELETE,
                    de: de.as_ptr(),
                    para: std::ptr::null(),
                    bandeiras: FOF_ALLOWUNDO
                        | FOF_NOCONFIRMATION
                        | FOF_WANTNUKEWARNING
                        | FOF_SILENT
                        | FOF_NOERRORUI,
                    abortou: 0,
                    mapeamentos: std::ptr::null_mut(),
                    titulo: std::ptr::null(),
                };
                let codigo = unsafe { SHFileOperationW(&mut operacao) };
                if com >= 0 {
                    unsafe { CoUninitialize() };
                }
                let _ = envia.send((codigo, operacao.abortou != 0));
            })
            .map_err(|e| format!("não consegui preparar a exclusão: {e}"))?;

        match recebe.recv_timeout(PRAZO) {
            Ok((0, false)) => Ok(()),
            // Abortou: alguém respondeu "não" à pergunta do Windows na tela.
            Ok((_, true)) => Err("a exclusão foi cancelada no computador".into()),
            Ok((codigo, false)) => Err(format!(
                "o Windows recusou (código {codigo:#x}); o arquivo pode estar aberto em algum programa"
            )),
            Err(_) => Err("o computador pediu confirmação na tela; nada foi excluído por enquanto".into()),
        }
    }
}

#[cfg(not(windows))]
mod imp {
    use super::Configuracao;
    use std::path::Path;

    pub fn configuracao(_arquivo: &Path) -> Configuracao {
        Configuracao::default()
    }

    /// Fora do Windows não há a Lixeira que o app promete, e apagar de vez
    /// quebraria a promessa. O agente de desenvolvimento recusa.
    pub fn mandar(_arquivo: &Path) -> Result<(), String> {
        Err("a Lixeira só existe no agente do Windows".into())
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn lixeira_normal_aceita() {
        assert!(cabe(10 * MB, Configuracao::default()).is_ok());
        let config = Configuracao {
            apaga_direto: false,
            capacidade_mb: Some(100),
        };
        assert!(cabe(100 * MB, config).is_ok());
    }

    #[test]
    fn o_que_nao_cabe_na_lixeira_e_recusado() {
        // O Windows apagaria de vez, calado. A pergunta do app prometeu a
        // Lixeira, então o agente recusa.
        let config = Configuracao {
            apaga_direto: false,
            capacidade_mb: Some(100),
        };
        let erro = cabe(100 * MB + 1, config).unwrap_err();
        assert!(erro.contains("101 MB") && erro.contains("100 MB"), "{erro}");
    }

    #[test]
    fn lixeira_que_apaga_direto_recusa_tudo() {
        let config = Configuracao {
            apaga_direto: true,
            capacidade_mb: None,
        };
        assert!(cabe(1, config).is_err());
    }

    #[test]
    fn o_guid_sai_do_nome_do_volume() {
        assert_eq!(
            guid_do_volume(r"\\?\Volume{1b2c3d4e-0000-1111-2222-333344445555}\"),
            Some("{1b2c3d4e-0000-1111-2222-333344445555}")
        );
        assert_eq!(guid_do_volume("C:\\"), None);
    }

    fn pasta_de_teste(nome: &str) -> PathBuf {
        let home = std::env::var(if cfg!(windows) { "USERPROFILE" } else { "HOME" }).unwrap();
        let pasta = PathBuf::from(home).join(nome);
        std::fs::create_dir_all(&pasta).unwrap();
        pasta
    }

    #[test]
    fn arquivo_dentro_da_pasta_do_usuario_e_aceito() {
        let pasta = pasta_de_teste("deskside-teste-lixeira-arquivo");
        let arquivo = pasta.join("apagar.txt");
        std::fs::write(&arquivo, b"12345").unwrap();

        let (real, tamanho) = alvo(&arquivo.to_string_lossy()).unwrap();
        assert!(real.ends_with("apagar.txt"));
        assert_eq!(tamanho, 5);

        std::fs::remove_dir_all(&pasta).ok();
    }

    #[test]
    fn pasta_nao_e_excluida_pelo_celular() {
        let pasta = pasta_de_teste("deskside-teste-lixeira-pasta");
        let erro = alvo(&pasta.to_string_lossy()).unwrap_err();
        assert!(erro.contains("pastas"), "{erro}");
        // Nem a pasta do usuário inteira, que é o que um caminho vazio seria.
        assert!(alvo("").is_err());
        std::fs::remove_dir_all(&pasta).ok();
    }

    #[test]
    fn fora_da_pasta_do_usuario_e_recusado() {
        assert!(alvo("/etc/hostname").is_err());
        assert!(alvo("../../etc/hostname").is_err());
    }

    #[cfg(unix)]
    #[test]
    fn atalho_simbolico_e_recusado() {
        // Resolvido, o atalho vira o arquivo para onde aponta — e excluir "o
        // atalho" apagaria o arquivo de verdade.
        let pasta = pasta_de_teste("deskside-teste-lixeira-link");
        let alvo_real = pasta.join("real.txt");
        let atalho = pasta.join("atalho.txt");
        std::fs::write(&alvo_real, b"x").unwrap();
        let _ = std::fs::remove_file(&atalho);
        std::os::unix::fs::symlink(&alvo_real, &atalho).unwrap();

        let erro = alvo(&atalho.to_string_lossy()).unwrap_err();
        assert!(erro.contains("atalho"), "{erro}");
        assert!(alvo_real.exists());

        std::fs::remove_dir_all(&pasta).ok();
    }

    #[test]
    fn fora_do_windows_nada_e_apagado() {
        // A promessa do app é a Lixeira; sem ela, recusa em vez de apagar.
        if cfg!(windows) {
            return;
        }
        let pasta = pasta_de_teste("deskside-teste-lixeira-linux");
        let arquivo = pasta.join("fica.txt");
        std::fs::write(&arquivo, b"x").unwrap();
        assert!(mandar(&arquivo.to_string_lossy()).is_err());
        assert!(arquivo.exists());
        std::fs::remove_dir_all(&pasta).ok();
    }
}
