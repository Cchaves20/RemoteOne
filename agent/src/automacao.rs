//! Automações: uma sequência de passos, executada num toque.
//!
//! É o "abrir todos" levado até o fim. Aquele abre programas; uma automação faz
//! o que a pessoa faria com os dedos depois de abri-los — silenciar o som,
//! baixar o brilho, mandar um atalho, suspender a máquina.
//!
//! Os dois exemplos que motivaram isto:
//!
//! - **Modo Reunião** — abrir Teams à esquerda, OneNote à direita, silenciar,
//!   brilho a 80%.
//! - **Fim do expediente** — fechar Slack, fechar Outlook, brilho no mínimo,
//!   suspender.
//!
//! ## O limite que define o recurso
//!
//! Um passo é **uma ação que o agente já sabia fazer**. Não há aqui nenhuma
//! capacidade nova: o conjunto do que uma automação pode fazer é exatamente o
//! conjunto do que a pessoa já podia fazer tocando nos botões. Isso não é
//! economia de esforço — é o que impede a automação de virar uma porta lateral
//! para poderes que o resto do produto não dá.
//!
//! ## Por que a espera é por passo
//!
//! Abrir um programa e mandar `Ctrl+F9` no instante seguinte não faz nada: o
//! programa ainda não existe para receber a tecla. Quem sabe quanto esperar é
//! quem montou a automação — o OBS demora cinco segundos, o Bloco de Notas
//! demora zero. Um valor fixo serviria mal aos dois.
//!
//! ## O que é portável e o que não é
//!
//! Este módulo tem a **ordem, a espera, os tetos e o relatório** — tudo o que
//! erra e tudo o que dá para testar fora do Windows. Quem executa cada passo
//! entra por parâmetro, e mora no `client.rs`.

use serde::{Deserialize, Serialize};
use std::time::Duration;

use crate::input::{InputAction, MediaAction};
use crate::janelas::Zona;
use crate::protocol::PowerAction;

/// Teto de passos numa automação.
///
/// Vinte e quatro é muito mais do que qualquer rotina real precisa; o número
/// não está aqui para a interface, e sim para o caso de uma mensagem adulterada
/// mandar o computador fazer mil coisas.
pub const MAX_PASSOS: usize = 24;

/// Teto da espera de **um** passo.
///
/// Dez segundos cobrem o pior caso comum: um Office ou um Electron abrindo em
/// disco mecânico. Acima disso, quem monta a automação está tentando resolver
/// com espera um problema que espera não resolve.
pub const MAX_ESPERA_PASSO: Duration = Duration::from_secs(10);

/// Teto da espera **somada** de uma automação.
///
/// Sem ele, vinte e quatro passos de dez segundos parariam o agente por quatro
/// minutos. Estourado o orçamento, os passos seguintes continuam rodando — só
/// não esperam mais: interromper a automação por causa de uma pausa seria
/// punir a pessoa errada.
pub const ORCAMENTO_DE_ESPERA: Duration = Duration::from_secs(60);

/// Um passo de uma automação.
///
/// `wait_ms` é a pausa **depois** deste passo, e não antes: o que se espera é o
/// efeito do que acabou de acontecer (o programa terminar de abrir), e escrever
/// isso como "abrir, esperar" é como a pessoa pensa.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct Passo {
    #[serde(flatten)]
    pub acao: Acao,
    /// Milissegundos a esperar depois deste passo. Ausente = não espera.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub wait_ms: Option<u32>,
}

/// O que um passo faz.
///
/// Fechado de propósito: cada variante corresponde a algo que o agente já
/// expõe por outro caminho. Acrescentar uma capacidade aqui é uma decisão
/// consciente, e não um efeito colateral de a lista ser aberta.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(tag = "kind", rename_all = "snake_case")]
pub enum Acao {
    /// Abre um programa, opcionalmente encaixando a janela numa zona.
    Launch {
        id: String,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        zone: Option<Zona>,
    },
    /// Fecha um programa **pelo nome do processo** (`slack`, `outlook`).
    ///
    /// Por nome e não por PID, ao contrário do `close_app` da tela de
    /// aplicativos: uma automação é escrita hoje e rodada amanhã, e o PID de
    /// hoje não existe amanhã.
    Close { name: String },
    /// Fecha **todos** os programas abertos de uma vez.
    ///
    /// Existe porque a alternativa era listar cada programa num passo `Close`,
    /// e "fim do expediente" não é uma lista fixa: o que está aberto hoje é
    /// diferente do que estava ontem. Um passo que pergunta ao computador o que
    /// está aberto acerta sempre; uma lista escrita à mão envelhece na semana
    /// seguinte.
    ///
    /// Não leva campo nenhum de propósito. Exceções ("menos o Spotify")
    /// virariam uma lista para manter, com o mesmo problema de envelhecer - e
    /// quem quer isso põe o `CloseAll` antes e um `Launch` depois.
    CloseAll,
    /// Manda uma tecla, um atalho ou um texto.
    Input { action: InputAction },
    /// Tecla de mídia: tocar/pausar, próxima, volume, silenciar.
    Media { action: MediaAction },
    /// Ajusta o brilho da tela, em valor absoluto ou em passo relativo.
    Brightness {
        #[serde(default, skip_serializing_if = "Option::is_none")]
        level: Option<u8>,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        delta: Option<i16>,
    },
    /// Desliga, reinicia ou suspende. **Sempre o último que faz sentido** —
    /// o que vier depois não roda, porque a máquina já foi.
    Power { action: PowerAction },
}

impl Acao {
    /// Se este passo é irreversível o bastante para o app confirmar antes.
    ///
    /// Fechar um programa pode perder trabalho não salvo; desligar, mais
    /// ainda. Quem decide **mostrar** o aviso é o app, mas quem sabe quais
    /// passos são perigosos é aqui — a mesma lista serviria a outro cliente, e
    /// duas cópias divergiriam.
    pub fn destrutiva(&self) -> bool {
        matches!(
            self,
            Acao::Close { .. } | Acao::CloseAll | Acao::Power { .. }
        )
    }
}

/// Como terminou um passo.
#[derive(Debug, Clone, PartialEq)]
pub enum Desfecho {
    Ok,
    /// Aconteceu, com uma ressalva — tipicamente o posicionamento da janela.
    ComAviso(String),
    Falhou(String),
}

/// O que aconteceu com um passo, para o app mostrar.
///
/// Identificado pelo **índice**, e não por um nome: dois passos de uma
/// automação podem ser idênticos ("baixar o volume" duas vezes), e o app
/// precisa saber qual dos dois falhou.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct ResultadoPasso {
    pub index: usize,
    pub ok: bool,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub error: Option<String>,
}

/// Roda a automação em ordem e devolve o que aconteceu com cada passo.
///
/// **Uma falha não interrompe as seguintes.** Se o Slack não estava aberto para
/// ser fechado, o brilho ainda deve baixar e a máquina ainda deve suspender —
/// quem pediu "fim do expediente" quer o expediente encerrado, não uma
/// verificação de integridade. Mas o resultado de **cada** passo volta.
///
/// `dormir` entra por parâmetro para os testes verificarem os tetos sem esperar
/// de verdade: conferir o orçamento de sessenta segundos dormindo sessenta
/// segundos seria um teste que ninguém roda.
pub fn executar<D, A>(passos: &[Passo], mut dormir: D, mut agir: A) -> Vec<ResultadoPasso>
where
    D: FnMut(Duration),
    A: FnMut(&Acao) -> Desfecho,
{
    let mut saida = Vec::new();
    let mut gasto = Duration::ZERO;

    for (index, passo) in passos.iter().take(MAX_PASSOS).enumerate() {
        let (ok, error) = match agir(&passo.acao) {
            Desfecho::Ok => (true, None),
            Desfecho::ComAviso(aviso) => (true, Some(aviso)),
            Desfecho::Falhou(motivo) => (false, Some(motivo)),
        };
        saida.push(ResultadoPasso { index, ok, error });

        // A pausa vem **depois** do passo, e nunca depois do último: esperar no
        // fim seria o agente dormindo à toa com a automação já terminada.
        let ultimo = index + 1 >= passos.len().min(MAX_PASSOS);
        if ultimo {
            continue;
        }
        if let Some(ms) = passo.wait_ms {
            let pedida = Duration::from_millis(ms as u64).min(MAX_ESPERA_PASSO);
            let restante = ORCAMENTO_DE_ESPERA.saturating_sub(gasto);
            let real = pedida.min(restante);
            if !real.is_zero() {
                dormir(real);
                gasto += real;
            }
        }
    }
    saida
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::cell::RefCell;

    fn abrir(id: &str) -> Passo {
        Passo {
            acao: Acao::Launch {
                id: id.to_string(),
                zone: None,
            },
            wait_ms: None,
        }
    }

    fn esperando(mut p: Passo, ms: u32) -> Passo {
        p.wait_ms = Some(ms);
        p
    }

    /// Roda uma automação registrando as ações e as esperas pedidas.
    fn rodar(passos: &[Passo]) -> (Vec<ResultadoPasso>, Vec<Duration>) {
        let esperas: RefCell<Vec<Duration>> = RefCell::new(Vec::new());
        let r = executar(
            passos,
            |d| esperas.borrow_mut().push(d),
            |_| Desfecho::Ok,
        );
        let e = esperas.borrow().clone();
        (r, e)
    }

    #[test]
    fn executa_na_ordem_escrita() {
        // Numa automação a ordem é o recurso inteiro: abrir e só então mandar a
        // tecla. Trocar a ordem entrega outra coisa.
        let vistas: RefCell<Vec<String>> = RefCell::new(Vec::new());
        let passos = vec![abrir("a"), abrir("b"), abrir("c")];
        let r = executar(
            &passos,
            |_| {},
            |acao| {
                if let Acao::Launch { id, .. } = acao {
                    vistas.borrow_mut().push(id.clone());
                }
                Desfecho::Ok
            },
        );
        assert_eq!(*vistas.borrow(), ["a", "b", "c"]);
        assert_eq!(r.iter().map(|x| x.index).collect::<Vec<_>>(), [0, 1, 2]);
    }

    #[test]
    fn uma_falha_nao_interrompe_as_seguintes() {
        // Se o Slack não estava aberto para ser fechado, o brilho ainda deve
        // baixar e a máquina ainda deve suspender.
        let passos = vec![abrir("ok"), abrir("ruim"), abrir("depois")];
        let r = executar(
            &passos,
            |_| {},
            |acao| match acao {
                Acao::Launch { id, .. } if id == "ruim" => {
                    Desfecho::Falhou("não achei".into())
                }
                _ => Desfecho::Ok,
            },
        );
        assert!(r[0].ok);
        assert!(!r[1].ok);
        assert!(r[2].ok, "o passo depois da falha tem que rodar");
    }

    #[test]
    fn o_indice_identifica_o_passo() {
        // Dois passos podem ser idênticos ("baixar o volume" duas vezes), e o
        // app precisa saber qual dos dois falhou.
        let volume = Passo {
            acao: Acao::Media {
                action: MediaAction::VolumeDown,
            },
            wait_ms: None,
        };
        let passos = vec![volume.clone(), volume.clone(), volume];
        let mut n = 0;
        let r = executar(
            &passos,
            |_| {},
            |_| {
                n += 1;
                if n == 2 {
                    Desfecho::Falhou("x".into())
                } else {
                    Desfecho::Ok
                }
            },
        );
        assert_eq!(r[1].index, 1);
        assert!(!r[1].ok);
        assert!(r[0].ok && r[2].ok);
    }

    #[test]
    fn espera_depois_do_passo_e_nunca_no_fim() {
        // Esperar no fim seria o agente dormindo à toa com a automação já
        // terminada.
        let (_, esperas) = rodar(&[
            esperando(abrir("a"), 500),
            esperando(abrir("b"), 700),
        ]);
        assert_eq!(esperas, [Duration::from_millis(500)]);
    }

    #[test]
    fn passo_sem_espera_nao_dorme() {
        let (_, esperas) = rodar(&[abrir("a"), abrir("b")]);
        assert!(esperas.is_empty());
    }

    #[test]
    fn espera_gigante_e_aparada_no_teto() {
        // Uma automação com "espere uma hora" pararia a captura de tela junto.
        let (_, esperas) = rodar(&[esperando(abrir("a"), 3_600_000), abrir("b")]);
        assert_eq!(esperas, [MAX_ESPERA_PASSO]);
    }

    #[test]
    fn o_orcamento_total_limita_a_soma() {
        // Dez passos de dez segundos são cem segundos de espera; o orçamento é
        // de sessenta. Os passos continuam rodando - só param de esperar.
        let passos: Vec<Passo> = (0..10)
            .map(|i| esperando(abrir(&i.to_string()), 10_000))
            .collect();
        let (r, esperas) = rodar(&passos);
        assert_eq!(r.len(), 10, "todos os passos rodam");
        let soma: Duration = esperas.iter().sum();
        assert_eq!(soma, ORCAMENTO_DE_ESPERA);
    }

    #[test]
    fn automacao_gigante_para_no_teto_de_passos() {
        let passos: Vec<Passo> = (0..500).map(|i| abrir(&i.to_string())).collect();
        let contador = RefCell::new(0usize);
        let r = executar(
            &passos,
            |_| {},
            |_| {
                *contador.borrow_mut() += 1;
                Desfecho::Ok
            },
        );
        assert_eq!(r.len(), MAX_PASSOS);
        assert_eq!(*contador.borrow(), MAX_PASSOS);
    }

    #[test]
    fn automacao_vazia_nao_faz_nada() {
        let r = executar(&[], |_| panic!("não deveria esperar"), |_| {
            panic!("não deveria agir")
        });
        assert!(r.is_empty());
    }

    #[test]
    fn abriu_mas_nao_posicionou_continua_sendo_sucesso() {
        // O desfecho do meio, o mesmo do "abrir todos": o programa está lá, e a
        // janela é que não foi para o lugar.
        let r = executar(
            &[abrir("a")],
            |_| {},
            |_| Desfecho::ComAviso("a janela não apareceu a tempo".into()),
        );
        assert!(r[0].ok);
        assert_eq!(r[0].error.as_deref(), Some("a janela não apareceu a tempo"));
    }

    #[test]
    fn fechar_e_desligar_sao_destrutivos_e_o_resto_nao() {
        // É esta lista que o app usa para pedir confirmação. Uma automação que
        // suspende a máquina sem avisar seria uma surpresa cara.
        assert!(Acao::Close { name: "slack".into() }.destrutiva());
        // O que fecha tudo é o mais destrutivo dos três, e seria o mais fácil
        // de esquecer nesta lista: ele não tem campo nenhum, então um
        // `matches!` desatento o deixaria de fora sem o compilador reclamar.
        assert!(Acao::CloseAll.destrutiva());
        assert!(Acao::Power {
            action: PowerAction::Suspend
        }
        .destrutiva());
        assert!(!Acao::Launch {
            id: "a".into(),
            zone: None
        }
        .destrutiva());
        assert!(!Acao::Brightness {
            level: Some(80),
            delta: None
        }
        .destrutiva());
        assert!(!Acao::Media {
            action: MediaAction::Mute
        }
        .destrutiva());
    }

    #[test]
    fn o_modo_reuniao_atravessa_o_json() {
        // O exemplo que motivou o recurso, ponta a ponta pelo formato de fio.
        // Um campo perdido aqui viraria um passo que não acontece, e a pessoa
        // não teria como saber qual.
        let passos = vec![
            esperando(
                Passo {
                    acao: Acao::Launch {
                        id: "C:\\teams.lnk".into(),
                        zone: Some(Zona {
                            cols: 2,
                            rows: 1,
                            col: 0,
                            row: 0,
                            colspan: 1,
                            rowspan: 1,
                        }),
                    },
                    wait_ms: None,
                },
                2000,
            ),
            Passo {
                acao: Acao::Media {
                    action: MediaAction::Mute,
                },
                wait_ms: None,
            },
            Passo {
                acao: Acao::Brightness {
                    level: Some(80),
                    delta: None,
                },
                wait_ms: None,
            },
        ];
        let json = serde_json::to_string(&passos).unwrap();
        assert!(json.contains(r#""kind":"launch""#), "{json}");
        assert!(json.contains(r#""wait_ms":2000"#), "{json}");
        let volta: Vec<Passo> = serde_json::from_str(&json).unwrap();
        assert_eq!(volta, passos);
    }

    #[test]
    fn fechar_tudo_atravessa_o_json_sem_campo_nenhum() {
        // Sem campos, a variante é serializada só pela etiqueta. Se o `serde` a
        // escrevesse como `"CloseAll"` em vez de `"close_all"`, o app mandaria
        // um passo que o agente recusaria - e o erro só apareceria no
        // computador de alguém, na hora de rodar a automação.
        let json = serde_json::to_string(&Acao::CloseAll).unwrap();
        assert_eq!(json, r#"{"kind":"close_all"}"#);
        let volta: Acao = serde_json::from_str(&json).unwrap();
        assert_eq!(volta, Acao::CloseAll);
    }

    #[test]
    fn o_fim_do_expediente_atravessa_o_json() {
        let passos = vec![
            Passo {
                acao: Acao::Close {
                    name: "slack".into(),
                },
                wait_ms: None,
            },
            Passo {
                acao: Acao::Power {
                    action: PowerAction::Suspend,
                },
                wait_ms: None,
            },
        ];
        let json = serde_json::to_string(&passos).unwrap();
        let volta: Vec<Passo> = serde_json::from_str(&json).unwrap();
        assert_eq!(volta, passos);
    }

    #[test]
    fn passo_sem_wait_ms_no_json_nao_espera() {
        // O caso comum é não esperar, e exigir `"wait_ms":0` em todo passo
        // seria peso sem informação numa mensagem de até 24 itens.
        let p: Passo =
            serde_json::from_str(r#"{"kind":"media","action":"mute"}"#).unwrap();
        assert_eq!(p.wait_ms, None);
        assert!(matches!(
            p.acao,
            Acao::Media {
                action: MediaAction::Mute
            }
        ));
    }
}
