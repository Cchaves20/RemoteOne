use remoteone_agent::pairing;
use remoteone_agent::platform::{self, Platform};

fn main() {
    let plat = platform::current();
    let code = pairing::generate_pairing_code();

    println!("RemoteOne Agent 0.1.0 — sistema: {}", plat.os_name());
    println!("Código de pareamento: {code}");
    println!("(comunicação com o backend será implementada na Etapa 1)");
}
