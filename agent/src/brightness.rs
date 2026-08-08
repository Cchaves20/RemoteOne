//! Brilho da tela do computador.
//!
//! ## O que funciona, e o que não tem como funcionar
//!
//! Brilho por software só alcança o **painel embutido** de um notebook. O
//! Windows expõe isso pelo WMI (`WmiMonitorBrightnessMethods`), que é o mesmo
//! caminho que o controle deslizante da central de ações usa.
//!
//! Monitor externo é outra história: o ajuste ali viaja pelo cabo, em DDC/CI, e
//! depende de o monitor implementar o protocolo e de o fabricante não o ter
//! desligado. Muitos ignoram. Este módulo **não** tenta esse caminho, e a
//! consequência é assumida: num computador de mesa a resposta é um erro claro,
//! e não um comando que parece funcionar e não faz nada.
//!
//! ## Por que o passo relativo é resolvido aqui
//!
//! A barra de perfis manda "mais 10" e "menos 10", não um valor absoluto. Fazer
//! o telefone ler o brilho, somar e escrever custaria duas idas e voltas por
//! toque - e dois toques rápidos se atropelariam, porque os dois leriam o mesmo
//! valor antigo e o segundo desfaria o primeiro. Somar do lado do computador
//! resolve os dois problemas de uma vez.
//!
//! Real no Windows; nas demais plataformas, stub.

/// Onde parar quando o passo pedido sai da faixa.
///
/// Pura e separada da chamada ao sistema porque é aqui que mora o erro fácil:
/// somar num `u8` e estourar, ou deixar o brilho chegar a zero e a pessoa ficar
/// olhando para um painel apagado sem saber que foi ela quem fez isso.
///
/// O piso é 5 e não 0 de propósito. Um notebook com o brilho no zero parece
/// desligado, e quem está do outro lado do controle remoto não tem como
/// perceber que o que aconteceu foi um toque a mais no botão de diminuir.
pub fn aplicar_passo(atual: u8, delta: i16) -> u8 {
    const PISO: i32 = 5;
    let alvo = atual as i32 + delta as i32;
    alvo.clamp(PISO, 100) as u8
}

/// Ajusta o brilho e devolve o nível resultante.
///
/// `level` tem precedência sobre `delta` quando os dois vêm - não deveria
/// acontecer, mas uma mensagem malformada não pode virar comportamento
/// indefinido.
pub fn ajustar(level: Option<u8>, delta: Option<i16>) -> Result<u8, String> {
    match (level, delta) {
        (Some(nivel), _) => {
            let alvo = nivel.min(100);
            imp::definir(alvo)?;
            Ok(alvo)
        }
        (None, Some(passo)) => {
            let atual = imp::ler()?;
            let alvo = aplicar_passo(atual, passo);
            imp::definir(alvo)?;
            Ok(alvo)
        }
        (None, None) => Err("nenhum brilho pedido".to_string()),
    }
}

/// O brilho atual, de 0 a 100.
pub fn ler() -> Result<u8, String> {
    imp::ler()
}

#[cfg(windows)]
mod imp {
    /// Lê o brilho pelo WMI.
    ///
    /// `WmiMonitorBrightness` já responde em porcentagem (0–100), então não há
    /// conversão a fazer - ao contrário da temperatura, que vem em décimos de
    /// Kelvin.
    const LER: &str = r#"
$ErrorActionPreference = 'Stop'
(Get-CimInstance -Namespace root/WMI -ClassName WmiMonitorBrightness |
    Select-Object -First 1).CurrentBrightness
"#;

    pub fn ler() -> Result<u8, String> {
        let saida = crate::apps::run_powershell(LER)
            .map_err(|e| format!("não consegui perguntar o brilho: {e}"))?;
        interpretar(&String::from_utf8_lossy(&saida.stdout))
    }

    /// Lê a resposta do PowerShell.
    ///
    /// Vazia é o caso do computador de mesa: a classe do WMI existe, mas não há
    /// painel embutido para responder por ela. O erro precisa dizer isso, e não
    /// "falhou" - a diferença entre "seu monitor não permite" e "deu problema"
    /// é o que decide se a pessoa vai tentar de novo ou parar de tentar.
    fn interpretar(saida: &str) -> Result<u8, String> {
        let texto = saida.trim();
        if texto.is_empty() {
            return Err(
                "este computador não permite ajustar o brilho por software \
                 (só painel embutido de notebook)"
                    .to_string(),
            );
        }
        texto
            .parse::<u32>()
            .map(|v| v.min(100) as u8)
            .map_err(|_| format!("não entendi o brilho devolvido pelo Windows: {texto}"))
    }

    /// Escreve o brilho pelo WMI.
    ///
    /// O `Timeout` de 1 segundo é do próprio método: é por quanto tempo o
    /// Windows tenta antes de desistir, e não um tempo de transição.
    pub fn definir(nivel: u8) -> Result<(), String> {
        let script = format!(
            r#"
$ErrorActionPreference = 'Stop'
$m = Get-CimInstance -Namespace root/WMI -ClassName WmiMonitorBrightnessMethods |
    Select-Object -First 1
if ($null -eq $m) {{ Write-Error 'sem painel embutido' }}
Invoke-CimMethod -InputObject $m -MethodName WmiSetBrightness `
    -Arguments @{{ Brightness = [byte]{nivel}; Timeout = [uint32]1 }} | Out-Null
"#
        );
        let saida = crate::apps::run_powershell(&script)
            .map_err(|e| format!("não consegui ajustar o brilho: {e}"))?;
        if saida.status.success() {
            return Ok(());
        }
        // A mensagem do PowerShell é longa e cheia de detalhe de objeto; o que
        // interessa ao usuário é a primeira linha.
        let erro = String::from_utf8_lossy(&saida.stderr);
        let primeira = erro.lines().find(|l| !l.trim().is_empty()).unwrap_or("");
        Err(if primeira.is_empty() {
            "este computador não permite ajustar o brilho por software \
             (só painel embutido de notebook)"
                .to_string()
        } else {
            primeira.trim().to_string()
        })
    }

    #[cfg(test)]
    mod tests {
        use super::interpretar;

        #[test]
        fn le_o_numero() {
            assert_eq!(interpretar("60\r\n"), Ok(60));
        }

        #[test]
        fn resposta_vazia_explica_o_motivo() {
            let erro = interpretar("   ").unwrap_err();
            assert!(erro.contains("notebook"), "{erro}");
        }

        #[test]
        fn valor_acima_de_cem_e_aparado() {
            assert_eq!(interpretar("255"), Ok(100));
        }
    }
}

#[cfg(not(windows))]
mod imp {
    pub fn ler() -> Result<u8, String> {
        Err("ajuste de brilho só no Windows".to_string())
    }

    pub fn definir(nivel: u8) -> Result<(), String> {
        println!("[brightness-stub] poria o brilho em {nivel}%");
        Err("ajuste de brilho só no Windows".to_string())
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn o_passo_soma_e_subtrai() {
        assert_eq!(aplicar_passo(50, 10), 60);
        assert_eq!(aplicar_passo(50, -10), 40);
    }

    #[test]
    fn nao_passa_de_cem() {
        assert_eq!(aplicar_passo(95, 10), 100);
        assert_eq!(aplicar_passo(100, 50), 100);
    }

    #[test]
    fn nao_apaga_a_tela() {
        // Zero deixaria o painel parecendo desligado, e quem está do outro lado
        // do controle remoto não teria como perceber que foi um toque a mais.
        assert_eq!(aplicar_passo(10, -50), 5);
        assert_eq!(aplicar_passo(5, -10), 5);
    }

    #[test]
    fn passo_gigante_nao_estoura_o_tipo() {
        // Uma mensagem adulterada com delta 30000 não pode dar volta no `u8`.
        assert_eq!(aplicar_passo(50, i16::MAX), 100);
        assert_eq!(aplicar_passo(50, i16::MIN), 5);
    }

    #[test]
    fn sem_nivel_e_sem_passo_e_erro() {
        assert!(ajustar(None, None).is_err());
    }

    #[cfg(not(windows))]
    #[test]
    fn fora_do_windows_falha_com_explicacao() {
        // Falhar é o certo aqui; o que não pode é falhar em silêncio.
        let erro = ajustar(Some(50), None).unwrap_err();
        assert!(erro.contains("Windows"), "{erro}");
    }
}
