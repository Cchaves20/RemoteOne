//! Embute o ícone e os dados de versão no executável do Windows.
//!
//! Sem isto o `.exe` fica com o ícone genérico do Windows, e todo atalho que
//! aponte para ele herda esse ícone - inclusive o do Menu Iniciar. Não é
//! enfeite: um programa que se propõe a ficar instalado e a receber controle
//! remoto da máquina precisa ser reconhecível de relance. Um binário sem cara
//! nenhuma é exatamente o que se espera de algo indesejado.
//!
//! Os dados de versão também aparecem em Detalhes, nas propriedades do
//! arquivo, e no aviso do SmartScreen: sem eles a caixa azul diz "Editor
//! desconhecido" e mais nada.

fn main() {
    // O recurso só existe no formato do Windows. Compilar isto ao rodar os
    // testes no Linux exigiria o `windres` do mingw, que não faz falta
    // nenhuma aqui - o alvo é outro.
    if std::env::var("CARGO_CFG_TARGET_OS").as_deref() != Ok("windows") {
        return;
    }

    println!("cargo:rerun-if-changed=assets/deskside.ico");

    let mut recurso = winresource::WindowsResource::new();
    recurso.set_icon("assets/deskside.ico");
    recurso.set("ProductName", "Deskside");
    recurso.set("FileDescription", "Agente do Deskside");
    recurso.set("CompanyName", "Deskside");
    recurso.set("LegalCopyright", "MIT");

    // Falhar aqui derrubaria a compilação inteira por causa de um ícone. O
    // aviso aparece, e o agente sai sem cara - que é o que já acontecia.
    if let Err(e) = recurso.compile() {
        println!("cargo:warning=não consegui embutir o ícone: {e}");
    }
}
