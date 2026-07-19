//! Geração e validação do código de pareamento (Etapa 5 do projeto).
//!
//! Lógica pura, sem dependência de sistema operacional — roda igual em
//! Windows, Linux e macOS e é coberta por testes unitários na CI.

use rand::Rng;

/// Alfabeto sem caracteres ambíguos (0/O, 1/I/L) para facilitar a digitação
/// do código no celular.
const ALPHABET: &[u8] = b"ABCDEFGHJKMNPQRSTUVWXYZ23456789";

pub const PAIRING_CODE_LEN: usize = 9;

/// Gera o código alfanumérico aleatório exibido pelo computador.
pub fn generate_pairing_code() -> String {
    let mut rng = rand::thread_rng();
    (0..PAIRING_CODE_LEN)
        .map(|_| ALPHABET[rng.gen_range(0..ALPHABET.len())] as char)
        .collect()
}

/// Valida um código digitado pelo usuário no aplicativo móvel.
pub fn is_valid_pairing_code(code: &str) -> bool {
    code.len() == PAIRING_CODE_LEN && code.bytes().all(|b| ALPHABET.contains(&b))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn generated_code_has_expected_length() {
        assert_eq!(generate_pairing_code().len(), PAIRING_CODE_LEN);
    }

    #[test]
    fn generated_code_is_valid() {
        for _ in 0..100 {
            assert!(is_valid_pairing_code(&generate_pairing_code()));
        }
    }

    #[test]
    fn generated_codes_are_random() {
        assert_ne!(generate_pairing_code(), generate_pairing_code());
    }

    #[test]
    fn rejects_wrong_length() {
        assert!(!is_valid_pairing_code(""));
        assert!(!is_valid_pairing_code("ABC"));
        assert!(!is_valid_pairing_code("ABCDEFGHJK"));
    }

    #[test]
    fn rejects_ambiguous_characters() {
        assert!(!is_valid_pairing_code("O00000000"));
        assert!(!is_valid_pairing_code("IL1111111"));
    }

    #[test]
    fn rejects_lowercase_and_symbols() {
        assert!(!is_valid_pairing_code("abcdefghj"));
        assert!(!is_valid_pairing_code("ABCD-EFGH"));
    }
}
