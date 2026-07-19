//! Núcleo do agente desktop do RemoteOne.
//!
//! A lógica portável (pareamento, protocolo, sessões) vive nesta biblioteca
//! e é testada em Windows, Linux e macOS pela CI. O binário (`main.rs`) é
//! apenas uma casca fina por cima dela.

pub mod pairing;
pub mod platform;
