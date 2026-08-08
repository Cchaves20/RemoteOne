//! Abrir vários programas de uma vez.
//!
//! É o "abrir todos" de um perfil, e a primeira peça das automações: um toque
//! no telefone monta o ambiente de trabalho em vez de abrir um programa só.
//!
//! ## Por que a lista é executada aqui, e não no telefone
//!
//! O caminho fácil seria o app chamar o endpoint de abrir uma vez por programa.
//! Três problemas, e o terceiro decide:
//!
//! 1. Uma lista de seis programas seriam seis idas e voltas
//!    `celular → servidor → agente`.
//! 2. A espera entre um programa e o seguinte teria de ser contada do outro
//!    lado do mundo.
//! 3. **O iOS suspende aplicativos.** Quem aperta o botão e bloqueia a tela
//!    veria a lista parar no meio — o primeiro programa aberto e o resto não.
//!    Um "Modo Trabalho" que às vezes faz metade do trabalho é pior que não
//!    ter.
//!
//! Com a lista inteira numa mensagem só, o telefone pode sair da frente no
//! instante seguinte ao toque.
//!
//! Este módulo é **portável de propósito**: quem abre o programa entra por
//! parâmetro. Isso deixa a parte que erra — ordem, espera, teto, o que fazer
//! quando um falha — testável fora do Windows, que é onde ela é escrita.

use std::time::Duration;

/// Teto de programas numa lista.
///
/// Um perfil com dezesseis programas já é exagero; acima disso é uma mensagem
/// que não deveria rodar. O teto não está aqui para a interface — está para o
/// caso de uma mensagem adulterada mandar o computador abrir mil janelas.
pub const MAX_PROGRAMAS: usize = 16;

/// Intervalo entre uma abertura e a seguinte.
///
/// Não é enfeite e não é medo: abrir quatro programas pesados no mesmo instante
/// faz os quatro demorarem mais, e o Windows empilha as janelas numa ordem que
/// depende de quem terminou de carregar primeiro. Com o intervalo, **o último
/// da lista fica por cima** — que é a regra combinada, e a única forma de a
/// ordem da lista significar alguma coisa para quem toca "abrir todos".
pub const ESPERA_PADRAO: Duration = Duration::from_millis(400);

/// O que aconteceu com um programa da lista.
#[derive(Debug, Clone, PartialEq, serde::Serialize, serde::Deserialize)]
pub struct Resultado {
    /// O mesmo identificador que veio no pedido, para o app casar a resposta
    /// com o item da lista que ele mostrou.
    pub id: String,
    pub ok: bool,
    /// Por que não abriu. Ausente quando abriu.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub error: Option<String>,
}

/// Abre a lista em ordem e devolve o que aconteceu com cada um.
///
/// **Uma falha não interrompe as outras.** Se o Teams não está instalado, os
/// outros três ainda devem abrir — quem pediu "abrir todos" quer o ambiente
/// montado, não uma verificação de integridade. Mas o resultado de cada um
/// volta: falhar em silêncio é o defeito que este projeto já corrigiu meia
/// dúzia de vezes.
///
/// `espera` entra por parâmetro para os testes poderem passar zero. Sem isso,
/// verificar a ordem de uma lista de quatro custaria mais de um segundo de
/// espera real por execução do teste.
pub fn abrir_todos<F>(ids: &[String], espera: Duration, mut abrir: F) -> Vec<Resultado>
where
    F: FnMut(&str) -> Result<(), String>,
{
    let mut saida = Vec::new();
    for (posicao, id) in ids.iter().take(MAX_PROGRAMAS).enumerate() {
        // A espera vai **antes** de cada abertura menos a primeira. Pôr depois
        // faria o agente dormir 400 ms à toa no fim de toda lista.
        if posicao > 0 && !espera.is_zero() {
            std::thread::sleep(espera);
        }
        saida.push(match abrir(id) {
            Ok(()) => Resultado {
                id: id.clone(),
                ok: true,
                error: None,
            },
            Err(motivo) => Resultado {
                id: id.clone(),
                ok: false,
                error: Some(motivo),
            },
        });
    }
    saida
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::cell::RefCell;

    #[test]
    fn abre_todos_na_ordem_da_lista() {
        // A ordem importa: o último a abrir fica por cima e em foco.
        let vistos: RefCell<Vec<String>> = RefCell::new(Vec::new());
        let ids = vec!["a".to_string(), "b".to_string(), "c".to_string()];
        let r = abrir_todos(&ids, Duration::ZERO, |id| {
            vistos.borrow_mut().push(id.to_string());
            Ok(())
        });
        assert_eq!(*vistos.borrow(), ["a", "b", "c"]);
        assert!(r.iter().all(|x| x.ok));
        assert_eq!(r.len(), 3);
    }

    #[test]
    fn uma_falha_nao_impede_as_outras() {
        // O caso real: o Teams não está instalado naquele computador. Os
        // outros três ainda têm de abrir - quem pediu o ambiente montado não
        // pediu uma verificação de integridade.
        let vistos: RefCell<Vec<String>> = RefCell::new(Vec::new());
        let ids = vec!["ok1".to_string(), "ruim".to_string(), "ok2".to_string()];
        let r = abrir_todos(&ids, Duration::ZERO, |id| {
            vistos.borrow_mut().push(id.to_string());
            if id == "ruim" {
                Err("não encontrei o programa".to_string())
            } else {
                Ok(())
            }
        });
        assert_eq!(*vistos.borrow(), ["ok1", "ruim", "ok2"]);
        assert_eq!(r[0].ok, true);
        assert_eq!(r[1].ok, false);
        assert_eq!(r[2].ok, true);
    }

    #[test]
    fn o_motivo_da_falha_volta_junto() {
        // Sem o motivo, "não abriu" e "não está instalado" chegam iguais ao
        // telefone, e a pessoa não sabe se tenta de novo ou se conserta o
        // perfil.
        let ids = vec!["x".to_string()];
        let r = abrir_todos(&ids, Duration::ZERO, |_| Err("sumiu".to_string()));
        assert_eq!(r[0].error.as_deref(), Some("sumiu"));
        assert!(!r[0].ok);
    }

    #[test]
    fn o_identificador_volta_para_o_app_casar() {
        let ids = vec!["C:\\um.lnk".to_string(), "C:\\dois.lnk".to_string()];
        let r = abrir_todos(&ids, Duration::ZERO, |_| Ok(()));
        assert_eq!(r[0].id, "C:\\um.lnk");
        assert_eq!(r[1].id, "C:\\dois.lnk");
    }

    #[test]
    fn lista_gigante_para_no_teto() {
        // Uma mensagem adulterada não pode mandar o computador abrir mil
        // janelas.
        let ids: Vec<String> = (0..500).map(|i| i.to_string()).collect();
        let contador = RefCell::new(0usize);
        let r = abrir_todos(&ids, Duration::ZERO, |_| {
            *contador.borrow_mut() += 1;
            Ok(())
        });
        assert_eq!(r.len(), MAX_PROGRAMAS);
        assert_eq!(*contador.borrow(), MAX_PROGRAMAS);
    }

    #[test]
    fn lista_vazia_nao_faz_nada_e_nao_quebra() {
        let r = abrir_todos(&[], Duration::ZERO, |_| -> Result<(), String> {
            panic!("não deveria abrir nada")
        });
        assert!(r.is_empty());
    }

    #[test]
    fn a_espera_fica_entre_as_aberturas_e_nao_no_fim() {
        // Três programas = duas esperas. Uma espera a mais no fim seria o
        // agente dormindo à toa em toda lista.
        let ids = vec!["a".to_string(), "b".to_string(), "c".to_string()];
        let espera = Duration::from_millis(30);
        let comeco = std::time::Instant::now();
        abrir_todos(&ids, espera, |_| Ok(()));
        let gasto = comeco.elapsed();
        assert!(gasto >= espera * 2, "esperou de menos: {gasto:?}");
        assert!(gasto < espera * 3, "esperou de mais: {gasto:?}");
    }

    #[test]
    fn um_programa_so_nao_espera() {
        let ids = vec!["a".to_string()];
        let comeco = std::time::Instant::now();
        abrir_todos(&ids, Duration::from_millis(200), |_| Ok(()));
        assert!(comeco.elapsed() < Duration::from_millis(100));
    }
}
