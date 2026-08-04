//! Exibe o código de pareamento sem depender de um terminal aberto.
//!
//! Quando o agente roda em segundo plano, o `println!` do código não é visto
//! por ninguém. Duas saídas, e as duas continuam valendo:
//!
//!  - grava o código num arquivo (`%APPDATA%\remoteone\pairing-code.txt`);
//!  - guarda-o aqui, e a janela do agente o mostra em letra grande, com botão
//!    de copiar - abrindo sozinha quando ele chega.
//!
//! ## O que saiu daqui
//!
//! Havia uma MessageBox disparada por `powershell.exe`. Custava cerca de um
//! segundo, piscava, só aceitava ASCII (o texto perdia acento) e é o padrão
//! que antivírus marcam: um processo em segundo plano invocando PowerShell.
//! A janela própria faz o mesmo trabalho melhor, sem processo nenhum a mais.
//!
//! Um balão de notificação seria pior que a janela: some em segundos, e um
//! código de pareamento é exatamente o tipo de coisa que a pessoa perde e
//! precisa reencontrar.

use std::path::PathBuf;
use std::sync::Mutex;

/// O código válido agora, se houver.
///
/// Global porque só existe um pareamento em curso por processo, e a
/// alternativa seria carregar um canal do laço de rede até o desenho da tela,
/// atravessando código que não tem nada a ver com isso.
static PENDENTE: Mutex<Option<(String, u64)>> = Mutex::new(None);

/// O que fazer quando um código chega. A interface registra "abrir a janela".
///
/// Um gancho, e não uma chamada direta à janela, porque este módulo é o do
/// **aviso**: ele não deve saber se existe interface. Fora do Windows não
/// existe, e nos testes também não.
static AO_RECEBER: Mutex<Option<Box<dyn Fn() + Send + 'static>>> = Mutex::new(None);

/// Registra quem deve ser avisado quando um código de pareamento chegar.
pub fn ao_receber_codigo(f: impl Fn() + Send + 'static) {
    if let Ok(mut slot) = AO_RECEBER.lock() {
        *slot = Some(Box::new(f));
    }
}

/// Anuncia o código de pareamento por vias que não exigem terminal.
pub fn announce_pairing_code(code: &str, expires_in_seconds: u64) {
    if let Some(path) = code_file_path() {
        write_code_file(&path, code, expires_in_seconds);
    }
    if let Ok(mut slot) = PENDENTE.lock() {
        *slot = Some((code.to_string(), expires_in_seconds));
    }
    // O aviso sai **depois** de o código estar guardado: quem for avisado abre
    // a janela, que lê o código já disponível. Na ordem inversa a janela
    // abriria vazia numa corrida rara e difícil de reproduzir.
    //
    // Chamado com o cadeado de `AO_RECEBER` na mão. Isso obriga o avisado a
    // não voltar a este módulo pelo mesmo caminho - e ele não volta: abrir a
    // janela é uma chamada ao Windows. Ler o código usa outro cadeado.
    if let Ok(slot) = AO_RECEBER.lock() {
        if let Some(f) = slot.as_ref() {
            f();
        }
    }
}

/// O código à espera de ser digitado, para a janela mostrar.
pub fn codigo_pendente() -> Option<(String, u64)> {
    PENDENTE.lock().ok().and_then(|s| s.clone())
}

/// Remove o código depois que o dispositivo é pareado (limpeza).
///
/// Some do arquivo **e** da tela: um código já usado continuar em letra
/// garrafal seria pedir para alguém tentar digitá-lo de novo e concluir que o
/// pareamento está quebrado.
pub fn clear_pairing_code() {
    if let Some(path) = code_file_path() {
        let _ = std::fs::remove_file(path);
    }
    if let Ok(mut slot) = PENDENTE.lock() {
        *slot = None;
    }
}

fn write_code_file(path: &PathBuf, code: &str, expires_in_seconds: u64) {
    if let Some(dir) = path.parent() {
        let _ = std::fs::create_dir_all(dir);
    }
    let minutes = expires_in_seconds / 60;
    let body = format!(
        "Código de pareamento do RemoteOne: {code}\n\
         Expira em {minutes} min. Informe este código no aplicativo.\n"
    );
    let _ = std::fs::write(path, body);
}

fn code_file_path() -> Option<PathBuf> {
    config_base().map(|b| b.join("remoteone").join("pairing-code.txt"))
}

/// Base de configuração, honrando REMOTEONE_CONFIG_DIR (igual ao main.rs).
fn config_base() -> Option<PathBuf> {
    if let Some(dir) = std::env::var_os("REMOTEONE_CONFIG_DIR") {
        return Some(PathBuf::from(dir));
    }
    if cfg!(target_os = "windows") {
        std::env::var_os("APPDATA").map(PathBuf::from)
    } else {
        std::env::var_os("XDG_CONFIG_HOME")
            .map(PathBuf::from)
            .or_else(|| std::env::var_os("HOME").map(|h| PathBuf::from(h).join(".config")))
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn writes_code_file_with_code_and_expiry() {
        let dir = std::env::temp_dir().join(format!("remoteone-notify-{}", std::process::id()));
        let path = dir.join("pairing-code.txt");
        write_code_file(&path, "ABC23XYZK", 600);
        let content = std::fs::read_to_string(&path).unwrap();
        assert!(content.contains("ABC23XYZK"));
        assert!(content.contains("10 min"));
        std::fs::remove_dir_all(&dir).ok();
    }

    #[test]
    fn quem_registrou_e_avisado_com_o_codigo_ja_no_lugar() {
        // A ordem é o que importa aqui. A janela abre por causa do aviso e lê
        // o código na hora; se o aviso saísse primeiro, ela abriria vazia.
        use std::sync::atomic::{AtomicBool, Ordering};
        static VIU_O_CODIGO: AtomicBool = AtomicBool::new(false);
        ao_receber_codigo(|| {
            VIU_O_CODIGO.store(codigo_pendente().is_some(), Ordering::SeqCst);
        });
        announce_pairing_code("XYZ99ABCD", 300);
        assert!(
            VIU_O_CODIGO.load(Ordering::SeqCst),
            "a janela abriria antes de o código existir"
        );
        clear_pairing_code();
    }

    #[test]
    fn o_codigo_fica_disponivel_para_a_janela_e_some_ao_parear() {
        announce_pairing_code("ABC23XYZK", 600);
        assert_eq!(
            codigo_pendente(),
            Some(("ABC23XYZK".to_string(), 600)),
            "a janela não teria o que mostrar"
        );
        clear_pairing_code();
        assert_eq!(
            codigo_pendente(),
            None,
            "um código já usado continuaria na tela convidando a digitá-lo de novo"
        );
    }
}
