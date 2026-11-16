//! Configuração do agente em arquivo, com as variáveis de ambiente por cima.
//!
//! Até aqui tudo se configurava por variável de ambiente, e o instalador
//! guardava a URL do backend numa variável **de usuário** do Windows. Funciona,
//! mas tem dois defeitos que aparecem quando outra pessoa instala:
//!
//! - **É invisível.** Ninguém sabe onde olhar para conferir o que está valendo,
//!   e mudar exige um passeio pelas propriedades do sistema.
//! - **É frágil.** Uma variável de usuário não acompanha o programa: desinstalar
//!   deixa o rastro para trás, e um perfil novo não herda nada.
//!
//! Agora há um arquivo, ao lado do `device_id`, com o mesmo formato simples de
//! um `.env` — e as variáveis de ambiente continuam valendo **por cima** dele,
//! porque é assim que se testa uma configuração diferente sem editar nada.
//!
//! Sem dependência nova: o formato é `CHAVE=valor`, uma por linha, e o parser
//! cabe em vinte linhas. Um TOML aqui seria uma crate a mais para ler seis
//! chaves.

use std::collections::BTreeMap;

/// O conteúdo do arquivo de configuração.
///
/// `BTreeMap` e não `HashMap`: assim o arquivo sai sempre na mesma ordem, e
/// duas gravações seguidas não produzem arquivos diferentes só porque o
/// embaralhamento mudou.
#[derive(Debug, Default, Clone, PartialEq, Eq)]
pub struct Config {
    values: BTreeMap<String, String>,
}

impl Config {
    pub fn new() -> Self {
        Self::default()
    }

    /// Lê o formato `CHAVE=valor`.
    ///
    /// Linha em branco e linha começando com `#` são ignoradas. Linha
    /// malformada também é ignorada, em vez de derrubar a leitura: um arquivo
    /// editado à mão com um erro de digitação não pode impedir o agente de
    /// subir — ele tem outras cinco chaves boas.
    pub fn parse(text: &str) -> Self {
        let mut values = BTreeMap::new();
        for linha in text.lines() {
            let linha = linha.trim();
            if linha.is_empty() || linha.starts_with('#') {
                continue;
            }
            let Some((chave, valor)) = linha.split_once('=') else {
                continue;
            };
            let chave = chave.trim();
            if chave.is_empty() {
                continue;
            }
            // Maiúsculas sempre: é como as variáveis de ambiente se chamam, e
            // aceitar as duas grafias faria a mesma chave existir duas vezes.
            values.insert(chave.to_uppercase(), valor.trim().to_string());
        }
        Self { values }
    }

    /// O arquivo como texto, pronto para gravar.
    pub fn to_text(&self) -> String {
        let mut saida = String::from(
            "# Configuração do agente do Deskside.\n\
             # Uma chave por linha. As variáveis de ambiente de mesmo nome têm\n\
             # prioridade sobre o que estiver aqui.\n\n",
        );
        for (chave, valor) in &self.values {
            saida.push_str(chave);
            saida.push('=');
            saida.push_str(valor);
            saida.push('\n');
        }
        saida
    }

    pub fn get(&self, key: &str) -> Option<&str> {
        self.values.get(&key.to_uppercase()).map(String::as_str)
    }

    /// Guarda um valor. Valor vazio **remove** a chave: é o que permite
    /// "voltar ao padrão" sem inventar uma palavra para isso.
    pub fn set(&mut self, key: &str, value: &str) {
        let chave = key.to_uppercase();
        if value.is_empty() {
            self.values.remove(&chave);
        } else {
            self.values.insert(chave, value.to_string());
        }
    }

    pub fn is_empty(&self) -> bool {
        self.values.is_empty()
    }
}

/// O valor em vigor para uma chave: ambiente primeiro, arquivo depois.
///
/// A ordem não é arbitrária. Quem exporta uma variável está fazendo um teste
/// pontual — "roda esta vez apontando para outro backend" — e essa intenção tem
/// de vencer o que está gravado, senão o teste não acontece e ninguém entende
/// por quê.
///
/// `env` entra por parâmetro para esta função ser testável: mexer nas variáveis
/// de ambiente de verdade dentro de um teste afeta os outros testes, que rodam
/// em paralelo na mesma máquina.
pub fn resolve_with<F>(env: F, file: &Config, key: &str) -> Option<String>
where
    F: Fn(&str) -> Option<String>,
{
    match env(key) {
        // Variável definida mas vazia conta como não definida: é o que acontece
        // quando alguém "limpa" a variável em vez de removê-la.
        Some(v) if !v.trim().is_empty() => Some(v),
        _ => file.get(key).map(str::to_string),
    }
}

/// O mesmo, lendo o ambiente de verdade.
pub fn resolve(file: &Config, key: &str) -> Option<String> {
    resolve_with(|k| std::env::var(k).ok(), file, key)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn le_chave_e_valor() {
        let c = Config::parse("DESKSIDE_BACKEND_URL=ws://exemplo/ws/agent\n");
        assert_eq!(c.get("DESKSIDE_BACKEND_URL"), Some("ws://exemplo/ws/agent"));
    }

    #[test]
    fn ignora_comentario_e_linha_vazia() {
        let c = Config::parse("# comentário\n\n  \nA=1\n");
        assert_eq!(c.get("A"), Some("1"));
    }

    #[test]
    fn linha_malformada_nao_derruba_o_resto() {
        // Um erro de digitação numa linha não pode impedir o agente de subir:
        // as outras chaves continuam boas.
        let c = Config::parse("isto nao tem igual\nA=1\n=sem chave\nB=2\n");
        assert_eq!(c.get("A"), Some("1"));
        assert_eq!(c.get("B"), Some("2"));
    }

    #[test]
    fn o_valor_pode_ter_igual_dentro() {
        // URLs com parâmetro têm `=` no meio; cortar no primeiro é o certo.
        let c = Config::parse("URL=ws://x/y?a=1&b=2\n");
        assert_eq!(c.get("URL"), Some("ws://x/y?a=1&b=2"));
    }

    #[test]
    fn a_grafia_da_chave_nao_importa() {
        let c = Config::parse("deskside_backend_url=x\n");
        assert_eq!(c.get("DESKSIDE_BACKEND_URL"), Some("x"));
        assert_eq!(c.get("deskside_backend_url"), Some("x"));
    }

    #[test]
    fn ida_e_volta_pelo_texto_preserva_tudo() {
        let mut c = Config::new();
        c.set("DESKSIDE_BACKEND_URL", "ws://caio/ws/agent");
        c.set("DESKSIDE_VIDEO_FPS", "24");
        assert_eq!(Config::parse(&c.to_text()), c);
    }

    #[test]
    fn gravar_duas_vezes_produz_o_mesmo_arquivo() {
        // Sem isto, cada gravação embaralharia as linhas e qualquer comparação
        // de "mudou alguma coisa?" daria sempre sim.
        let mut c = Config::new();
        c.set("Z", "1");
        c.set("A", "2");
        assert_eq!(c.to_text(), c.to_text());
        assert!(c.to_text().find("A=").unwrap() < c.to_text().find("Z=").unwrap());
    }

    #[test]
    fn valor_vazio_remove_a_chave() {
        let mut c = Config::parse("A=1\n");
        c.set("A", "");
        assert_eq!(c.get("A"), None);
        assert!(c.is_empty());
    }

    #[test]
    fn o_ambiente_vence_o_arquivo() {
        // "Roda esta vez apontando para outro backend" tem de funcionar sem
        // editar arquivo nenhum.
        let arquivo = Config::parse("URL=do-arquivo\n");
        let env = |k: &str| (k == "URL").then(|| "do-ambiente".to_string());
        assert_eq!(
            resolve_with(env, &arquivo, "URL"),
            Some("do-ambiente".into())
        );
    }

    #[test]
    fn sem_variavel_vale_o_arquivo() {
        let arquivo = Config::parse("URL=do-arquivo\n");
        assert_eq!(
            resolve_with(|_| None, &arquivo, "URL"),
            Some("do-arquivo".into())
        );
    }

    #[test]
    fn variavel_vazia_conta_como_ausente() {
        // É o que acontece quando alguém "limpa" a variável em vez de removê-la.
        // Tratá-la como valor faria o agente tentar conectar a lugar nenhum,
        // com um arquivo de configuração correto ao lado.
        let arquivo = Config::parse("URL=do-arquivo\n");
        let env = |_: &str| Some("   ".to_string());
        assert_eq!(
            resolve_with(env, &arquivo, "URL"),
            Some("do-arquivo".into())
        );
    }

    #[test]
    fn chave_que_ninguem_definiu_e_ausente() {
        assert_eq!(resolve_with(|_| None, &Config::new(), "NADA"), None);
    }
}
