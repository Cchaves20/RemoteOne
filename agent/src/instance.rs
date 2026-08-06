//! Uma instância só do agente por usuário, e um jeito de a segunda falar com
//! a primeira.
//!
//! Sem isto, o atalho do Menu Iniciar é uma armadilha: o agente já sobe no
//! login, então clicar no atalho subiria um **segundo** agente com o mesmo
//! `device_id`. Os dois conectariam ao backend, e o servidor entregaria os
//! comandos a um deles - qual, ninguém sabe. O sintoma seria o pior tipo: o
//! controle remoto funcionando pela metade, intermitente, sem erro nenhum
//! para explicar.
//!
//! O desenho tem duas peças:
//!
//! - Um **mutex nomeado** responde "já tem alguém rodando?". É a pergunta que
//!   o Windows sabe responder sem corrida: quem cria primeiro ganha.
//! - Um **evento nomeado** deixa a segunda instância pedir à primeira que
//!   mostre a janela, e sair. É o que faz clicar no atalho parecer "abrir o
//!   programa" em vez de não fazer nada.
//!
//! O prefixo `Local\` põe os dois no espaço de nomes **da sessão**, e não da
//! máquina. Dois usuários no mesmo computador têm cada um o seu agente, e
//! travar o segundo por causa do primeiro seria errado.

/// O que fazer ao subir.
pub enum Start {
    /// Somos o agente desta sessão. O guarda precisa continuar vivo enquanto
    /// o processo viver - largá-lo liberaria o nome para um segundo agente.
    Primeira(Guard),
    /// Já havia um agente rodando; este processo pediu a janela e deve sair.
    JaRodando,
}

pub use imp::{escutar_pedidos_de_janela, reivindicar, Guard};

/// Texto no formato que as APIs do Windows esperam: UTF-16 terminado em zero.
///
/// Fora do módulo de plataforma porque é conversão de texto, não chamada de
/// sistema - e é a única parte disto que dá para testar em qualquer máquina.
/// O zero final não é detalhe: sem ele o Windows lê memória adiante até achar
/// um, e o nome do mutex vira lixo diferente a cada execução.
fn wide(s: &str) -> Vec<u16> {
    s.encode_utf16().chain(std::iter::once(0)).collect()
}

#[cfg(windows)]
mod imp {
    use super::{wide, Start};

    const NOME_MUTEX: &str = r"Local\DesksideAgent.instancia";
    const NOME_EVENTO: &str = r"Local\DesksideAgent.mostrar-janela";

    const ERROR_ALREADY_EXISTS: u32 = 183;
    const EVENT_MODIFY_STATE: u32 = 0x0002;
    const WAIT_OBJECT_0: u32 = 0;
    const INFINITE: u32 = 0xFFFF_FFFF;

    #[link(name = "kernel32")]
    extern "system" {
        fn CreateMutexW(attrs: *const u8, dono_inicial: i32, nome: *const u16) -> isize;
        fn CreateEventW(
            attrs: *const u8,
            reset_manual: i32,
            estado_inicial: i32,
            nome: *const u16,
        ) -> isize;
        fn OpenEventW(acesso: u32, herdar: i32, nome: *const u16) -> isize;
        fn SetEvent(handle: isize) -> i32;
        fn WaitForSingleObject(handle: isize, ms: u32) -> u32;
        fn CloseHandle(handle: isize) -> i32;
        fn GetLastError() -> u32;
    }

    /// Mantém o nome reservado. Ao ser descartado, libera-o.
    pub struct Guard(isize);

    impl Drop for Guard {
        fn drop(&mut self) {
            unsafe { CloseHandle(self.0) };
        }
    }

    // O handle é do processo, não da thread: pode atravessar threads sem
    // perigo. Sem isto ele não caberia numa estrutura movida para o laço.
    unsafe impl Send for Guard {}

    /// Tenta ser o agente desta sessão.
    pub fn reivindicar() -> Start {
        let nome = wide(NOME_MUTEX);
        let handle = unsafe { CreateMutexW(std::ptr::null(), 0, nome.as_ptr()) };
        // Handle nulo é falha do próprio Windows (memória, política). Seguir
        // como primeira instância é a escolha certa: melhor um agente a mais
        // num caso raríssimo do que nenhum agente por causa de um mutex.
        if handle == 0 {
            eprintln!("Não consegui checar se já havia um agente rodando; seguindo mesmo assim");
            return Start::Primeira(Guard(0));
        }
        if unsafe { GetLastError() } == ERROR_ALREADY_EXISTS {
            // O handle é nosso mesmo assim, e precisa ser devolvido.
            unsafe { CloseHandle(handle) };
            pedir_janela();
            return Start::JaRodando;
        }
        Start::Primeira(Guard(handle))
    }

    /// Pede ao agente que já está rodando que mostre a janela.
    fn pedir_janela() {
        let nome = wide(NOME_EVENTO);
        let evento = unsafe { OpenEventW(EVENT_MODIFY_STATE, 0, nome.as_ptr()) };
        if evento == 0 {
            // O outro agente é de uma versão anterior, que não escuta. Não é
            // erro: ele está rodando, que é o que importa.
            return;
        }
        unsafe {
            SetEvent(evento);
            CloseHandle(evento);
        }
    }

    /// Fica esperando pedidos de janela e chama `mostrar` a cada um.
    ///
    /// Bloqueia para sempre: o chamador deve pô-la numa thread própria.
    pub fn escutar_pedidos_de_janela(mostrar: impl Fn()) {
        let nome = wide(NOME_EVENTO);
        // Reset automático: cada `SetEvent` acorda exatamente uma espera, e o
        // evento volta sozinho ao estado apagado. Com reset manual, o primeiro
        // clique deixaria o laço girando sem parar.
        let evento = unsafe { CreateEventW(std::ptr::null(), 0, 0, nome.as_ptr()) };
        if evento == 0 {
            eprintln!("Não consegui escutar pedidos de janela; o atalho não vai abrir a tela");
            return;
        }
        loop {
            if unsafe { WaitForSingleObject(evento, INFINITE) } != WAIT_OBJECT_0 {
                break;
            }
            mostrar();
        }
        unsafe { CloseHandle(evento) };
    }
}

#[cfg(not(windows))]
mod imp {
    use super::Start;

    /// Fora do Windows não há instalação nem atalho: o agente roda no
    /// terminal do desenvolvimento, e travar a segunda cópia só atrapalharia
    /// quem está testando duas configurações lado a lado.
    pub struct Guard;

    pub fn reivindicar() -> Start {
        Start::Primeira(Guard)
    }

    pub fn escutar_pedidos_de_janela(_mostrar: impl Fn()) {
        // Sem janela e sem atalho: não há o que escutar.
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn nome_vira_utf16_terminado_em_zero() {
        assert_eq!(wide("ab"), vec![97, 98, 0]);
        assert_eq!(*wide(r"Local\x").last().unwrap(), 0);
    }

    #[test]
    fn nome_vazio_ainda_termina_em_zero() {
        // Um `Vec` vazio passado ao Windows seria leitura fora do que é nosso.
        assert_eq!(wide(""), vec![0]);
    }

    /// No Linux não há mutex nomeado, e o agente de desenvolvimento tem que
    /// poder subir duas vezes. No Windows este teste não vale: se houver um
    /// agente instalado rodando, a resposta correta é `JaRodando` - e chamar
    /// `reivindicar` aqui ainda pediria a janela dele.
    #[cfg(not(windows))]
    #[test]
    fn no_desenvolvimento_a_segunda_copia_tambem_sobe() {
        assert!(matches!(reivindicar(), Start::Primeira(_)));
        assert!(matches!(reivindicar(), Start::Primeira(_)));
    }
}
