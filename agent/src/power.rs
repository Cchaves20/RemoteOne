//! Controle de energia do computador (desligar, reiniciar, suspender).
//!
//! Real no Windows; nas demais plataformas é um stub que apenas registra a
//! intenção — assim o agente compila e roda no Linux/macOS de desenvolvimento
//! sem executar nada destrutivo.
//!
//! ## Por que suspender não usa mais o `rundll32`
//!
//! A versão anterior fazia `rundll32.exe powrprof.dll,SetSuspendState 0,1,0`,
//! a receita que circula em todo lugar. Ela tem três defeitos, e juntos eles
//! produziam exatamente o que foi relatado — "aperto suspender e nada
//! acontece":
//!
//! 1. **O `0,1,0` nunca chega à função.** O `rundll32` só sabe chamar funções
//!    com a assinatura `(HWND, HINSTANCE, LPSTR, int)`. O que o
//!    `SetSuspendState` recebe como "hibernar?" é o primeiro desses argumentos
//!    — lixo diferente de zero. Então ele tenta **hibernar**, e num computador
//!    com a hibernação desligada, isso falha.
//! 2. **Ele sempre sai com sucesso.** O `rundll32` não repassa o retorno da
//!    função, e o agente registrava "suspendi" quando nada tinha acontecido.
//! 3. **O privilégio de desligar não é ligado.** Toda conta do Windows o
//!    **tem**, mas desligado; quem vai suspender precisa ligá-lo antes.
//!
//! Aqui a função é chamada direto, com os argumentos certos, depois de ligar
//! o privilégio, e o retorno dela é conferido.
//!
//! ## Computadores sem suspensão por comando
//!
//! Notebooks recentes — o Surface, todo Windows em ARM — usam a **espera
//! moderna** no lugar do sono clássico (S3). Neles não existe estado S3 para o
//! `SetSuspendState` entrar, e o Windows não oferece API pública para "entre
//! em espera agora": só o botão de energia, a tampa e o menu Iniciar fazem
//! isso. O gesto mais próximo ao alcance de um programa é **apagar a tela**, e
//! é o que se faz nesses computadores — dizendo isso no registro, em vez de
//! fingir que suspendeu.

use crate::protocol::PowerAction;

/// Executa a ação de energia solicitada.
pub fn apply(action: PowerAction) -> Result<(), String> {
    imp::apply(action)
}

/// O que este computador sabe fazer quando pedem para suspender.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
#[cfg_attr(not(windows), allow(dead_code))]
pub(crate) enum ComoSuspender {
    /// O sono clássico (S3), pelo `SetSuspendState`.
    Suspender,
    /// Espera moderna sem S3: apagar a tela é o que está ao alcance.
    ApagarATela,
}

/// Onde, dentro de `SYSTEM_POWER_CAPABILITIES`, estão os dois campos que
/// interessam.
///
/// A estrutura começa com uma fila de `BOOLEAN` (um byte cada, sem
/// preenchimento entre eles): `PowerButtonPresent`, `SleepButtonPresent`,
/// `LidPresent`, `SystemS1`, `SystemS2`, **`SystemS3`** (5), `SystemS4`,
/// `SystemS5`, `HiberFilePresent`, `FullWake`, `VideoDimPresent`, `ApmPresent`,
/// `UpsPresent`, `ThermalControl`, `ProcessorThrottle`, `ProcessorMinThrottle`,
/// `ProcessorMaxThrottle`, `FastSystemS4`, `Hiberboot`, `WakeAlarmPresent`,
/// **`AoAc`** (20).
///
/// `AoAc` ("always on, always connected") é o nome interno da espera moderna.
const DESLOCAMENTO_S3: usize = 5;
const DESLOCAMENTO_ESPERA_MODERNA: usize = 20;

/// `(tem_s3, espera_moderna)` a partir da estrutura crua que o Windows devolve.
///
/// Pura, e é a parte que dá para testar fora do Windows: um deslocamento
/// errado aqui faria o agente ler outro campo e escolher o caminho errado sem
/// erro nenhum.
#[cfg_attr(not(windows), allow(dead_code))]
pub(crate) fn capacidades(bruto: &[u8]) -> Option<(bool, bool)> {
    if bruto.len() <= DESLOCAMENTO_ESPERA_MODERNA {
        return None;
    }
    Some((
        bruto[DESLOCAMENTO_S3] != 0,
        bruto[DESLOCAMENTO_ESPERA_MODERNA] != 0,
    ))
}

/// Qual caminho seguir.
///
/// Havendo S3, ele vence — mesmo que o computador também declare espera
/// moderna, o sono clássico é o que a pessoa pediu e o que se sabe fazer. Sem
/// S3 e sem espera moderna (uma máquina virtual, por exemplo), tenta-se o
/// `SetSuspendState` mesmo assim: se o Windows recusar, a recusa é reportada.
#[cfg_attr(not(windows), allow(dead_code))]
pub(crate) fn como_suspender(tem_s3: bool, espera_moderna: bool) -> ComoSuspender {
    if !tem_s3 && espera_moderna {
        ComoSuspender::ApagarATela
    } else {
        ComoSuspender::Suspender
    }
}

#[cfg(windows)]
mod imp {
    use crate::sem_janela::SemJanela;
    use std::ffi::c_void;
    use std::process::Command;

    use crate::protocol::PowerAction;

    use super::ComoSuspender;

    type Handle = *mut c_void;

    #[repr(C)]
    struct Luid {
        low: u32,
        high: i32,
    }

    #[repr(C)]
    struct LuidAndAttributes {
        luid: Luid,
        attributes: u32,
    }

    #[repr(C)]
    struct TokenPrivileges {
        count: u32,
        privileges: [LuidAndAttributes; 1],
    }

    /// A estrutura de capacidades tem campos de 4 bytes adiante; o
    /// alinhamento de 8 garante que o Windows escreva neles alinhado.
    #[repr(C, align(8))]
    struct Capacidades([u8; 256]);

    const TOKEN_ADJUST_PRIVILEGES: u32 = 0x0020;
    const TOKEN_QUERY: u32 = 0x0008;
    const SE_PRIVILEGE_ENABLED: u32 = 0x0000_0002;
    const ERROR_NOT_ALL_ASSIGNED: u32 = 1300;

    const HWND_BROADCAST: isize = 0xFFFF;
    const WM_SYSCOMMAND: u32 = 0x0112;
    const SC_MONITORPOWER: usize = 0xF170;
    const TELA_DESLIGADA: isize = 2;

    #[link(name = "kernel32")]
    extern "system" {
        fn GetCurrentProcess() -> Handle;
        fn CloseHandle(objeto: Handle) -> i32;
        fn GetLastError() -> u32;
    }

    #[link(name = "advapi32")]
    extern "system" {
        fn OpenProcessToken(processo: Handle, acesso: u32, token: *mut Handle) -> i32;
        fn LookupPrivilegeValueW(sistema: *const u16, nome: *const u16, luid: *mut Luid) -> i32;
        fn AdjustTokenPrivileges(
            token: Handle,
            desligar_todos: i32,
            novos: *const TokenPrivileges,
            tamanho: u32,
            anteriores: *mut TokenPrivileges,
            tamanho_devolvido: *mut u32,
        ) -> i32;
    }

    #[link(name = "powrprof")]
    extern "system" {
        fn SetSuspendState(hibernar: u8, forcar: u8, sem_eventos_de_despertar: u8) -> u8;
        fn GetPwrCapabilities(capacidades: *mut u8) -> u8;
    }

    #[link(name = "user32")]
    extern "system" {
        fn PostMessageW(janela: isize, mensagem: u32, wparam: usize, lparam: isize) -> i32;
    }

    pub fn apply(action: PowerAction) -> Result<(), String> {
        match action {
            // /t 0 = sem contagem regressiva; /f força fechar apps travados.
            PowerAction::Shutdown => executar("shutdown", &["/s", "/f", "/t", "0"]),
            PowerAction::Restart => executar("shutdown", &["/r", "/f", "/t", "0"]),
            PowerAction::Suspend => suspender(),
        }
    }

    fn executar(programa: &str, argumentos: &[&str]) -> Result<(), String> {
        match Command::new(programa).sem_janela().args(argumentos).status() {
            Ok(s) if s.success() => Ok(()),
            Ok(s) => Err(format!("comando de energia falhou (código {s})")),
            Err(e) => Err(format!("não foi possível executar o comando: {e}")),
        }
    }

    fn suspender() -> Result<(), String> {
        // Sem conseguir ler as capacidades, tenta-se o caminho clássico: se o
        // Windows recusar, a recusa aparece — que é melhor do que adivinhar.
        let (tem_s3, espera_moderna) = ler_capacidades().unwrap_or((true, false));
        println!(
            "Suspender: sono clássico (S3) {}, espera moderna {}",
            sim_ou_nao(tem_s3),
            sim_ou_nao(espera_moderna)
        );

        match super::como_suspender(tem_s3, espera_moderna) {
            ComoSuspender::ApagarATela => {
                println!(
                    "Suspender: este computador usa espera moderna e não aceita \
                     suspender por comando; desligando a tela."
                );
                apagar_a_tela()
            }
            ComoSuspender::Suspender => {
                ligar_privilegio_de_desligar()?;
                // Síncrona: com sucesso, ela só volta quando o computador
                // acorda. Com falha, volta na hora — e é aí que o erro importa.
                let ok = unsafe { SetSuspendState(0, 0, 0) };
                if ok != 0 {
                    Ok(())
                } else {
                    let erro = unsafe { GetLastError() };
                    Err(format!("o Windows recusou suspender (erro {erro})"))
                }
            }
        }
    }

    fn ler_capacidades() -> Option<(bool, bool)> {
        // Bem maior que a estrutura real (uns 76 bytes): a API escreve o
        // tamanho que ela conhece, e um buffer folgado não estoura se uma
        // versão futura do Windows a aumentar.
        let mut bruto = Capacidades([0u8; 256]);
        let ok = unsafe { GetPwrCapabilities(bruto.0.as_mut_ptr()) };
        if ok == 0 {
            return None;
        }
        super::capacidades(&bruto.0)
    }

    /// Liga o `SeShutdownPrivilege` neste processo.
    ///
    /// Toda conta do Windows o possui, mas **desligado**. Sem ligá-lo, o
    /// `SetSuspendState` recusa com "privilégio não mantido".
    fn ligar_privilegio_de_desligar() -> Result<(), String> {
        let nome: Vec<u16> = "SeShutdownPrivilege"
            .encode_utf16()
            .chain(std::iter::once(0))
            .collect();
        unsafe {
            let mut token: Handle = std::ptr::null_mut();
            if OpenProcessToken(
                GetCurrentProcess(),
                TOKEN_ADJUST_PRIVILEGES | TOKEN_QUERY,
                &mut token,
            ) == 0
            {
                return Err(format!(
                    "não consegui abrir as permissões do agente (erro {})",
                    GetLastError()
                ));
            }

            let mut luid = Luid { low: 0, high: 0 };
            let resultado = if LookupPrivilegeValueW(std::ptr::null(), nome.as_ptr(), &mut luid) == 0 {
                Err(format!(
                    "o Windows não reconheceu a permissão de suspender (erro {})",
                    GetLastError()
                ))
            } else {
                let pedido = TokenPrivileges {
                    count: 1,
                    privileges: [LuidAndAttributes {
                        luid,
                        attributes: SE_PRIVILEGE_ENABLED,
                    }],
                };
                let ok = AdjustTokenPrivileges(
                    token,
                    0,
                    &pedido,
                    0,
                    std::ptr::null_mut(),
                    std::ptr::null_mut(),
                );
                // `AdjustTokenPrivileges` devolve sucesso até quando **não**
                // ligou nada; a resposta de verdade está no `GetLastError`, e
                // ele precisa ser lido logo em seguida.
                let erro = GetLastError();
                if ok == 0 || erro == ERROR_NOT_ALL_ASSIGNED {
                    Err(format!(
                        "esta conta do Windows não tem permissão de suspender (erro {erro})"
                    ))
                } else {
                    Ok(())
                }
            };
            CloseHandle(token);
            resultado
        }
    }

    /// Desliga a tela, pelo mesmo pedido que o Windows manda quando o tempo de
    /// tela se esgota.
    ///
    /// `PostMessage` e não `SendMessage`: mandar para todas as janelas e
    /// esperar a resposta de cada uma travaria o agente na primeira janela
    /// que estivesse sem responder.
    fn apagar_a_tela() -> Result<(), String> {
        let ok = unsafe {
            PostMessageW(HWND_BROADCAST, WM_SYSCOMMAND, SC_MONITORPOWER, TELA_DESLIGADA)
        };
        if ok != 0 {
            Ok(())
        } else {
            Err(format!("não consegui desligar a tela (erro {})", unsafe {
                GetLastError()
            }))
        }
    }

    fn sim_ou_nao(valor: bool) -> &'static str {
        if valor {
            "sim"
        } else {
            "não"
        }
    }
}

#[cfg(not(windows))]
mod imp {
    use crate::protocol::PowerAction;

    pub fn apply(action: PowerAction) -> Result<(), String> {
        println!("[power-stub] ação de energia solicitada: {action:?} (ignorada fora do Windows)");
        Ok(())
    }
}

#[cfg(test)]
mod tests {
    use super::{capacidades, como_suspender, ComoSuspender};

    /// Uma estrutura crua com só os dois campos que interessam preenchidos.
    fn estrutura(s3: bool, espera_moderna: bool) -> Vec<u8> {
        let mut bruto = vec![0u8; 76];
        bruto[5] = s3 as u8;
        bruto[20] = espera_moderna as u8;
        bruto
    }

    #[test]
    fn le_os_dois_campos_nas_posicoes_certas() {
        // Um deslocamento errado leria outro campo e escolheria o caminho
        // errado sem erro nenhum — é o defeito que só aparece num notebook.
        assert_eq!(capacidades(&estrutura(true, false)), Some((true, false)));
        assert_eq!(capacidades(&estrutura(false, true)), Some((false, true)));
    }

    #[test]
    fn campos_vizinhos_nao_se_confundem() {
        // S4 (hibernar) fica logo depois do S3. Um computador que só hiberna
        // não pode ser lido como se tivesse sono clássico.
        let mut bruto = vec![0u8; 76];
        bruto[6] = 1; // SystemS4
        bruto[19] = 1; // WakeAlarmPresent
        bruto[21] = 1; // DiskSpinDown
        assert_eq!(capacidades(&bruto), Some((false, false)));
    }

    #[test]
    fn estrutura_curta_demais_nao_e_lida() {
        assert_eq!(capacidades(&[0u8; 20]), None);
        assert_eq!(capacidades(&[]), None);
    }

    #[test]
    fn com_s3_suspende() {
        assert_eq!(como_suspender(true, false), ComoSuspender::Suspender);
        // Havendo S3, ele vence mesmo que o computador declare espera moderna.
        assert_eq!(como_suspender(true, true), ComoSuspender::Suspender);
    }

    #[test]
    fn espera_moderna_sem_s3_apaga_a_tela() {
        // Surface, Windows em ARM: não há S3 para o `SetSuspendState` entrar.
        assert_eq!(como_suspender(false, true), ComoSuspender::ApagarATela);
    }

    #[test]
    fn sem_nenhum_dos_dois_tenta_suspender_e_deixa_o_windows_responder() {
        // Máquina virtual, por exemplo. Se o Windows recusar, a recusa é
        // reportada — o que não pode é o agente adivinhar e dizer que deu certo.
        assert_eq!(como_suspender(false, false), ComoSuspender::Suspender);
    }
}
