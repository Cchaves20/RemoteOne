//! Transferência de arquivos entre o celular e o computador.
//!
//! Como o `system_info`, este módulo é multiplataforma de verdade: não tem
//! stub, e o mesmo código roda no Windows, no Linux e no macOS — o que permite
//! testá-lo aqui, e não só no PC.
//!
//! **Fronteira:** tudo acontece dentro da pasta do usuário. Não é o dono da
//! máquina que precisa ser contido — ele já pode tudo —, é o caminho que vem
//! pela rede: sem essa checagem, um `..\..\Windows\System32` numa mensagem
//! adulterada leria o que quisesse.

use serde::{Deserialize, Serialize};

/// Tamanho do pedaço em que os arquivos viajam.
///
/// 64 KiB é o meio-termo: pedaço pequeno demais multiplica o custo por mensagem
/// (cada uma leva JSON e base64 em volta), e grande demais engasga o socket que
/// também carrega a tela.
pub const CHUNK_BYTES: usize = 64 * 1024;

/// Teto de um arquivo, nos dois sentidos.
///
/// Existe porque a transferência passa pelo VPS gratuito (1 GB de RAM): o
/// backend só repassa os pedaços, sem guardar o arquivo, mas um envio sem limite
/// ainda prenderia a conexão por horas. O backend tem o mesmo número.
pub const MAX_TRANSFER_BYTES: u64 = 100 * 1024 * 1024;

/// Um item de uma pasta do computador.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct FileEntry {
    pub name: String,
    /// Caminho absoluto, que é o que volta ao agente para abrir ou baixar.
    pub path: String,
    pub is_dir: bool,
    /// Tamanho em bytes. Zero em pastas — o custo de somar o conteúdo não se
    /// justifica para um número que ninguém usa.
    pub size: u64,
}

/// O conteúdo de uma pasta, com o caminho de onde se está e o de voltar.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct Listing {
    pub path: String,
    /// Pasta acima, ou `None` quando já se está na raiz permitida.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub parent: Option<String>,
    pub entries: Vec<FileEntry>,
    /// Atalhos para as pastas conhecidas (Área de Trabalho, Downloads...).
    ///
    /// Só vêm preenchidos **na raiz**: é onde eles servem para alguma coisa.
    /// Mandá-los em toda listagem seria repetir a mesma lista a cada passo da
    /// navegação, sem ninguém olhando.
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub shortcuts: Vec<FileEntry>,
}

/// A pasta do usuário: a raiz de tudo o que este módulo enxerga.
fn home() -> Result<std::path::PathBuf, String> {
    let var = if cfg!(windows) { "USERPROFILE" } else { "HOME" };
    std::env::var(var)
        .map(std::path::PathBuf::from)
        .map_err(|_| format!("não consegui descobrir a pasta do usuário ({var})"))
}

/// Resolve um caminho recebido pela rede, garantindo que fica dentro da pasta
/// do usuário.
///
/// Vazio significa "a pasta do usuário". O caminho é **canonicalizado** antes da
/// comparação: é isso que derruba `..` e atalhos que apontariam para fora —
/// comparar texto cru deixaria passar.
pub fn resolve(path: &str) -> Result<std::path::PathBuf, String> {
    let root = home()?;
    let root = root.canonicalize().unwrap_or(root);
    if path.trim().is_empty() {
        return Ok(root);
    }
    let candidate = std::path::Path::new(path);
    let joined = if candidate.is_absolute() {
        candidate.to_path_buf()
    } else {
        root.join(candidate)
    };
    let real = joined
        .canonicalize()
        .map_err(|e| format!("caminho inacessível: {e}"))?;
    if !real.starts_with(&root) {
        return Err("fora da pasta do usuário".to_string());
    }
    Ok(real)
}

/// Lista uma pasta: subpastas primeiro, depois arquivos, cada grupo em ordem
/// alfabética — a ordem em que se procura algo com o olho.
pub fn list(path: &str) -> Result<Listing, String> {
    let dir = resolve(path)?;
    if !dir.is_dir() {
        return Err("não é uma pasta".to_string());
    }
    let root = home()?;
    let root = root.canonicalize().unwrap_or(root);

    let mut entries = Vec::new();
    for item in std::fs::read_dir(&dir)
        .map_err(|e| e.to_string())?
        .flatten()
    {
        // Um item que não se deixa inspecionar (permissão, link quebrado) é
        // pulado: uma pasta inteira não deve sumir por causa de um arquivo.
        let Ok(meta) = item.metadata() else { continue };
        let name = item.file_name().to_string_lossy().to_string();
        if name.starts_with('.') {
            continue; // ocultos do Unix: ruído para quem só quer buscar um arquivo
        }
        entries.push(FileEntry {
            name,
            path: item.path().to_string_lossy().to_string(),
            is_dir: meta.is_dir(),
            size: if meta.is_dir() { 0 } else { meta.len() },
        });
    }
    entries.sort_by(|a, b| {
        b.is_dir
            .cmp(&a.is_dir)
            .then_with(|| a.name.to_lowercase().cmp(&b.name.to_lowercase()))
    });

    let parent = if dir == root {
        None
    } else {
        dir.parent().map(|p| p.to_string_lossy().to_string())
    };
    Ok(Listing {
        path: dir.to_string_lossy().to_string(),
        parent: parent.clone(),
        entries,
        // Na raiz, e só nela: é onde os atalhos servem para alguma coisa.
        shortcuts: if parent.is_none() {
            shortcuts()
        } else {
            Vec::new()
        },
    })
}

/// As pastas conhecidas do usuário: Área de Trabalho, Downloads, Documentos,
/// Imagens, Músicas e Vídeos.
///
/// **Não** dá para montar esses caminhos concatenando `USERPROFILE` com o nome
/// em inglês, e há dois motivos independentes: o nome muda com o idioma do
/// Windows ("Área de Trabalho"), e o OneDrive **redireciona** essas pastas
/// quando está ligado - a Área de Trabalho real passa a ser
/// `...\OneDrive\Área de Trabalho`. Quem sabe a resposta certa é o próprio
/// sistema, e é a ele que se pergunta.
///
/// O resultado é lembrado: essas pastas não mudam de lugar enquanto o
/// computador está ligado, e perguntar custa um processo do PowerShell.
pub fn shortcuts() -> Vec<FileEntry> {
    static CACHE: std::sync::OnceLock<Vec<FileEntry>> = std::sync::OnceLock::new();
    CACHE.get_or_init(imp_shortcuts).clone()
}

/// Transforma caminhos em atalhos, descartando o que não existe ou não está
/// dentro da pasta do usuário. Função pura - testada em qualquer sistema.
///
/// O filtro pelo `resolve` não é decorativo: é o mesmo limite da navegação e do
/// download, e um atalho para fora dele seria um botão que leva a um erro.
fn shortcuts_from<I: IntoIterator<Item = (String, String)>>(paths: I) -> Vec<FileEntry> {
    let mut vistos = std::collections::HashSet::new();
    let mut atalhos = Vec::new();
    for (name, path) in paths {
        if path.trim().is_empty() {
            continue;
        }
        let Ok(real) = resolve(&path) else { continue };
        if !real.is_dir() {
            continue;
        }
        let texto = real.to_string_lossy().to_string();
        // A mesma pasta pode aparecer duas vezes (Documentos e "Meus
        // Documentos" apontando para o mesmo lugar).
        if !vistos.insert(texto.clone()) {
            continue;
        }
        atalhos.push(FileEntry {
            name,
            path: texto,
            is_dir: true,
            size: 0,
        });
    }
    atalhos
}

/// Pergunta ao Windows onde ficam as pastas conhecidas.
///
/// `[Environment]::GetFolderPath` devolve o caminho **real**, já com o
/// redirecionamento do OneDrive e no idioma do sistema. Uma chamada só traz
/// todas: abrir um PowerShell por pasta seria seis vezes o custo pela mesma
/// informação.
#[cfg(windows)]
fn imp_shortcuts() -> Vec<FileEntry> {
    const SCRIPT: &str = r#"
$saida = @()
foreach ($par in @(
    @('Área de Trabalho','Desktop'),
    @('Downloads',''),
    @('Documentos','MyDocuments'),
    @('Imagens','MyPictures'),
    @('Músicas','MyMusic'),
    @('Vídeos','MyVideos')
)) {
  $caminho = ''
  if ($par[1] -eq '') {
    # Downloads não está no enum do .NET; o registro é quem sabe (e ele
    # também acompanha o redirecionamento).
    try {
      $caminho = (Get-ItemProperty 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Shell Folders')."{374DE290-123F-4565-9164-39C4925E467B}"
    } catch { }
    if (-not $caminho) { $caminho = Join-Path $env:USERPROFILE 'Downloads' }
  } else {
    try { $caminho = [Environment]::GetFolderPath($par[1]) } catch { }
  }
  $saida += [PSCustomObject]@{ name = $par[0]; path = $caminho }
}
ConvertTo-Json -InputObject @($saida) -Compress
"#;
    let output = match crate::apps::run_powershell(SCRIPT) {
        Ok(o) => o,
        Err(e) => {
            eprintln!("Atalhos de pasta indisponíveis: {e}");
            return Vec::new();
        }
    };
    let texto = String::from_utf8_lossy(&output.stdout);
    let pares = parse_shortcuts(&texto);
    if pares.is_empty() {
        eprintln!("Atalhos de pasta: o PowerShell não devolveu nada.");
    }
    shortcuts_from(pares)
}

/// Fora do Windows, monta a partir da pasta do usuário. Serve ao
/// desenvolvimento e mantém o caminho inteiro exercitável.
#[cfg(not(windows))]
fn imp_shortcuts() -> Vec<FileEntry> {
    let Ok(root) = home() else { return Vec::new() };
    let nomes = [
        ("Área de Trabalho", "Desktop"),
        ("Downloads", "Downloads"),
        ("Documentos", "Documents"),
        ("Imagens", "Pictures"),
        ("Músicas", "Music"),
        ("Vídeos", "Videos"),
    ];
    shortcuts_from(nomes.into_iter().map(|(rotulo, pasta)| {
        (
            rotulo.to_string(),
            root.join(pasta).to_string_lossy().to_string(),
        )
    }))
}

/// Lê o JSON do PowerShell com os pares nome/caminho. Função pura.
#[cfg_attr(not(windows), allow(dead_code))]
fn parse_shortcuts(text: &str) -> Vec<(String, String)> {
    let Ok(valor) = serde_json::from_str::<serde_json::Value>(text.trim()) else {
        return Vec::new();
    };
    let itens = match valor {
        serde_json::Value::Array(itens) => itens,
        outro => vec![outro],
    };
    itens
        .into_iter()
        .filter_map(|item| {
            let name = item.get("name")?.as_str()?.to_string();
            let path = item.get("path")?.as_str().unwrap_or_default().to_string();
            Some((name, path))
        })
        .collect()
}

/// Abre um arquivo para leitura, devolvendo também o tamanho.
pub fn open_read(path: &str) -> Result<(std::fs::File, u64), String> {
    let file = resolve(path)?;
    if !file.is_file() {
        return Err("não é um arquivo".to_string());
    }
    let size = file.metadata().map_err(|e| e.to_string())?.len();
    let handle = std::fs::File::open(&file).map_err(|e| e.to_string())?;
    Ok((handle, size))
}

/// Onde os arquivos vindos do celular são guardados, criada se não existir.
pub fn inbox() -> Result<std::path::PathBuf, String> {
    let dir = home()?.join("Downloads").join("Deskside");
    std::fs::create_dir_all(&dir).map_err(|e| format!("não consegui criar {dir:?}: {e}"))?;
    Ok(dir)
}

/// Reduz um nome vindo da rede ao que ele deveria ser: **só** um nome.
///
/// Descarta qualquer coisa que pareça caminho — é o que impede que um
/// `..\\..\\Windows\\System32\\algo.dll` vindo do celular escreva onde não deve.
pub fn safe_name(name: &str) -> String {
    let base = name
        .rsplit(['/', '\\'])
        .next()
        .unwrap_or(name)
        .trim()
        .trim_matches('.');
    let limpo: String = base
        .chars()
        .filter(|c| !matches!(c, '<' | '>' | ':' | '"' | '|' | '?' | '*') && !c.is_control())
        .collect();
    if limpo.is_empty() {
        "arquivo".to_string()
    } else {
        limpo
    }
}

/// Escolhe um caminho livre na caixa de entrada: `foto.png`, `foto (2).png`…
///
/// Sobrescrever seria a única alternativa, e apagar em silêncio o arquivo de
/// mesmo nome que a pessoa mandou antes é o tipo de perda que não se desfaz.
pub fn free_path(dir: &std::path::Path, name: &str) -> std::path::PathBuf {
    let candidate = dir.join(name);
    if !candidate.exists() {
        return candidate;
    }
    let path = std::path::Path::new(name);
    let stem = path
        .file_stem()
        .map(|s| s.to_string_lossy().to_string())
        .unwrap_or_else(|| name.to_string());
    let ext = path
        .extension()
        .map(|e| format!(".{}", e.to_string_lossy()))
        .unwrap_or_default();
    for n in 2..1000 {
        let tentativa = dir.join(format!("{stem} ({n}){ext}"));
        if !tentativa.exists() {
            return tentativa;
        }
    }
    dir.join(format!("{stem} ({}){ext}", std::process::id()))
}

/// Um arquivo sendo recebido do celular, escrito pedaço a pedaço.
///
/// Grava num arquivo temporário (`.parte`) e só renomeia no fim: uma
/// transferência interrompida não deixa para trás algo com nome de arquivo
/// pronto e conteúdo pela metade.
pub struct Incoming {
    file: std::fs::File,
    temp: std::path::PathBuf,
    final_path: std::path::PathBuf,
    written: u64,
    limit: u64,
}

impl Incoming {
    pub fn create(name: &str, limit: u64) -> Result<Self, String> {
        let dir = inbox()?;
        let final_path = free_path(&dir, &safe_name(name));
        let temp = final_path.with_extension("parte");
        let file = std::fs::File::create(&temp).map_err(|e| e.to_string())?;
        Ok(Self {
            file,
            temp,
            final_path,
            written: 0,
            limit,
        })
    }

    pub fn write(&mut self, bytes: &[u8]) -> Result<(), String> {
        use std::io::Write;
        self.written += bytes.len() as u64;
        if self.written > self.limit {
            return Err(format!(
                "arquivo maior que o limite de {} bytes",
                self.limit
            ));
        }
        self.file.write_all(bytes).map_err(|e| e.to_string())
    }

    /// Fecha e publica o arquivo, devolvendo o caminho final.
    pub fn finish(self) -> Result<String, String> {
        drop(self.file);
        std::fs::rename(&self.temp, &self.final_path).map_err(|e| e.to_string())?;
        Ok(self.final_path.to_string_lossy().to_string())
    }

    /// Desiste: apaga o arquivo pela metade.
    pub fn cancel(self) {
        drop(self.file);
        let _ = std::fs::remove_file(&self.temp);
    }
}

#[cfg(test)]
mod tests {
    #[test]
    fn atalhos_ignoram_o_que_nao_existe() {
        use super::shortcuts_from;
        // Nem todo computador tem as seis pastas (quem nunca abriu o gravador
        // de som não tem "Músicas"). Oferecer um atalho que leva a erro é pior
        // do que não oferecer.
        let atalhos = shortcuts_from([
            ("Existe".to_string(), std::env::var("HOME").unwrap_or_default()),
            ("Não existe".to_string(), "/caminho/que/nao/existe".to_string()),
            ("Vazio".to_string(), String::new()),
        ]);
        assert_eq!(atalhos.len(), 1);
        assert_eq!(atalhos[0].name, "Existe");
        assert!(atalhos[0].is_dir);
    }

    #[test]
    fn atalhos_nao_repetem_a_mesma_pasta() {
        use super::shortcuts_from;
        let casa = std::env::var("HOME").unwrap_or_default();
        let atalhos = shortcuts_from([
            ("Documentos".to_string(), casa.clone()),
            ("Meus Documentos".to_string(), casa),
        ]);
        assert_eq!(atalhos.len(), 1, "a mesma pasta não deve aparecer duas vezes");
    }

    #[test]
    fn atalho_fora_da_pasta_do_usuario_e_recusado() {
        use super::shortcuts_from;
        // Mesmo limite da navegação e do download.
        let atalhos = shortcuts_from([("Raiz".to_string(), "/".to_string())]);
        assert!(atalhos.is_empty());
    }

    #[test]
    fn le_os_atalhos_que_o_powershell_devolve() {
        use super::parse_shortcuts;
        let json = r#"[{"name":"Área de Trabalho","path":"C:\\Users\\eu\\OneDrive\\Área de Trabalho"},
                       {"name":"Downloads","path":"C:\\Users\\eu\\Downloads"}]"#;
        let pares = parse_shortcuts(json);
        assert_eq!(pares.len(), 2);
        assert_eq!(pares[0].0, "Área de Trabalho");
        // O caminho real passa pelo OneDrive: é justamente o que montar na mão
        // erraria.
        assert!(pares[0].1.contains("OneDrive"));
    }

    #[test]
    fn powershell_mudo_nao_quebra_a_listagem() {
        use super::parse_shortcuts;
        assert!(parse_shortcuts("").is_empty());
        assert!(parse_shortcuts("não é json").is_empty());
    }

    #[test]
    fn a_raiz_traz_atalhos_e_as_subpastas_nao() {
        use super::list;
        // Os atalhos servem na raiz; repeti-los a cada passo da navegação seria
        // mandar a mesma lista sem ninguém olhando.
        let raiz = list("").expect("a pasta do usuário deve listar");
        assert!(raiz.parent.is_none());
        // (No ambiente de teste pode não haver nenhuma das pastas conhecidas;
        // o que se afirma é a regra, não a quantidade.)
        let sub = raiz.entries.iter().find(|e| e.is_dir);
        if let Some(pasta) = sub {
            let dentro = list(&pasta.path).expect("subpasta deve listar");
            assert!(dentro.parent.is_some());
            assert!(dentro.shortcuts.is_empty(), "atalhos só na raiz");
        }
    }

    use super::*;

    #[test]
    fn resolve_vazio_e_a_pasta_do_usuario() {
        let home = home().unwrap();
        assert_eq!(resolve("").unwrap(), home.canonicalize().unwrap_or(home));
    }

    #[test]
    fn resolve_recusa_sair_da_pasta_do_usuario() {
        // O caso que a checagem existe para pegar.
        assert!(resolve("../../etc").is_err());
        assert!(resolve("/etc").is_err());
        assert!(resolve("/etc/passwd").is_err());
    }

    #[test]
    fn resolve_aceita_subpasta_existente() {
        let sub = home().unwrap().join("deskside-teste-resolve");
        std::fs::create_dir_all(&sub).unwrap();
        let resolvido = resolve(&sub.to_string_lossy()).unwrap();
        assert!(resolvido.ends_with("deskside-teste-resolve"));
        std::fs::remove_dir_all(&sub).ok();
    }

    #[test]
    fn listagem_ordena_pastas_antes_de_arquivos() {
        let base = home().unwrap().join("deskside-teste-lista");
        std::fs::create_dir_all(base.join("zpasta")).unwrap();
        std::fs::write(base.join("aarquivo.txt"), b"oi").unwrap();
        std::fs::write(base.join(".oculto"), b"x").unwrap();

        let listing = list(&base.to_string_lossy()).unwrap();
        let nomes: Vec<&str> = listing.entries.iter().map(|e| e.name.as_str()).collect();
        assert_eq!(nomes, vec!["zpasta", "aarquivo.txt"], "pasta vem primeiro");
        assert!(listing.parent.is_some(), "dá para voltar de uma subpasta");
        let arquivo = listing.entries.iter().find(|e| !e.is_dir).unwrap();
        assert_eq!(arquivo.size, 2);

        std::fs::remove_dir_all(&base).ok();
    }

    #[test]
    fn a_raiz_nao_oferece_voltar() {
        // Sem isso o app mostraria um "voltar" que sai da área permitida e
        // devolve erro — um beco sem saída visível na tela.
        assert!(list("").unwrap().parent.is_none());
    }

    #[test]
    fn safe_name_reduz_caminho_a_nome() {
        assert_eq!(safe_name("../../Windows/System32/evil.dll"), "evil.dll");
        assert_eq!(safe_name("C:\\Users\\caio\\foto.png"), "foto.png");
        assert_eq!(safe_name("relatório final.pdf"), "relatório final.pdf");
        assert_eq!(safe_name("../.."), "arquivo");
        assert_eq!(safe_name(""), "arquivo");
        assert_eq!(safe_name("nome:com*proibidos?.txt"), "nomecomproibidos.txt");
    }

    #[test]
    fn free_path_nao_sobrescreve() {
        let dir = home().unwrap().join("deskside-teste-livre");
        std::fs::create_dir_all(&dir).unwrap();
        std::fs::write(dir.join("nota.txt"), b"antigo").unwrap();

        let livre = free_path(&dir, "nota.txt");
        assert_eq!(livre.file_name().unwrap(), "nota (2).txt");
        assert_eq!(
            std::fs::read(dir.join("nota.txt")).unwrap(),
            b"antigo",
            "o arquivo anterior continua intacto"
        );

        std::fs::remove_dir_all(&dir).ok();
    }

    #[test]
    fn recebido_so_aparece_pronto_no_fim() {
        let mut incoming = Incoming::create("teste-deskside.bin", 1024).unwrap();
        let destino = incoming.final_path.clone();
        incoming.write(b"parte um ").unwrap();
        assert!(!destino.exists(), "não existe enquanto está pela metade");
        incoming.write(b"parte dois").unwrap();
        let caminho = incoming.finish().unwrap();

        assert_eq!(
            std::fs::read_to_string(&caminho).unwrap(),
            "parte um parte dois"
        );
        std::fs::remove_file(&caminho).ok();
    }

    #[test]
    fn recebido_respeita_o_limite_de_tamanho() {
        let mut incoming = Incoming::create("teste-limite.bin", 8).unwrap();
        let temp = incoming.temp.clone();
        assert!(incoming.write(&[0u8; 4]).is_ok());
        assert!(
            incoming.write(&[0u8; 8]).is_err(),
            "passar do limite tem de falhar"
        );
        incoming.cancel();
        assert!(!temp.exists(), "o pedaço escrito é apagado");
    }

    #[test]
    fn leitura_recusa_pasta_e_aceita_arquivo() {
        let dir = home().unwrap().join("deskside-teste-leitura");
        std::fs::create_dir_all(&dir).unwrap();
        let arquivo = dir.join("dados.bin");
        std::fs::write(&arquivo, vec![7u8; 100]).unwrap();

        assert!(open_read(&dir.to_string_lossy()).is_err());
        let (_, size) = open_read(&arquivo.to_string_lossy()).unwrap();
        assert_eq!(size, 100);

        std::fs::remove_dir_all(&dir).ok();
    }
}
