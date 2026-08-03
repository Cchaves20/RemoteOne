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
