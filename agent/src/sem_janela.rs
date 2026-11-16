//! Lançar processos sem piscar console.
//!
//! ## O sintoma
//!
//! "O terminal no meu Dell está abrindo e fechando." Uma janela preta que
//! aparece e some, às vezes várias seguidas, enquanto o computador está sendo
//! controlado pelo celular.
//!
//! ## A causa
//!
//! O agente delega algumas tarefas a programas do próprio Windows: o
//! PowerShell lista os aplicativos instalados e extrai os ícones, o `cmd
//! /C start` abre um programa, o `taskkill` fecha, o `reg` escreve no
//! registro. Cada um desses é um processo de console — e o Windows, ao criar
//! um processo de console a partir de um programa sem console, **abre uma
//! janela para ele**. Ela vive o tempo do comando e some.
//!
//! Não é erro: é o padrão da plataforma. Quem não quer a janela precisa dizer,
//! e o jeito de dizer é a bandeira `CREATE_NO_WINDOW` na criação.
//!
//! ## Por que importa mais do que parece
//!
//! Num produto de controle remoto, quem vê a janela piscar **não é quem está
//! usando o app** — é quem está sentado na frente do computador controlado.
//! Para essa pessoa, janelas pretas aparecendo sozinhas é exatamente a
//! aparência de um computador invadido. O sintoma é cosmético; a leitura dele
//! não é.
//!
//! E há o caso do próprio dono: abrir a lista de programas pelo celular
//! dispara uma chamada de PowerShell por ícone. Não é uma janela piscando, são
//! várias em sequência.

/// Acrescenta a bandeira que impede o Windows de abrir console para o filho.
///
/// Um trait de extensão, e não uma função que devolve `Command`, porque assim
/// entra no meio de uma cadeia existente sem reescrevê-la:
///
/// ```ignore
/// Command::new("taskkill").sem_janela().args([...]).output()
/// ```
///
/// Fora do Windows não faz nada — devolve o próprio comando. Isso mantém as
/// chamadas iguais nos dois sistemas, em vez de espalhar `#[cfg(windows)]`
/// por cada lugar que lança um processo.
pub trait SemJanela {
    fn sem_janela(&mut self) -> &mut Self;
}

impl SemJanela for std::process::Command {
    #[cfg(windows)]
    fn sem_janela(&mut self) -> &mut Self {
        use std::os::windows::process::CommandExt;
        /// `CREATE_NO_WINDOW`, de `winbase.h`. O valor está aqui em vez de vir
        /// de um crate de ligações porque é uma constante só, e estável desde
        /// sempre — trazer uma dependência inteira para um número seria pior.
        const CREATE_NO_WINDOW: u32 = 0x0800_0000;
        self.creation_flags(CREATE_NO_WINDOW)
    }

    #[cfg(not(windows))]
    fn sem_janela(&mut self) -> &mut Self {
        self
    }
}
