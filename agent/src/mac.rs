//! O que os módulos do agente precisam do Mac e que é igual para todos: os
//! programas abertos e o ícone de um programa.
//!
//! Os programas vêm do `NSWorkspace`, que é de onde o próprio Dock e o
//! "Forçar Encerrar" do menu Apple tiram a lista. "Programa" aqui é o que tem
//! ícone no Dock (`NSApplicationActivationPolicy::Regular`): o mesmo critério
//! do Windows ("processo com janela"), e o que a pessoa reconhece como
//! programa. Serviços e ajudantes de fundo ficam de fora.

use objc2::rc::Retained;
use objc2::AnyThread;
use objc2_app_kit::{
    NSApplicationActivationOptions, NSApplicationActivationPolicy, NSBitmapImageFileType,
    NSBitmapImageRep, NSImage, NSRunningApplication, NSWorkspace,
};
use objc2_foundation::{NSDictionary, NSPoint, NSRect, NSSize, NSString};

/// Lado do ícone que vai ao celular, em pixels. O mesmo do Windows.
pub const LADO_DO_ICONE: u32 = 64;

/// Um programa aberto.
pub struct Programa {
    pub pid: i32,
    pub nome: String,
    /// O nome do executável dentro do `.app`, em minúsculas — a chave que os
    /// perfis do app usam para reconhecer o programa em primeiro plano.
    pub executavel: String,
    pub app: Retained<NSRunningApplication>,
}

fn descrever(app: Retained<NSRunningApplication>) -> Option<Programa> {
    let pid = app.processIdentifier();
    if pid <= 0 {
        return None;
    }
    let nome = app.localizedName()?.to_string();
    let executavel = app
        .executableURL()
        .and_then(|u| u.lastPathComponent())
        .map(|n| n.to_string().to_lowercase())
        .unwrap_or_else(|| nome.to_lowercase());
    Some(Programa {
        pid,
        nome,
        executavel,
        app,
    })
}

/// Os programas abertos, sem o próprio Deskside.
pub fn programas_abertos() -> Vec<Programa> {
    let meu = std::process::id() as i32;
    NSWorkspace::sharedWorkspace()
        .runningApplications()
        .iter()
        .filter(|a| a.activationPolicy() == NSApplicationActivationPolicy::Regular)
        .filter_map(descrever)
        .filter(|p| p.pid != meu)
        .collect()
}

/// O programa em primeiro plano.
pub fn em_primeiro_plano() -> Option<Programa> {
    descrever(NSWorkspace::sharedWorkspace().frontmostApplication()?)
}

/// O programa aberto com este PID.
pub fn pelo_pid(pid: i32) -> Option<Retained<NSRunningApplication>> {
    NSRunningApplication::runningApplicationWithProcessIdentifier(pid)
}

/// Traz o programa para a frente, com todas as janelas dele.
pub fn trazer_para_frente(pid: i32) -> Result<(), String> {
    let app = pelo_pid(pid).ok_or_else(|| format!("nenhum programa aberto com o PID {pid}"))?;
    if app.activateWithOptions(NSApplicationActivationOptions::ActivateAllWindows) {
        Ok(())
    } else {
        Err("o Mac não trouxe o programa para a frente".into())
    }
}

/// O ícone de um programa aberto, em PNG e base64.
pub fn icone_do_programa(app: &NSRunningApplication) -> Option<String> {
    icone(&*app.icon()?)
}

/// O ícone de um arquivo ou `.app`, em PNG e base64.
pub fn icone_do_caminho(caminho: &str) -> Option<String> {
    icone(&NSWorkspace::sharedWorkspace().iconForFile(&NSString::from_str(caminho)))
}

/// Um `NSImage` no tamanho do celular, em PNG e base64.
///
/// O ícone de um programa no Mac guarda vários tamanhos (de 16 a 1024 px).
/// Pedir a imagem "para um retângulo de 64" faz o Mac escolher a mais
/// próxima, em vez de decodificar a de 1024 só para reduzir depois.
fn icone(imagem: &NSImage) -> Option<String> {
    use base64::Engine;

    let lado = LADO_DO_ICONE as f64;
    let mut retangulo = NSRect::new(NSPoint::new(0.0, 0.0), NSSize::new(lado, lado));
    let cg = unsafe { imagem.CGImageForProposedRect_context_hints(&mut retangulo, None, None) }?;
    let rep = NSBitmapImageRep::initWithCGImage(NSBitmapImageRep::alloc(), &cg);
    let png = unsafe {
        rep.representationUsingType_properties(NSBitmapImageFileType::PNG, &NSDictionary::new())
    }?;
    // Numa tela Retina o Mac devolve o dobro (128 px); o celular não precisa.
    let mut img = image::load_from_memory(&png.to_vec()).ok()?;
    if img.width() > LADO_DO_ICONE {
        img = img.resize(
            LADO_DO_ICONE,
            LADO_DO_ICONE,
            image::imageops::FilterType::Triangle,
        );
    }
    let mut saida = std::io::Cursor::new(Vec::new());
    img.write_to(&mut saida, image::ImageFormat::Png).ok()?;
    Some(base64::engine::general_purpose::STANDARD.encode(saida.into_inner()))
}
