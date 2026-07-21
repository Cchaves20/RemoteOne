//! Núcleo do agente desktop do RemoteOne.
//!
//! A lógica portável (pareamento, protocolo, identidade, cliente) vive nesta
//! biblioteca e é testada em Windows, Linux e macOS pela CI. O binário
//! (`main.rs`) é apenas uma casca fina por cima dela.

pub mod capture;
pub mod client;
pub mod identity;
pub mod injector;
pub mod input;
pub mod pairing;
pub mod platform;
pub mod protocol;
