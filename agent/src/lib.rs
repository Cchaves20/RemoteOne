//! Núcleo do agente desktop do RemoteOne.
//!
//! A lógica portável (pareamento, protocolo, identidade, cliente) vive nesta
//! biblioteca e é testada em Windows, Linux e macOS pela CI. O binário
//! (`main.rs`) é apenas uma casca fina por cima dela.

pub mod apps;
pub mod capture;
pub mod client;
pub mod datachannel;
pub mod h264;
pub mod identity;
pub mod injector;
pub mod input;
pub mod notify;
pub mod pairing;
pub mod platform;
pub mod power;
pub mod protocol;
pub mod webrtc;
pub mod wol;
