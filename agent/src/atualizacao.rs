//! O agente se atualiza sozinho, sem a pessoa voltar ao site.
//!
//! ## Como ele sabe que há versão nova
//!
//! Pelo **conteúdo**, não pelo número. A versão do agente é `0.1.0` desde
//! sempre, e um mecanismo que dependesse de alguém lembrar de trocar o número
//! a cada build erraria na primeira vez que esquecessem. O `atualizar.ps1
//! -Publicar` põe ao lado de cada executável o SHA-256 dele
//! (`/baixar/Deskside.exe.sha256`); o agente calcula o do próprio arquivo e
//! compara. Diferente é atualização.
//!
//! ## Como ele troca o próprio arquivo
//!
//! Um executável em uso não pode ser sobrescrito no Windows — mas pode ser
//! **renomeado**, e quem sai do caminho não precisa sair da memória. Mesmo
//! assim a troca não é feita pelo agente que está rodando: quem a faz é um
//! **ajudante**, uma cópia do executável atual com outro nome, porque alguém
//! precisa sobreviver ao agente velho para conferir se o novo funciona.
//!
//! 1. O agente baixa o novo para `deskside-agent.new.exe`, confere o resumo,
//!    copia a si mesmo para `deskside-atualizador.exe`, chama essa cópia e sai.
//! 2. O ajudante espera o agente velho terminar, renomeia `deskside-agent.exe`
//!    para `.old.exe` e o `.new.exe` para `deskside-agent.exe`, e sobe o novo.
//! 3. O novo agente, depois de ficar conectado ao servidor por 10 segundos
//!    seguidos, grava `atualizacao.ok`. É a prova de que a versão nova serve:
//!    abrir a janela não bastaria, o produto é o computador ficar alcançável.
//!    E "conectado" sozinho também não: ele é marcado quando o socket abre,
//!    antes do `Hello`, e uma versão que caísse logo depois passaria.
//! 4. Com a prova, o ajudante apaga o `.old.exe`. Sem ela em 90 segundos, ou
//!    se o novo cair antes, ele **desfaz**: encerra o novo, devolve o velho ao
//!    lugar e o sobe de novo. Uma atualização ruim custa um minuto e meio fora
//!    do ar, não um computador perdido até alguém ir até ele — que, num
//!    produto de acesso remoto, é justamente o que a pessoa não pode fazer.
//!
//! O caminho do executável nunca muda, então a tarefa do logon, o atalho do
//! Menu Iniciar e a entrada em "Aplicativos instalados" continuam valendo sem
//! ninguém tocar neles.
//!
//! ## Por que não uma biblioteca de HTTP
//!
//! O agente já fala TLS — é o `native-tls` do WebSocket, que no Windows usa o
//! SChannel do próprio sistema. Um GET de um arquivo estático é pouco código
//! por cima dele, e uma biblioteca de HTTP traria dezenas de crates a mais e
//! mais uma chance de o build do ARM64 quebrar. O que se interpreta é um
//! cabeçalho e um tamanho: o Caddy serve arquivo estático sempre com
//! `Content-Length`, e uma resposta em pedaços (`chunked`) é recusada em vez
//! de mal lida.
//!
//! O pedido é HTTP/1.1, e não 1.0, que dispensaria até essa recusa: foi
//! testado, e um proxy no caminho (Envoy, o mais comum deles) responde 426 a
//! qualquer HTTP/1.0. Numa rede de empresa isso seria "não há atualização",
//! para sempre, sem erro que explicasse.
//!
//! ## Só HTTPS, e só o servidor que o agente já usa
//!
//! O endereço vem do backend configurado (`wss://deskside.com.br/ws/agent` →
//! `https://deskside.com.br`). Um backend em `ws://`, sem TLS, é ambiente de
//! desenvolvimento, e ali não há atualização: baixar um executável por texto
//! puro seria entregar o computador a quem estiver no meio da rede.

use std::io::{Read, Write};
use std::path::{Path, PathBuf};

use sha2::{Digest, Sha256};

/// Nome da cópia instalada. Precisa bater com o de `setup.rs`.
pub const EXE: &str = "deskside-agent.exe";
/// O executável novo, já baixado e conferido, esperando a troca.
pub const NOVO: &str = "deskside-agent.new.exe";
/// O executável velho, guardado até o novo provar que funciona.
pub const VELHO: &str = "deskside-agent.old.exe";
/// O novo que não passou na prova, afastado para o velho voltar ao lugar.
pub const FALHOU: &str = "deskside-agent.falhou.exe";
/// A cópia do agente velho que faz a troca.
pub const AJUDANTE: &str = "deskside-atualizador.exe";
/// A prova de que o novo conectou.
pub const PROVA: &str = "atualizacao.ok";

/// Tudo o que uma atualização pode deixar na pasta. A desinstalação apaga
/// estes também: o `rmdir` do fim dela só remove pasta vazia.
pub const SOBRAS: [&str; 5] = [NOVO, VELHO, FALHOU, AJUDANTE, PROVA];

/// Argumento com que o agente chama o ajudante.
pub const ARG_APLICAR: &str = "--aplicar-atualizacao";
/// Argumento com que o ajudante sobe o agente novo.
pub const ARG_ATUALIZADO: &str = "--atualizado";

/// Quanto o ajudante espera o agente novo conectar.
pub const PRAZO_DA_PROVA_SECS: u64 = 90;

/// Nenhum executável do Deskside chega perto disto. O limite existe para um
/// servidor com defeito não encher o disco de ninguém.
const LIMITE_DO_EXE: u64 = 300 * 1024 * 1024;
const LIMITE_DO_RESUMO: u64 = 1024;
const LIMITE_DO_CABECALHO: usize = 16 * 1024;

/// O nome com que o site publica o executável **desta** arquitetura.
///
/// Os mesmos nomes de `scripts/lib-arquitetura.ps1`. Pela arquitetura em que
/// este binário foi compilado, e não pela do Windows: um agente x64 rodando
/// emulado num ARM64 tem que continuar recebendo x64, que é o que ele é.
pub fn nome_publicado() -> Option<&'static str> {
    if cfg!(target_arch = "x86_64") {
        Some("Deskside.exe")
    } else if cfg!(target_arch = "aarch64") {
        Some("Deskside-ARM64.exe")
    } else {
        None
    }
}

/// O site de onde vêm as atualizações.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Origem {
    pub host: String,
    pub porta: u16,
}

impl Origem {
    /// O site do mesmo servidor do backend. `None` se não for `wss://`.
    pub fn do_backend(url: &str) -> Option<Origem> {
        let resto = url.trim().strip_prefix("wss://")?;
        let autoridade = resto.split(['/', '?', '#']).next()?;
        // Usuário e senha na URL não têm lugar aqui; recusar é mais simples
        // que interpretar.
        if autoridade.is_empty() || autoridade.contains('@') || autoridade.starts_with('[') {
            return None;
        }
        let (host, porta) = match autoridade.split_once(':') {
            Some((h, p)) => (h, p.parse().ok()?),
            None => (autoridade, 443),
        };
        if host.is_empty() {
            return None;
        }
        Some(Origem {
            host: host.to_ascii_lowercase(),
            porta,
        })
    }

    /// O pedido, pronto para ir pelo fio.
    pub fn pedido(&self, caminho: &str) -> String {
        let host = if self.porta == 443 {
            self.host.clone()
        } else {
            format!("{}:{}", self.host, self.porta)
        };
        format!(
            "GET {caminho} HTTP/1.1\r\n\
             Host: {host}\r\n\
             User-Agent: Deskside-Agent\r\n\
             Accept-Encoding: identity\r\n\
             Connection: close\r\n\r\n"
        )
    }
}

/// O que importa do cabeçalho de uma resposta.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Resposta {
    pub status: u16,
    pub tamanho: Option<u64>,
    /// Veio em pedaços (`Transfer-Encoding`), que este leitor não monta.
    pub em_pedacos: bool,
}

/// Lê o cabeçalho, se ele já chegou inteiro.
///
/// `Ok(None)` é "ainda não": falta chegar mais. `Ok(Some((resposta, n)))` diz
/// onde o corpo começa. Pura, para ser testada sem rede.
pub fn ler_cabecalho(bytes: &[u8]) -> Result<Option<(Resposta, usize)>, String> {
    let Some(fim) = bytes.windows(4).position(|j| j == b"\r\n\r\n") else {
        return Ok(None);
    };
    let texto = std::str::from_utf8(&bytes[..fim])
        .map_err(|_| "o cabeçalho da resposta não é texto".to_string())?;
    let mut linhas = texto.split("\r\n");
    let primeira = linhas.next().unwrap_or_default();
    let mut partes = primeira.split_whitespace();
    let versao = partes.next().unwrap_or_default();
    if !versao.starts_with("HTTP/1.") {
        return Err(format!("resposta que não é HTTP: {primeira:?}"));
    }
    let status = partes
        .next()
        .and_then(|s| s.parse::<u16>().ok())
        .ok_or_else(|| format!("resposta sem código: {primeira:?}"))?;

    let mut tamanho = None;
    let mut em_pedacos = false;
    for linha in linhas {
        let Some((nome, valor)) = linha.split_once(':') else {
            continue;
        };
        let nome = nome.trim().to_ascii_lowercase();
        let valor = valor.trim();
        if nome == "content-length" {
            tamanho = Some(
                valor
                    .parse::<u64>()
                    .map_err(|_| format!("tamanho ilegível: {valor:?}"))?,
            );
        } else if nome == "transfer-encoding" && !valor.eq_ignore_ascii_case("identity") {
            em_pedacos = true;
        }
    }
    Ok(Some((
        Resposta {
            status,
            tamanho,
            em_pedacos,
        },
        fim + 4,
    )))
}

/// O texto do `.sha256` publicado, se for mesmo um resumo.
///
/// Tolera o que um arquivo de texto costuma trazer de brinde — quebra de
/// linha, BOM, maiúsculas — e recusa o resto. Um 404 que viesse como página
/// HTML não pode ser comparado com resumo nenhum e anunciar uma "atualização".
pub fn resumo_valido(texto: &str) -> Option<String> {
    let limpo = texto
        .trim_start_matches('\u{feff}')
        .trim()
        .to_ascii_lowercase();
    (limpo.len() == 64 && limpo.bytes().all(|b| b.is_ascii_hexdigit())).then_some(limpo)
}

/// SHA-256 em hexadecimal de tudo o que o leitor entregar.
pub fn resumo_de(mut leitor: impl Read) -> std::io::Result<String> {
    let mut sha = Sha256::new();
    let mut pedaco = vec![0u8; 64 * 1024];
    loop {
        let n = leitor.read(&mut pedaco)?;
        if n == 0 {
            break;
        }
        sha.update(&pedaco[..n]);
    }
    Ok(hex(&sha.finalize()))
}

pub fn resumo_de_arquivo(caminho: &Path) -> Result<String, String> {
    let arquivo =
        std::fs::File::open(caminho).map_err(|e| format!("não abri {}: {e}", caminho.display()))?;
    resumo_de(std::io::BufReader::new(arquivo))
        .map_err(|e| format!("não li {}: {e}", caminho.display()))
}

fn hex(bytes: &[u8]) -> String {
    bytes.iter().map(|b| format!("{b:02x}")).collect()
}

/// Um `Write` que resume o que passa por ele. Conferir durante o download
/// poupa ler de novo, do disco, um arquivo que acabou de ser escrito.
struct ComResumo<W> {
    dentro: W,
    sha: Sha256,
}

impl<W: Write> Write for ComResumo<W> {
    fn write(&mut self, dados: &[u8]) -> std::io::Result<usize> {
        let n = self.dentro.write(dados)?;
        self.sha.update(&dados[..n]);
        Ok(n)
    }
    fn flush(&mut self) -> std::io::Result<()> {
        self.dentro.flush()
    }
}

/// Copia o corpo da resposta para `saida`, respeitando o tamanho anunciado.
///
/// Separado da rede para ser testado: `inicio` é o que já veio junto com o
/// cabeçalho, e `resto` é a conexão. Devolve quantos bytes escreveu.
pub fn copiar_corpo(
    inicio: &[u8],
    mut resto: impl Read,
    tamanho: Option<u64>,
    limite: u64,
    saida: &mut dyn Write,
) -> Result<u64, String> {
    if tamanho.is_some_and(|t| t > limite) {
        return Err("o arquivo anunciado é grande demais".into());
    }
    let alvo = tamanho.unwrap_or(limite);
    let mut total = 0u64;
    let mut escrever = |dados: &[u8], total: &mut u64| -> Result<bool, String> {
        let cabe = (alvo - *total).min(dados.len() as u64) as usize;
        saida
            .write_all(&dados[..cabe])
            .map_err(|e| format!("não gravei o download: {e}"))?;
        *total += cabe as u64;
        if tamanho.is_none() && cabe < dados.len() {
            return Err("o arquivo é grande demais".into());
        }
        Ok(*total >= alvo)
    };

    let mut acabou = escrever(inicio, &mut total)?;
    let mut pedaco = vec![0u8; 64 * 1024];
    while !acabou {
        let n = match resto.read(&mut pedaco) {
            Ok(n) => n,
            // Sem tamanho anunciado, o fim é a conexão fechar — e há
            // servidor que fecha sem a despedida do TLS. O resumo confere o
            // que chegou de qualquer jeito.
            Err(e) if tamanho.is_none() && e.kind() == std::io::ErrorKind::UnexpectedEof => 0,
            Err(e) => return Err(format!("o download caiu: {e}")),
        };
        if n == 0 {
            break;
        }
        acabou = escrever(&pedaco[..n], &mut total)?;
    }
    if let Some(t) = tamanho {
        if total != t {
            return Err(format!("o download parou em {total} de {t} bytes"));
        }
    }
    Ok(total)
}

/// Um GET por HTTPS, com o corpo indo para `saida`.
fn baixar(
    origem: &Origem,
    caminho: &str,
    limite: u64,
    saida: &mut dyn Write,
) -> Result<u64, String> {
    use std::net::{TcpStream, ToSocketAddrs};
    use std::time::Duration;

    let enderecos = (origem.host.as_str(), origem.porta)
        .to_socket_addrs()
        .map_err(|e| format!("não achei {}: {e}", origem.host))?;
    let mut ultimo_erro = format!("{} não tem endereço", origem.host);
    let mut tcp = None;
    for endereco in enderecos {
        match TcpStream::connect_timeout(&endereco, Duration::from_secs(15)) {
            Ok(t) => {
                tcp = Some(t);
                break;
            }
            Err(e) => ultimo_erro = format!("não conectei a {}: {e}", origem.host),
        }
    }
    let tcp = tcp.ok_or(ultimo_erro)?;
    let _ = tcp.set_read_timeout(Some(Duration::from_secs(30)));
    let _ = tcp.set_write_timeout(Some(Duration::from_secs(30)));

    let conector = native_tls::TlsConnector::new().map_err(|e| format!("TLS: {e}"))?;
    let mut tls = conector
        .connect(&origem.host, tcp)
        .map_err(|e| format!("TLS com {}: {e}", origem.host))?;
    tls.write_all(origem.pedido(caminho).as_bytes())
        .map_err(|e| format!("não enviei o pedido: {e}"))?;

    let mut recebido = Vec::with_capacity(8 * 1024);
    let mut pedaco = [0u8; 8 * 1024];
    let (resposta, inicio) = loop {
        let n = tls
            .read(&mut pedaco)
            .map_err(|e| format!("sem resposta de {}: {e}", origem.host))?;
        if n == 0 {
            return Err(format!("{} fechou sem responder", origem.host));
        }
        recebido.extend_from_slice(&pedaco[..n]);
        if let Some(pronto) = ler_cabecalho(&recebido)? {
            break pronto;
        }
        if recebido.len() > LIMITE_DO_CABECALHO {
            return Err("cabeçalho grande demais".into());
        }
    };
    if resposta.status != 200 {
        return Err(format!(
            "o site respondeu {} para {caminho}",
            resposta.status
        ));
    }
    // Conferido **depois** do código: página de erro costuma vir em pedaços,
    // e "404" diz muito mais que "chunked". Num 200, o Caddy não faz isto
    // com arquivo estático; se um dia fizer, o erro diz o que mudou, em vez
    // de gravar os tamanhos dos pedaços no meio do executável e culpar o
    // resumo.
    if resposta.em_pedacos {
        return Err("o site respondeu em pedaços (chunked), que o agente não lê".into());
    }
    copiar_corpo(&recebido[inicio..], tls, resposta.tamanho, limite, saida)
}

/// O resumo que o site publica agora para esta arquitetura.
fn resumo_publicado(origem: &Origem, nome: &str) -> Result<String, String> {
    let mut texto = Vec::new();
    baixar(
        origem,
        &format!("/baixar/{nome}.sha256"),
        LIMITE_DO_RESUMO,
        &mut texto,
    )?;
    resumo_valido(&String::from_utf8_lossy(&texto))
        .ok_or_else(|| "o site não publicou um resumo válido".to_string())
}

/// O que a verificação encontrou.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Situacao {
    /// O arquivo em uso é o publicado.
    EmDia,
    /// O site tem outro.
    Disponivel,
    /// Este agente não se atualiza sozinho, e o texto diz por quê.
    NaoSeAplica(&'static str),
}

/// Compara os dois resumos. Pura, para o teste dizer o óbvio em voz alta.
pub fn comparar(local: &str, publicado: &str) -> Situacao {
    if local.eq_ignore_ascii_case(publicado) {
        Situacao::EmDia
    } else {
        Situacao::Disponivel
    }
}

/// Pergunta ao site se há versão nova.
pub fn verificar(backend: &str) -> Result<Situacao, String> {
    let Some(nome) = nome_publicado() else {
        return Ok(Situacao::NaoSeAplica(
            "não há versão publicada para este processador",
        ));
    };
    let Some(origem) = Origem::do_backend(backend) else {
        return Ok(Situacao::NaoSeAplica(
            "o servidor configurado não usa HTTPS",
        ));
    };
    let Some(exe) = imp::exe_instalado_em_uso() else {
        // Rodando de fora da pasta de instalação: é quem desenvolve, ou o
        // arquivo recém-baixado antes de se instalar. Trocar o executável de
        // outra pasta não atualizaria o que sobe com o Windows.
        return Ok(Situacao::NaoSeAplica("este não é o Deskside instalado"));
    };
    let local = resumo_de_arquivo(&exe)?;
    Ok(comparar(&local, &resumo_publicado(&origem, nome)?))
}

/// Baixa, confere e passa a vez ao ajudante.
///
/// `Ok(())` quer dizer que o ajudante já está rodando e **quem chamou precisa
/// encerrar o processo agora**: o ajudante espera este agente sair para fazer
/// a troca.
pub fn aplicar(backend: &str) -> Result<(), String> {
    let nome = nome_publicado().ok_or("não há versão publicada para este processador")?;
    let origem = Origem::do_backend(backend).ok_or("o servidor configurado não usa HTTPS")?;
    let exe = imp::exe_instalado_em_uso().ok_or("este não é o Deskside instalado")?;
    let pasta = exe
        .parent()
        .ok_or("pasta de instalação desconhecida")?
        .to_path_buf();

    let novo = pasta.join(NOVO);
    let _ = std::fs::remove_file(&novo);
    let arquivo = std::fs::File::create(&novo)
        .map_err(|e| format!("não consegui gravar em {}: {e}", pasta.display()))?;
    let mut saida = ComResumo {
        dentro: std::io::BufWriter::new(arquivo),
        sha: Sha256::new(),
    };
    let baixou = baixar(
        &origem,
        &format!("/baixar/{nome}"),
        LIMITE_DO_EXE,
        &mut saida,
    )
    .and_then(|n| {
        saida
            .flush()
            .map(|_| n)
            .map_err(|e| format!("não gravei: {e}"))
    });
    let obtido = hex(&saida.sha.finalize());
    drop(saida.dentro);
    if let Err(e) = baixou {
        let _ = std::fs::remove_file(&novo);
        return Err(e);
    }

    // O resumo é buscado **depois** do executável. O script publica nessa
    // mesma ordem, então os dois só batem quando o executável baixado é
    // mesmo o que o resumo descreve — e um download no meio de uma
    // publicação é recusado, em vez de instalar a coisa errada.
    let esperado = resumo_publicado(&origem, nome)?;
    if obtido != esperado {
        let _ = std::fs::remove_file(&novo);
        return Err(
            "o arquivo baixado não confere com o publicado; tente de novo em instantes".into(),
        );
    }
    if resumo_de_arquivo(&exe)? == esperado {
        let _ = std::fs::remove_file(&novo);
        return Err("este computador já está com a versão publicada".into());
    }

    crate::diario(&format!(
        "atualização baixada e conferida ({esperado}); passando ao ajudante"
    ));
    imp::chamar_ajudante(&exe, &pasta)
}

/// Quanto tempo a conexão precisa durar, sem cair, para valer como prova.
pub const FIRMEZA_SECS: u64 = 10;

/// Conta há quanto tempo a conexão está de pé sem cair.
#[derive(Debug, Default)]
pub struct Firmeza {
    desde: Option<std::time::Instant>,
}

impl Firmeza {
    /// `true` quando a conexão já durou `FIRMEZA_SECS` seguidos. Uma queda
    /// zera a contagem: conectar e cair em laço não é versão que funciona.
    pub fn observar(&mut self, conectado: bool, agora: std::time::Instant) -> bool {
        if !conectado {
            self.desde = None;
            return false;
        }
        let desde = *self.desde.get_or_insert(agora);
        agora.duration_since(desde) >= std::time::Duration::from_secs(FIRMEZA_SECS)
    }
}

/// Grava a prova quando o agente novo conectar. Só existe no agente que o
/// ajudante subiu com `--atualizado`.
pub fn provar_quando_conectar(estado: crate::gui::Compartilhado) {
    let Some(pasta) = imp::pasta_instalada() else {
        return;
    };
    std::thread::Builder::new()
        .name("deskside-prova".into())
        .spawn(move || {
            let limite =
                std::time::Instant::now() + std::time::Duration::from_secs(PRAZO_DA_PROVA_SECS);
            let mut firmeza = Firmeza::default();
            while std::time::Instant::now() < limite {
                let conectado = estado.lock().map(|e| e.conectado).unwrap_or(false);
                if firmeza.observar(conectado, std::time::Instant::now()) {
                    let _ = std::fs::write(pasta.join(PROVA), b"ok");
                    crate::diario("versão nova conectada e firme; avisando o ajudante");
                    // O ajudante sai logo depois de ler a prova. Aí sim ele
                    // pode ser apagado.
                    std::thread::sleep(std::time::Duration::from_secs(15));
                    limpar_sobras();
                    return;
                }
                std::thread::sleep(std::time::Duration::from_millis(500));
            }
        })
        .ok();
}

/// Quanto esperar depois de subir para a primeira verificação.
///
/// No logon a rede e o disco estão disputados, e a atualização não tem pressa
/// nenhuma: é o momento em que o agente menos deve fazer coisas a mais.
const PRIMEIRA_VERIFICACAO_SECS: u64 = 2 * 60;
/// E de quanto em quanto tempo depois. Um computador que fica ligado a
/// semana toda também precisa descobrir a versão nova.
const ENTRE_VERIFICACOES_SECS: u64 = 6 * 60 * 60;

/// Pergunta ao site de tempos em tempos e deixa a resposta no estado da
/// janela. **Só avisa**: quem decide atualizar é a pessoa, pelo botão —
/// reiniciar o agente sozinho derrubaria o controle remoto de quem estivesse
/// usando o computador naquela hora.
pub fn vigiar(estado: crate::gui::Compartilhado) {
    use crate::gui::Atualizacao;
    std::thread::Builder::new()
        .name("deskside-atualizacao".into())
        .spawn(move || {
            std::thread::sleep(std::time::Duration::from_secs(PRIMEIRA_VERIFICACAO_SECS));
            loop {
                let backend = estado.lock().map(|e| e.backend.clone()).unwrap_or_default();
                let nova = match verificar(&backend) {
                    Ok(Situacao::Disponivel) => Some(Atualizacao::Disponivel),
                    Ok(Situacao::EmDia) => Some(Atualizacao::Nenhuma),
                    Ok(Situacao::NaoSeAplica(motivo)) => {
                        crate::diario(&format!("atualização automática desligada: {motivo}"));
                        return;
                    }
                    Err(e) => {
                        // Sem internet agora não quer dizer nada; tenta na
                        // próxima volta, sem incomodar ninguém.
                        crate::diario(&format!("não verifiquei atualização: {e}"));
                        None
                    }
                };
                if let (Some(nova), Ok(mut e)) = (nova, estado.lock()) {
                    // Uma atualização em andamento, ou uma falha que a pessoa
                    // ainda não viu, não são apagadas por uma verificação.
                    if matches!(
                        e.atualizacao,
                        Atualizacao::Nenhuma | Atualizacao::Disponivel
                    ) {
                        if nova == Atualizacao::Disponivel && e.atualizacao != nova {
                            crate::diario("há versão nova do Deskside no site");
                        }
                        e.atualizacao = nova;
                    }
                }
                std::thread::sleep(std::time::Duration::from_secs(ENTRE_VERIFICACOES_SECS));
            }
        })
        .ok();
}

/// Apaga o que uma atualização terminada deixou.
///
/// **Nunca o `.old.exe`**: enquanto o agente novo está sendo posto à prova,
/// é ele que o ajudante devolveria ao lugar. Quem o apaga é o ajudante,
/// depois da prova.
pub fn limpar_sobras() {
    let Some(pasta) = imp::pasta_instalada() else {
        return;
    };
    for nome in [NOVO, FALHOU, AJUDANTE] {
        // Falhar é normal: o ajudante pode ainda estar de pé.
        let _ = std::fs::remove_file(pasta.join(nome));
    }
}

/// O que o ajudante faz. Chamado por `main` com o PID do agente velho.
pub fn executar_ajudante(pid_do_velho: u32) {
    imp::executar_ajudante(pid_do_velho);
}

#[cfg(windows)]
mod imp {
    use super::*;
    use std::process::{Child, Command};
    use std::time::{Duration, Instant};

    const SYNCHRONIZE: u32 = 0x0010_0000;
    const CREATE_BREAKAWAY_FROM_JOB: u32 = 0x0100_0000;

    #[link(name = "kernel32")]
    extern "system" {
        fn OpenProcess(acesso: u32, herdar: i32, pid: u32) -> isize;
        fn WaitForSingleObject(handle: isize, ms: u32) -> u32;
        fn CloseHandle(handle: isize) -> i32;
    }

    pub fn pasta_instalada() -> Option<PathBuf> {
        let local = std::env::var_os("LOCALAPPDATA")?;
        Some(crate::setup::install_dir(Path::new(&local)))
    }

    /// O executável em uso, se ele for o instalado.
    pub fn exe_instalado_em_uso() -> Option<PathBuf> {
        let atual = std::env::current_exe().ok()?;
        let instalado = pasta_instalada()?.join(EXE);
        crate::setup::already_installed(&atual, &instalado).then_some(instalado)
    }

    /// Sobe um processo que sobrevive a quem o chamou.
    ///
    /// O agente sobe pela tarefa agendada do logon, e o Agendador de Tarefas
    /// põe seus processos num *job*. Pedir para sair do job é o que garante
    /// que o ajudante não morra junto com o agente velho; se o job não
    /// permitir, a criação falha e vai sem o pedido — hoje o agente já
    /// sobrevive ao `wscript` que o chamou, então o job não mata os filhos.
    fn lancar(exe: &Path, args: &[&str]) -> std::io::Result<Child> {
        use std::os::windows::process::CommandExt;
        Command::new(exe)
            .args(args)
            .creation_flags(CREATE_BREAKAWAY_FROM_JOB)
            .spawn()
            .or_else(|_| Command::new(exe).args(args).spawn())
    }

    pub fn chamar_ajudante(exe: &Path, pasta: &Path) -> Result<(), String> {
        let ajudante = pasta.join(AJUDANTE);
        let _ = std::fs::remove_file(&ajudante);
        std::fs::copy(exe, &ajudante).map_err(|e| format!("não preparei o ajudante: {e}"))?;
        let pid = std::process::id().to_string();
        lancar(&ajudante, &[ARG_APLICAR, &pid])
            .map_err(|e| format!("não consegui chamar o ajudante: {e}"))?;
        Ok(())
    }

    fn esperar_sair(pid: u32, prazo: Duration) {
        let handle = unsafe { OpenProcess(SYNCHRONIZE, 0, pid) };
        if handle == 0 {
            // Já saiu (ou nunca existiu): nada a esperar.
            return;
        }
        unsafe {
            WaitForSingleObject(handle, prazo.as_millis() as u32);
            CloseHandle(handle);
        }
    }

    /// Renomeia com paciência. Um antivírus examinando o arquivo recém-baixado
    /// segura ele por alguns instantes, e desistir na primeira recusa
    /// abortaria uma atualização boa.
    fn renomear(de: &Path, para: &Path) -> std::io::Result<()> {
        let mut tentativas = 0;
        loop {
            match std::fs::rename(de, para) {
                Ok(()) => return Ok(()),
                Err(e) if tentativas >= 40 => return Err(e),
                Err(_) => {
                    tentativas += 1;
                    std::thread::sleep(Duration::from_millis(250));
                }
            }
        }
    }

    pub fn executar_ajudante(pid_do_velho: u32) {
        let Some(pasta) = pasta_instalada() else {
            return;
        };
        let (exe, novo, velho) = (pasta.join(EXE), pasta.join(NOVO), pasta.join(VELHO));
        let (falhou, prova) = (pasta.join(FALHOU), pasta.join(PROVA));
        let diario = |t: &str| crate::diario(&format!("atualizador: {t}"));

        esperar_sair(pid_do_velho, Duration::from_secs(30));

        let _ = std::fs::remove_file(&velho);
        let _ = std::fs::remove_file(&prova);
        if let Err(e) = renomear(&exe, &velho) {
            diario(&format!(
                "não tirei o executável velho do lugar ({e}); nada mudou"
            ));
            let _ = lancar(&exe, &[]);
            return;
        }
        if let Err(e) = renomear(&novo, &exe) {
            diario(&format!("não pus o novo no lugar ({e}); voltando o velho"));
            let _ = renomear(&velho, &exe);
            let _ = lancar(&exe, &[]);
            return;
        }

        let mut filho = match lancar(&exe, &[ARG_ATUALIZADO]) {
            Ok(f) => f,
            Err(e) => {
                diario(&format!("o novo não abriu ({e}); voltando o velho"));
                desfazer(&exe, &velho, &falhou, None);
                return;
            }
        };

        let limite = Instant::now() + Duration::from_secs(PRAZO_DA_PROVA_SECS);
        while Instant::now() < limite {
            if prova.exists() {
                let _ = std::fs::remove_file(&prova);
                let _ = std::fs::remove_file(&velho);
                diario("versão nova no ar");
                return;
            }
            if let Ok(Some(saida)) = filho.try_wait() {
                diario(&format!(
                    "o novo encerrou sozinho ({saida}); voltando o velho"
                ));
                desfazer(&exe, &velho, &falhou, None);
                return;
            }
            std::thread::sleep(Duration::from_millis(500));
        }
        diario(&format!(
            "o novo não conectou em {PRAZO_DA_PROVA_SECS}s; voltando o velho"
        ));
        desfazer(&exe, &velho, &falhou, Some(filho));
    }

    fn desfazer(exe: &Path, velho: &Path, falhou: &Path, filho: Option<Child>) {
        if let Some(mut f) = filho {
            let _ = f.kill();
            let _ = f.wait();
        }
        let _ = std::fs::remove_file(falhou);
        let _ = renomear(exe, falhou);
        match renomear(velho, exe) {
            Ok(()) => {
                let _ = lancar(exe, &[]);
            }
            Err(e) => crate::diario(&format!(
                "atualizador: não devolvi o velho ({e}); reinstale pelo site"
            )),
        }
    }
}

#[cfg(not(windows))]
mod imp {
    use super::*;

    pub fn pasta_instalada() -> Option<PathBuf> {
        None
    }

    pub fn exe_instalado_em_uso() -> Option<PathBuf> {
        None
    }

    pub fn chamar_ajudante(_exe: &Path, _pasta: &Path) -> Result<(), String> {
        Err("atualização automática só existe no Windows".into())
    }

    pub fn executar_ajudante(_pid: u32) {}
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn cada_processador_recebe_o_seu_executavel() {
        // Os nomes de `scripts/lib-arquitetura.ps1`. Um ARM64 que baixasse o
        // x64 funcionaria emulado e mais lento, sem ninguém perceber por quê.
        let nome = nome_publicado();
        if cfg!(target_arch = "x86_64") {
            assert_eq!(nome, Some("Deskside.exe"));
        } else if cfg!(target_arch = "aarch64") {
            assert_eq!(nome, Some("Deskside-ARM64.exe"));
        }
    }

    #[test]
    fn o_site_e_o_mesmo_servidor_do_backend() {
        assert_eq!(
            Origem::do_backend("wss://deskside.com.br/ws/agent"),
            Some(Origem {
                host: "deskside.com.br".into(),
                porta: 443
            })
        );
        assert_eq!(
            Origem::do_backend("wss://Exemplo.com:8443/ws/agent?x=1"),
            Some(Origem {
                host: "exemplo.com".into(),
                porta: 8443
            })
        );
    }

    #[test]
    fn sem_tls_nao_ha_atualizacao() {
        // Um executável por texto puro é o computador de presente para quem
        // estiver no meio da rede.
        assert_eq!(Origem::do_backend("ws://127.0.0.1:8000/ws/agent"), None);
        assert_eq!(Origem::do_backend("https://deskside.com.br"), None);
        assert_eq!(Origem::do_backend("wss://usuario@deskside.com.br/ws"), None);
        assert_eq!(Origem::do_backend("wss://deskside.com.br:x/ws"), None);
        assert_eq!(Origem::do_backend("wss:///ws"), None);
    }

    #[test]
    fn o_pedido_e_http_1_1_e_nao_aceita_compressao() {
        let o = Origem {
            host: "deskside.com.br".into(),
            porta: 443,
        };
        let p = o.pedido("/baixar/Deskside.exe.sha256");
        assert!(
            p.starts_with("GET /baixar/Deskside.exe.sha256 HTTP/1.1\r\n"),
            "{p}"
        );
        assert!(p.contains("\r\nHost: deskside.com.br\r\n"), "{p}");
        assert!(p.contains("Accept-Encoding: identity"), "{p}");
        assert!(p.ends_with("\r\n\r\n"));

        let fora = Origem {
            host: "x.com".into(),
            porta: 8443,
        };
        assert!(fora.pedido("/").contains("Host: x.com:8443\r\n"));
    }

    #[test]
    fn cabecalho_incompleto_pede_mais() {
        assert_eq!(
            ler_cabecalho(b"HTTP/1.1 200 OK\r\nContent-Length: 3\r\n"),
            Ok(None)
        );
    }

    #[test]
    fn cabecalho_inteiro_diz_onde_o_corpo_comeca() {
        let bytes = b"HTTP/1.1 200 OK\r\ncontent-length: 5\r\nServer: x\r\n\r\nabcde";
        let (r, inicio) = ler_cabecalho(bytes).unwrap().unwrap();
        assert_eq!(
            r,
            Resposta {
                status: 200,
                tamanho: Some(5),
                em_pedacos: false
            }
        );
        assert_eq!(&bytes[inicio..], b"abcde");
    }

    #[test]
    fn outros_codigos_e_respostas_sem_tamanho() {
        let (r, _) = ler_cabecalho(b"HTTP/1.0 404 Not Found\r\n\r\n")
            .unwrap()
            .unwrap();
        assert_eq!(
            r,
            Resposta {
                status: 404,
                tamanho: None,
                em_pedacos: false
            }
        );
    }

    #[test]
    fn resposta_estranha_e_recusada() {
        assert!(ler_cabecalho(b"SSH-2.0-OpenSSH\r\n\r\n").is_err());
        assert!(ler_cabecalho(b"HTTP/1.1 200 OK\r\nContent-Length: dez\r\n\r\n").is_err());
    }

    #[test]
    fn resposta_em_pedacos_e_marcada() {
        let (r, _) = ler_cabecalho(b"HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n")
            .unwrap()
            .unwrap();
        assert!(r.em_pedacos);
    }

    #[test]
    fn corpo_com_tamanho_para_no_tamanho() {
        let mut saida = Vec::new();
        let n = copiar_corpo(b"abc", &b"defXYZ"[..], Some(6), 100, &mut saida).unwrap();
        assert_eq!((n, saida.as_slice()), (6, &b"abcdef"[..]));
    }

    #[test]
    fn corpo_que_chega_pela_metade_e_erro() {
        let mut saida = Vec::new();
        let erro = copiar_corpo(b"abc", &b""[..], Some(10), 100, &mut saida).unwrap_err();
        assert!(erro.contains("3 de 10"), "{erro}");
    }

    #[test]
    fn corpo_sem_tamanho_vai_ate_a_conexao_fechar() {
        let mut saida = Vec::new();
        let n = copiar_corpo(b"ab", &b"cd"[..], None, 100, &mut saida).unwrap();
        assert_eq!((n, saida.as_slice()), (4, &b"abcd"[..]));
    }

    #[test]
    fn corpo_grande_demais_e_recusado() {
        let mut saida = Vec::new();
        assert!(copiar_corpo(b"", &b""[..], Some(101), 100, &mut saida).is_err());
        assert!(copiar_corpo(b"abcdef", &b""[..], None, 4, &mut saida).is_err());
    }

    #[test]
    fn o_resumo_publicado_tolera_o_que_arquivo_de_texto_traz() {
        let r = "a".repeat(64);
        assert_eq!(resumo_valido(&r), Some(r.clone()));
        assert_eq!(
            resumo_valido(&format!("\u{feff}{}\r\n", r.to_uppercase())),
            Some(r)
        );
    }

    #[test]
    fn o_que_nao_e_resumo_nao_anuncia_atualizacao() {
        // Uma página de erro em HTML comparada com um resumo daria "diferente",
        // e o agente ofereceria uma atualização que não existe.
        for ruim in ["", "<html>404</html>", &"a".repeat(63), &"g".repeat(64)] {
            assert_eq!(resumo_valido(ruim), None, "{ruim:?}");
        }
    }

    #[test]
    fn o_resumo_e_o_sha256_de_sempre() {
        // O mesmo que o `Get-FileHash` do PowerShell dá para "abc".
        assert_eq!(
            resumo_de(&b"abc"[..]).unwrap(),
            "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
        );
    }

    #[test]
    fn o_resumo_durante_a_gravacao_bate_com_o_do_arquivo() {
        let mut saida = ComResumo {
            dentro: Vec::new(),
            sha: Sha256::new(),
        };
        saida.write_all(b"abc").unwrap();
        assert_eq!(hex(&saida.sha.finalize()), resumo_de(&b"abc"[..]).unwrap());
    }

    #[test]
    fn so_resumo_diferente_e_atualizacao() {
        let a = "a".repeat(64);
        assert_eq!(comparar(&a, &a.to_uppercase()), Situacao::EmDia);
        assert_eq!(comparar(&a, &"b".repeat(64)), Situacao::Disponivel);
    }

    #[test]
    fn so_conexao_que_dura_vale_como_prova() {
        use std::time::{Duration, Instant};
        let t0 = Instant::now();
        let s = |n| t0 + Duration::from_secs(n);
        let mut f = Firmeza::default();
        assert!(!f.observar(false, s(0)));
        assert!(!f.observar(true, s(1)));
        assert!(!f.observar(true, s(10)));
        // Caiu: a contagem recomeça do zero.
        assert!(!f.observar(false, s(10)));
        assert!(!f.observar(true, s(12)));
        assert!(!f.observar(true, s(21)));
        assert!(f.observar(true, s(22)));
    }

    #[test]
    fn a_prova_cabe_no_prazo_do_ajudante() {
        // Com folga para conectar: a reconexão do agente começa em segundos.
        const { assert!(FIRMEZA_SECS * 3 < PRAZO_DA_PROVA_SECS) };
    }

    #[test]
    fn a_desinstalacao_conhece_todas_as_sobras() {
        for nome in [NOVO, VELHO, FALHOU, AJUDANTE, PROVA] {
            assert!(SOBRAS.contains(&nome), "{nome}");
        }
        // E nenhuma delas é o executável instalado.
        assert!(!SOBRAS.contains(&EXE));
    }
}
