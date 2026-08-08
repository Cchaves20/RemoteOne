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

use crate::janelas::Zona;
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

/// Um programa da lista, com o lugar onde ele deve ficar.
#[derive(Debug, Clone, PartialEq, serde::Serialize, serde::Deserialize)]
pub struct Item {
    /// Caminho do atalho, como em `launch_app`.
    pub id: String,
    /// Onde a janela vai. `None` = abre onde o Windows quiser, que é o
    /// comportamento de sempre.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub zone: Option<Zona>,
}

/// Como terminou a tentativa de abrir **e** posicionar um programa.
///
/// São três desfechos, e não dois, porque "abriu mas não consegui posicionar"
/// não é nem sucesso nem falha: o programa está lá, e a tela não ficou como a
/// pessoa montou. Espremer isso num booleano obrigaria a escolher entre mentir
/// que deu tudo certo e dizer que o programa não abriu com ele à vista.
#[derive(Debug, Clone, PartialEq)]
pub enum Passo {
    Ok,
    /// Abriu, mas com uma ressalva - tipicamente o posicionamento.
    ComAviso(String),
    Falhou(String),
}

/// O que aconteceu com um programa da lista.
///
/// `ok = true` com `error` preenchido é o desfecho do meio: **abriu**, e algo
/// não saiu como pedido. O app mostra a ressalva sem dizer que o programa
/// falhou.
#[derive(Debug, Clone, PartialEq, serde::Serialize, serde::Deserialize)]
pub struct Resultado {
    /// O mesmo identificador que veio no pedido, para o app casar a resposta
    /// com o item da lista que ele mostrou.
    pub id: String,
    pub ok: bool,
    /// Por que não abriu, ou o que não saiu como pedido. Ausente quando tudo
    /// correu bem.
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
pub fn abrir_todos<F>(itens: &[Item], espera: Duration, mut executar: F) -> Vec<Resultado>
where
    F: FnMut(&Item) -> Passo,
{
    let mut saida = Vec::new();
    for (posicao, item) in itens.iter().take(MAX_PROGRAMAS).enumerate() {
        // A espera vai **antes** de cada abertura menos a primeira. Pôr depois
        // faria o agente dormir 400 ms à toa no fim de toda lista.
        //
        // Com zona, quem espera de verdade é o posicionamento (ele fica olhando
        // a janela aparecer); esta pausa continua valendo porque abrir quatro
        // programas pesados no mesmo instante faz os quatro demorarem mais.
        if posicao > 0 && !espera.is_zero() {
            std::thread::sleep(espera);
        }
        let (ok, error) = match executar(item) {
            Passo::Ok => (true, None),
            Passo::ComAviso(aviso) => (true, Some(aviso)),
            Passo::Falhou(motivo) => (false, Some(motivo)),
        };
        saida.push(Resultado {
            id: item.id.clone(),
            ok,
            error,
        });
    }
    saida
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::cell::RefCell;

    fn item(id: &str) -> Item {
        Item {
            id: id.to_string(),
            zone: None,
        }
    }

    fn itens(ids: &[&str]) -> Vec<Item> {
        ids.iter().map(|i| item(i)).collect()
    }

    #[test]
    fn abre_todos_na_ordem_da_lista() {
        // A ordem importa: o último a abrir fica por cima e em foco.
        let vistos: RefCell<Vec<String>> = RefCell::new(Vec::new());
        let r = abrir_todos(&itens(&["a", "b", "c"]), Duration::ZERO, |i| {
            vistos.borrow_mut().push(i.id.clone());
            Passo::Ok
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
        let r = abrir_todos(&itens(&["ok1", "ruim", "ok2"]), Duration::ZERO, |i| {
            vistos.borrow_mut().push(i.id.clone());
            if i.id == "ruim" {
                Passo::Falhou("não encontrei o programa".into())
            } else {
                Passo::Ok
            }
        });
        assert_eq!(*vistos.borrow(), ["ok1", "ruim", "ok2"]);
        assert!(r[0].ok);
        assert!(!r[1].ok);
        assert!(r[2].ok);
    }

    #[test]
    fn abriu_mas_nao_posicionou_nao_e_falha() {
        // O desfecho do meio, e o motivo de `Passo` ter três variantes: o
        // programa está lá. Dizer que ele não abriu, com ele à vista, mandaria
        // a pessoa procurar o problema no lugar errado - mas ficar calado
        // deixaria a tela fora do lugar sem explicação.
        let r = abrir_todos(&itens(&["x"]), Duration::ZERO, |_| {
            Passo::ComAviso("a janela não apareceu a tempo".into())
        });
        assert!(r[0].ok, "abriu, então não é falha");
        assert_eq!(r[0].error.as_deref(), Some("a janela não apareceu a tempo"));
    }

    #[test]
    fn o_motivo_da_falha_volta_junto() {
        // Sem o motivo, "não abriu" e "não está instalado" chegam iguais ao
        // telefone, e a pessoa não sabe se tenta de novo ou se conserta o
        // perfil.
        let r = abrir_todos(&itens(&["x"]), Duration::ZERO, |_| {
            Passo::Falhou("sumiu".into())
        });
        assert_eq!(r[0].error.as_deref(), Some("sumiu"));
        assert!(!r[0].ok);
    }

    #[test]
    fn o_identificador_volta_para_o_app_casar() {
        let r = abrir_todos(
            &itens(&["C:\\um.lnk", "C:\\dois.lnk"]),
            Duration::ZERO,
            |_| Passo::Ok,
        );
        assert_eq!(r[0].id, "C:\\um.lnk");
        assert_eq!(r[1].id, "C:\\dois.lnk");
    }

    #[test]
    fn a_zona_chega_junto_do_programa_certo() {
        // O erro que este teste existe para pegar: trocar as zonas de lugar,
        // que poria o navegador onde deveria estar o terminal. Sintoma
        // silencioso - tudo abre, tudo posiciona, e a tela fica errada.
        let esquerda = Zona {
            cols: 2,
            rows: 1,
            col: 0,
            row: 0,
            colspan: 1,
            rowspan: 1,
        };
        let direita = Zona { col: 1, ..esquerda };
        let lista = vec![
            Item {
                id: "navegador".into(),
                zone: Some(esquerda),
            },
            Item {
                id: "terminal".into(),
                zone: Some(direita),
            },
        ];
        let pares: RefCell<Vec<(String, u32)>> = RefCell::new(Vec::new());
        abrir_todos(&lista, Duration::ZERO, |i| {
            pares
                .borrow_mut()
                .push((i.id.clone(), i.zone.map(|z| z.col).unwrap_or(99)));
            Passo::Ok
        });
        assert_eq!(
            *pares.borrow(),
            [("navegador".to_string(), 0), ("terminal".to_string(), 1)]
        );
    }

    #[test]
    fn programa_sem_zona_abre_como_sempre() {
        // Posicionar é opcional por programa: um perfil pode ter três
        // posicionados e um solto.
        let lista = vec![
            item("solto"),
            Item {
                id: "encaixado".into(),
                zone: Some(Zona {
                    cols: 2,
                    rows: 1,
                    col: 0,
                    row: 0,
                    colspan: 1,
                    rowspan: 1,
                }),
            },
        ];
        let com_zona: RefCell<Vec<bool>> = RefCell::new(Vec::new());
        abrir_todos(&lista, Duration::ZERO, |i| {
            com_zona.borrow_mut().push(i.zone.is_some());
            Passo::Ok
        });
        assert_eq!(*com_zona.borrow(), [false, true]);
    }

    #[test]
    fn lista_gigante_para_no_teto() {
        // Uma mensagem adulterada não pode mandar o computador abrir mil
        // janelas.
        let lista: Vec<Item> = (0..500).map(|i| item(&i.to_string())).collect();
        let contador = RefCell::new(0usize);
        let r = abrir_todos(&lista, Duration::ZERO, |_| {
            *contador.borrow_mut() += 1;
            Passo::Ok
        });
        assert_eq!(r.len(), MAX_PROGRAMAS);
        assert_eq!(*contador.borrow(), MAX_PROGRAMAS);
    }

    #[test]
    fn lista_vazia_nao_faz_nada_e_nao_quebra() {
        let r = abrir_todos(&[], Duration::ZERO, |_| -> Passo {
            panic!("não deveria abrir nada")
        });
        assert!(r.is_empty());
    }

    #[test]
    fn a_espera_fica_entre_as_aberturas_e_nao_no_fim() {
        // Três programas = duas esperas. Uma espera a mais no fim seria o
        // agente dormindo à toa em toda lista.
        let espera = Duration::from_millis(30);
        let comeco = std::time::Instant::now();
        abrir_todos(&itens(&["a", "b", "c"]), espera, |_| Passo::Ok);
        let gasto = comeco.elapsed();
        assert!(gasto >= espera * 2, "esperou de menos: {gasto:?}");
        assert!(gasto < espera * 3, "esperou de mais: {gasto:?}");
    }

    #[test]
    fn um_programa_so_nao_espera() {
        let comeco = std::time::Instant::now();
        abrir_todos(&itens(&["a"]), Duration::from_millis(200), |_| Passo::Ok);
        assert!(comeco.elapsed() < Duration::from_millis(100));
    }

    #[test]
    fn o_item_atravessa_o_json_com_e_sem_zona() {
        let sem = item("a");
        let json = serde_json::to_string(&sem).unwrap();
        // Sem zona o campo nem viaja: é o caso comum, e ele vai numa mensagem
        // que pode ter dezesseis itens.
        assert!(!json.contains("zone"), "{json}");
        assert_eq!(serde_json::from_str::<Item>(&json).unwrap(), sem);

        let com = Item {
            id: "b".into(),
            zone: Some(Zona {
                cols: 3,
                rows: 1,
                col: 0,
                row: 0,
                colspan: 2,
                rowspan: 1,
            }),
        };
        let json = serde_json::to_string(&com).unwrap();
        assert_eq!(serde_json::from_str::<Item>(&json).unwrap(), com);
    }
}
