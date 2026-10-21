//! Um aviso curto para o celular de quem está com a tela aberta.
//!
//! Para o que deu errado longe dos olhos de quem pediu: o sistema pedindo
//! permissão na tela do computador, um layout de teclado que não faz o "é", um
//! "desligar" recusado. Chega ao app como `aviso_da_tela` e aparece numa faixa
//! no rodapé. Sem tela aberta, o servidor não tem a quem entregar, e o aviso
//! fica só no diário.

use std::sync::Mutex;

static AVISO: Mutex<Option<String>> = Mutex::new(None);

/// Deixa o aviso para o laço de rede mandar. Um só de cada vez: o mais novo
/// substitui o que ainda não saiu.
pub fn avisar(texto: &str) {
    crate::diario(&format!("aviso ao celular: {texto}"));
    if let Ok(mut a) = AVISO.lock() {
        *a = Some(texto.to_string());
    }
}

/// O aviso pendente, se houver. Quem lê é o laço de rede.
pub fn tomar() -> Option<String> {
    AVISO.lock().ok()?.take()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn o_mais_novo_vence_e_sai_uma_vez() {
        avisar("primeiro");
        avisar("segundo");
        assert_eq!(tomar().as_deref(), Some("segundo"));
        assert_eq!(tomar(), None);
    }
}
