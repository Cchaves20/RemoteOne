//! Pôr as janelas nos seus lugares.
//!
//! Abrir quatro programas empilhados um sobre o outro não é um ambiente
//! montado — é a mesma bagunça em três toques a menos. O que falta é cada um
//! abrir **no lugar certo**, como nos layouts de encaixe do Windows 11.
//!
//! ## O que o Windows deixa fazer, e o que não
//!
//! Não há API pública para *invocar* aquele menu de layouts. Há o que está por
//! trás dele: `SetWindowPos`, que põe uma janela em qualquer retângulo. É o
//! mesmo caminho do FancyZones, do PowerToys.
//!
//! Os atalhos de encaixe (`Win+Esquerda`) seriam mais fáceis — o agente já sabe
//! mandá-los — e são o caminho errado: só fazem metades e quartos, agem sobre a
//! **janela em foco**, e logo depois de abrir um programa o foco é a coisa mais
//! imprevisível que existe. Meio segundo de atraso e o atalho encaixa a janela
//! de outro programa.
//!
//! ## A parte difícil não é posicionar
//!
//! Posicionar é uma chamada. Descobrir **qual** janela pertence ao programa que
//! acabou de ser aberto é onde mora o trabalho:
//!
//! - o programa mostra uma tela de carregamento antes da janela de verdade;
//! - o processo lançado termina e quem abre a janela é outro — navegadores,
//!   Office, qualquer coisa em Electron;
//! - a janela pode aparecer três segundos depois, e até lá não há o que mover.
//!
//! A saída é não depender do processo: o agente fotografa quais janelas existem
//! **antes** de abrir e espera aparecer uma nova. Funciona igual para os três
//! casos acima, porque a pergunta deixa de ser "de quem é esta janela" e passa
//! a ser "qual janela não existia agora há pouco".
//!
//! A geometria é portável e está testada; a caça à janela é do Windows.

use serde::{Deserialize, Serialize};

/// Uma zona: o retângulo de células que uma janela ocupa numa grade.
///
/// **Células, e não frações.** Um layout de três colunas em frações seria
/// 0,333 cada, e três vezes 0,333 não fecha 1 — sobraria uma fresta de um ou
/// dois pixels entre as janelas, ou elas se sobreporiam. Com a grade, a borda
/// direita de uma zona é calculada pela mesma conta que a borda esquerda da
/// seguinte, e o encaixe é exato por construção.
///
/// A grade vem junto porque o agente **não conhece os layouts**: quem tem o
/// catálogo (metades, três colunas, 2×2, 2/3+1/3) é o app, que precisa dele
/// para desenhar o seletor. Aqui só chega "coluna 0 de 3, largura 2".
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
pub struct Zona {
    /// Quantas colunas e linhas a grade tem.
    pub cols: u32,
    pub rows: u32,
    /// Onde a zona começa, em células.
    pub col: u32,
    pub row: u32,
    /// Quantas células ela ocupa.
    #[serde(default = "uma")]
    pub colspan: u32,
    #[serde(default = "uma")]
    pub rowspan: u32,
}

fn uma() -> u32 {
    1
}

impl Zona {
    /// Se a zona cabe na grade que ela mesma declara.
    ///
    /// A zona chega pela rede. Uma coluna 5 numa grade de 2 colunas não é um
    /// erro de digitação a corrigir em silêncio — é um pedido que não faz
    /// sentido, e posicionar "o mais perto possível" poria a janela num lugar
    /// que ninguém escolheu.
    pub fn valida(&self) -> bool {
        self.cols > 0
            && self.rows > 0
            && self.colspan > 0
            && self.rowspan > 0
            && self.col + self.colspan <= self.cols
            && self.row + self.rowspan <= self.rows
    }
}

/// Um retângulo em pixels da tela.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Retangulo {
    pub x: i32,
    pub y: i32,
    pub largura: i32,
    pub altura: i32,
}

impl Retangulo {
    pub fn direita(&self) -> i32 {
        self.x + self.largura
    }
    pub fn base(&self) -> i32 {
        self.y + self.altura
    }
}

/// Converte uma zona no retângulo em pixels dentro da área útil.
///
/// `area` é a **área de trabalho**, não a resolução: é ela que exclui a barra
/// de tarefas. Usar a resolução deixaria a janela de baixo escondida atrás da
/// barra em todo layout com duas linhas.
///
/// As bordas saem de multiplicação e divisão inteiras sobre o índice da célula,
/// e não de somar larguras arredondadas. É isso que garante que a borda direita
/// de uma zona seja exatamente a esquerda da seguinte — somar `largura/3` três
/// vezes deixaria uma fresta.
pub fn retangulo(zona: &Zona, area: Retangulo) -> Option<Retangulo> {
    if !zona.valida() {
        return None;
    }
    let borda = |indice: u32, total: u32, tamanho: i32, inicio: i32| -> i32 {
        inicio + (tamanho as i64 * indice as i64 / total as i64) as i32
    };
    let esquerda = borda(zona.col, zona.cols, area.largura, area.x);
    let direita = borda(zona.col + zona.colspan, zona.cols, area.largura, area.x);
    let topo = borda(zona.row, zona.rows, area.altura, area.y);
    let base = borda(zona.row + zona.rowspan, zona.rows, area.altura, area.y);
    Some(Retangulo {
        x: esquerda,
        y: topo,
        largura: direita - esquerda,
        altura: base - topo,
    })
}

/// Quanto tempo esperar a janela de um programa aparecer.
///
/// Cinco segundos porque o pior caso comum é um Office ou um Electron em disco
/// mecânico. Passar disso não ajudaria: se a janela não veio até aqui, ou o
/// programa não abriu, ou ele não tem janela — e continuar esperando só
/// atrasaria os programas seguintes da lista.
pub const ESPERA_JANELA: std::time::Duration = std::time::Duration::from_secs(5);

/// De quanto em quanto tempo perguntar se a janela já apareceu.
pub const INTERVALO_BUSCA: std::time::Duration = std::time::Duration::from_millis(150);

#[cfg(windows)]
pub use imp::{area_de_trabalho, janelas_visiveis, posicionar_nova_janela};

#[cfg(windows)]
mod imp {
    use super::{Retangulo, Zona, ESPERA_JANELA, INTERVALO_BUSCA};
    use std::collections::HashSet;

    type Hwnd = isize;

    #[repr(C)]
    #[derive(Default, Clone, Copy)]
    struct Rect {
        left: i32,
        top: i32,
        right: i32,
        bottom: i32,
    }

    const SPI_GETWORKAREA: u32 = 0x0030;
    const GWL_EXSTYLE: i32 = -20;
    const WS_EX_TOOLWINDOW: u32 = 0x0000_0080;
    const SW_RESTORE: i32 = 9;
    // Não mexer na ordem de empilhamento nem roubar o foco: quem decide quem
    // fica por cima é a ordem de abertura, e ativar aqui faria a última janela
    // posicionada roubar o foco de quem o usuário já estava usando.
    const SWP_NOZORDER: u32 = 0x0004;
    const SWP_NOACTIVATE: u32 = 0x0010;

    #[link(name = "user32")]
    extern "system" {
        fn EnumWindows(callback: extern "system" fn(Hwnd, isize) -> i32, param: isize) -> i32;
        fn IsWindowVisible(hwnd: Hwnd) -> i32;
        fn IsIconic(hwnd: Hwnd) -> i32;
        fn IsZoomed(hwnd: Hwnd) -> i32;
        fn GetWindowTextLengthW(hwnd: Hwnd) -> i32;
        fn GetWindowLongW(hwnd: Hwnd, index: i32) -> i32;
        fn ShowWindow(hwnd: Hwnd, cmd: i32) -> i32;
        fn SetWindowPos(
            hwnd: Hwnd,
            insert_after: Hwnd,
            x: i32,
            y: i32,
            cx: i32,
            cy: i32,
            flags: u32,
        ) -> i32;
        fn SystemParametersInfoW(action: u32, param: u32, data: *mut Rect, ini: u32) -> i32;
    }

    thread_local! {
        /// Onde o `EnumWindows` deposita o que encontrou.
        ///
        /// A chamada do Windows leva uma função solta, não um fechamento, então
        /// não há como passar um `Vec` por captura. `thread_local` em vez de
        /// estático global porque duas listas sendo abertas ao mesmo tempo em
        /// threads diferentes não podem escrever no mesmo balde.
        static ENCONTRADAS: std::cell::RefCell<Vec<Hwnd>> =
            const { std::cell::RefCell::new(Vec::new()) };
    }

    extern "system" fn coletar(hwnd: Hwnd, _: isize) -> i32 {
        if candidata(hwnd) {
            ENCONTRADAS.with(|v| v.borrow_mut().push(hwnd));
        }
        1 // continuar enumerando
    }

    /// Se esta janela pode ser a janela principal de um programa.
    ///
    /// Três filtros, e cada um tira uma classe inteira de falso positivo:
    /// invisível (janela de mensagem que todo processo tem), sem título (a
    /// janela oculta que muitos frameworks criam) e "tool window" (paletas,
    /// dicas, bandeja). Sem eles, "a janela nova" seria quase sempre uma janela
    /// interna que ninguém vê.
    fn candidata(hwnd: Hwnd) -> bool {
        unsafe {
            IsWindowVisible(hwnd) != 0
                && GetWindowTextLengthW(hwnd) > 0
                && (GetWindowLongW(hwnd, GWL_EXSTYLE) as u32) & WS_EX_TOOLWINDOW == 0
        }
    }

    /// As janelas de nível superior que existem agora.
    pub fn janelas_visiveis() -> HashSet<Hwnd> {
        ENCONTRADAS.with(|v| v.borrow_mut().clear());
        unsafe {
            EnumWindows(coletar, 0);
        }
        ENCONTRADAS.with(|v| v.borrow().iter().copied().collect())
    }

    /// A área útil da tela principal: a resolução menos a barra de tarefas.
    pub fn area_de_trabalho() -> Option<Retangulo> {
        let mut r = Rect::default();
        let ok = unsafe { SystemParametersInfoW(SPI_GETWORKAREA, 0, &mut r, 0) };
        if ok == 0 {
            return None;
        }
        Some(Retangulo {
            x: r.left,
            y: r.top,
            largura: r.right - r.left,
            altura: r.bottom - r.top,
        })
    }

    /// Espera aparecer uma janela que não existia antes e a põe na zona.
    ///
    /// `antes` é a fotografia tirada **antes** de abrir o programa. Comparar com
    /// ela é o que dispensa saber de qual processo a janela é — e é por isso que
    /// funciona com navegador, Office e Electron, em que quem abre a janela não
    /// é o processo que foi lançado.
    ///
    /// Devolve o motivo quando não deu, e nunca em silêncio: "abriu, mas não
    /// consegui posicionar" é uma informação que a pessoa precisa ter para
    /// entender por que a tela não ficou como ela montou.
    pub fn posicionar_nova_janela(antes: &HashSet<Hwnd>, zona: &Zona) -> Result<(), String> {
        let area = area_de_trabalho().ok_or("não descobri a área de trabalho da tela")?;
        let alvo = super::retangulo(zona, area).ok_or("zona fora da grade")?;

        let limite = std::time::Instant::now() + ESPERA_JANELA;
        let hwnd = loop {
            if let Some(nova) = janelas_visiveis().difference(antes).copied().next() {
                break nova;
            }
            if std::time::Instant::now() >= limite {
                return Err("o programa abriu, mas a janela dele não apareceu a tempo".into());
            }
            std::thread::sleep(INTERVALO_BUSCA);
        };

        unsafe {
            // Janela maximizada ignora o tamanho pedido: ela volta a ocupar a
            // tela inteira no próximo desenho. Restaurar antes é o que faz o
            // encaixe pegar - e é a diferença entre "não funcionou" e
            // "funcionou em alguns programas".
            if IsZoomed(hwnd) != 0 || IsIconic(hwnd) != 0 {
                ShowWindow(hwnd, SW_RESTORE);
            }
            let ok = SetWindowPos(
                hwnd,
                0,
                alvo.x,
                alvo.y,
                alvo.largura,
                alvo.altura,
                SWP_NOZORDER | SWP_NOACTIVATE,
            );
            if ok == 0 {
                return Err("o Windows recusou mover a janela".into());
            }
        }
        Ok(())
    }
}

#[cfg(not(windows))]
pub use imp::{area_de_trabalho, janelas_visiveis, posicionar_nova_janela};

#[cfg(not(windows))]
mod imp {
    use super::{Retangulo, Zona};
    use std::collections::HashSet;

    pub fn janelas_visiveis() -> HashSet<isize> {
        HashSet::new()
    }

    pub fn area_de_trabalho() -> Option<Retangulo> {
        None
    }

    pub fn posicionar_nova_janela(_antes: &HashSet<isize>, _zona: &Zona) -> Result<(), String> {
        Err("posicionar janela só no Windows".into())
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    /// Uma tela de 1920×1080 com a barra de tarefas embaixo.
    fn tela() -> Retangulo {
        Retangulo {
            x: 0,
            y: 0,
            largura: 1920,
            altura: 1032,
        }
    }

    fn zona(cols: u32, rows: u32, col: u32, row: u32, colspan: u32, rowspan: u32) -> Zona {
        Zona {
            cols,
            rows,
            col,
            row,
            colspan,
            rowspan,
        }
    }

    #[test]
    fn metades_dividem_a_tela_ao_meio() {
        let esq = retangulo(&zona(2, 1, 0, 0, 1, 1), tela()).unwrap();
        let dir = retangulo(&zona(2, 1, 1, 0, 1, 1), tela()).unwrap();
        assert_eq!(esq.x, 0);
        assert_eq!(esq.largura, 960);
        assert_eq!(dir.x, 960);
        assert_eq!(dir.largura, 960);
        // Altura inteira nas duas: a barra de tarefas já saiu da conta.
        assert_eq!(esq.altura, 1032);
    }

    #[test]
    fn tres_colunas_nao_deixam_fresta_nem_sobra() {
        // 1920/3 é exato, mas 1032/1 e larguras ímpares não são. O que se fixa
        // aqui é a regra que vale para qualquer largura: a borda direita de uma
        // é exatamente a esquerda da seguinte, e a última fecha na tela.
        let area = Retangulo {
            x: 0,
            y: 0,
            largura: 1001,
            altura: 700,
        };
        let a = retangulo(&zona(3, 1, 0, 0, 1, 1), area).unwrap();
        let b = retangulo(&zona(3, 1, 1, 0, 1, 1), area).unwrap();
        let c = retangulo(&zona(3, 1, 2, 0, 1, 1), area).unwrap();
        assert_eq!(a.direita(), b.x, "fresta entre a primeira e a segunda");
        assert_eq!(b.direita(), c.x, "fresta entre a segunda e a terceira");
        assert_eq!(c.direita(), 1001, "a última não fecha na borda da tela");
        assert_eq!(a.largura + b.largura + c.largura, 1001);
    }

    #[test]
    fn quadrantes_cobrem_a_tela_inteira() {
        let g = |col, row| retangulo(&zona(2, 2, col, row, 1, 1), tela()).unwrap();
        let (se, sd, ie, id) = (g(0, 0), g(1, 0), g(0, 1), g(1, 1));
        assert_eq!(se.direita(), sd.x);
        assert_eq!(se.base(), ie.y);
        assert_eq!(sd.base(), id.y);
        assert_eq!(id.direita(), 1920);
        assert_eq!(id.base(), 1032);
        let soma: i64 = [se, sd, ie, id]
            .iter()
            .map(|r| r.largura as i64 * r.altura as i64)
            .sum();
        assert_eq!(soma, 1920 * 1032);
    }

    #[test]
    fn dois_tercos_e_um_terco() {
        // O layout 2/3 + 1/3 do Windows: uma zona ocupa duas células de três.
        let grande = retangulo(&zona(3, 1, 0, 0, 2, 1), tela()).unwrap();
        let pequena = retangulo(&zona(3, 1, 2, 0, 1, 1), tela()).unwrap();
        assert_eq!(grande.largura, 1280);
        assert_eq!(pequena.largura, 640);
        assert_eq!(grande.direita(), pequena.x);
    }

    #[test]
    fn uma_principal_e_duas_empilhadas() {
        // Esquerda inteira, direita dividida em cima e embaixo.
        let esq = retangulo(&zona(2, 2, 0, 0, 1, 2), tela()).unwrap();
        let cima = retangulo(&zona(2, 2, 1, 0, 1, 1), tela()).unwrap();
        let baixo = retangulo(&zona(2, 2, 1, 1, 1, 1), tela()).unwrap();
        assert_eq!(esq.altura, 1032);
        assert_eq!(cima.base(), baixo.y);
        assert_eq!(baixo.base(), 1032);
        assert_eq!(esq.direita(), cima.x);
    }

    #[test]
    fn a_area_de_trabalho_desloca_tudo() {
        // Barra de tarefas em cima (ou na esquerda): a área não começa em 0,0 e
        // as janelas não podem começar em 0,0 tampouco.
        let area = Retangulo {
            x: 0,
            y: 48,
            largura: 1920,
            altura: 1032,
        };
        let r = retangulo(&zona(2, 1, 0, 0, 1, 1), area).unwrap();
        assert_eq!(r.y, 48);
        assert_eq!(r.base(), 1080);
    }

    #[test]
    fn zona_fora_da_grade_e_recusada() {
        // Chega pela rede. Posicionar "o mais perto possível" poria a janela num
        // lugar que ninguém escolheu - melhor recusar e dizer.
        assert!(retangulo(&zona(2, 1, 2, 0, 1, 1), tela()).is_none());
        assert!(retangulo(&zona(2, 2, 0, 0, 3, 1), tela()).is_none());
        assert!(retangulo(&zona(2, 2, 1, 1, 1, 2), tela()).is_none());
    }

    #[test]
    fn grade_de_tamanho_zero_nao_divide_por_zero() {
        assert!(retangulo(&zona(0, 1, 0, 0, 1, 1), tela()).is_none());
        assert!(retangulo(&zona(2, 0, 0, 0, 1, 1), tela()).is_none());
        assert!(retangulo(&zona(2, 1, 0, 0, 0, 1), tela()).is_none());
    }

    #[test]
    fn a_zona_atravessa_o_json_sem_perder_o_tamanho() {
        // O app manda isto pela rede; um campo perdido viraria uma janela no
        // lugar errado, que é mais confuso que uma que não se moveu.
        let z = zona(3, 2, 1, 0, 2, 1);
        let json = serde_json::to_string(&z).unwrap();
        assert_eq!(serde_json::from_str::<Zona>(&json).unwrap(), z);
    }

    #[test]
    fn sem_colspan_no_json_vale_uma_celula() {
        // O caso comum é ocupar uma célula só, e obrigar o app a escrever
        // `"colspan":1` em todo item seria peso sem informação.
        let z: Zona = serde_json::from_str(r#"{"cols":2,"rows":1,"col":1,"row":0}"#).unwrap();
        assert_eq!(z.colspan, 1);
        assert_eq!(z.rowspan, 1);
        assert!(z.valida());
    }

    #[test]
    fn tela_estreita_ainda_da_retangulos_positivos() {
        // Uma tela de tablet em pé com quatro zonas: cada uma fica pequena, mas
        // nenhuma pode ficar com largura negativa ou zero.
        let area = Retangulo {
            x: 0,
            y: 0,
            largura: 800,
            altura: 1280,
        };
        for col in 0..2 {
            for row in 0..2 {
                let r = retangulo(&zona(2, 2, col, row, 1, 1), area).unwrap();
                assert!(r.largura > 0 && r.altura > 0, "{r:?}");
            }
        }
    }
}
