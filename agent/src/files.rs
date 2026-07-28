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
        parent,
        entries,
    })
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
    let dir = home()?.join("Downloads").join("RemoteOne");
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
        let sub = home().unwrap().join("remoteone-teste-resolve");
        std::fs::create_dir_all(&sub).unwrap();
        let resolvido = resolve(&sub.to_string_lossy()).unwrap();
        assert!(resolvido.ends_with("remoteone-teste-resolve"));
        std::fs::remove_dir_all(&sub).ok();
    }

    #[test]
    fn listagem_ordena_pastas_antes_de_arquivos() {
        let base = home().unwrap().join("remoteone-teste-lista");
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
        let dir = home().unwrap().join("remoteone-teste-livre");
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
        let mut incoming = Incoming::create("teste-remoteone.bin", 1024).unwrap();
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
        let dir = home().unwrap().join("remoteone-teste-leitura");
        std::fs::create_dir_all(&dir).unwrap();
        let arquivo = dir.join("dados.bin");
        std::fs::write(&arquivo, vec![7u8; 100]).unwrap();

        assert!(open_read(&dir.to_string_lossy()).is_err());
        let (_, size) = open_read(&arquivo.to_string_lossy()).unwrap();
        assert_eq!(size, 100);

        std::fs::remove_dir_all(&dir).ok();
    }
}
