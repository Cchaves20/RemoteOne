//! Wake-on-LAN: envia o "pacote mágico" para acordar outro computador da mesma
//! rede local. Usado quando este agente é o "peer" ligado que o backend escolhe
//! para acordar uma máquina vizinha desligada.
//!
//! O pacote mágico é 6 bytes 0xFF seguidos do MAC do alvo repetido 16 vezes,
//! enviado como broadcast UDP na LAN. Usa só a biblioteca padrão (multiplataforma).

use std::net::{Ipv4Addr, SocketAddr, UdpSocket};

/// Envia o pacote mágico para o MAC informado (formato AA:BB:CC:DD:EE:FF).
pub fn send_magic_packet(mac: &str) -> Result<(), String> {
    let target = parse_mac(mac)?;

    let mut packet = Vec::with_capacity(102);
    packet.extend_from_slice(&[0xFF; 6]);
    for _ in 0..16 {
        packet.extend_from_slice(&target);
    }

    let socket = UdpSocket::bind((Ipv4Addr::UNSPECIFIED, 0)).map_err(|e| e.to_string())?;
    socket.set_broadcast(true).map_err(|e| e.to_string())?;

    // Portas usuais de WoL (9 = discard, 7 = echo); manda nas duas por garantia.
    for port in [9u16, 7] {
        let addr = SocketAddr::from((Ipv4Addr::BROADCAST, port));
        socket.send_to(&packet, addr).map_err(|e| e.to_string())?;
    }
    Ok(())
}

/// Converte "AA:BB:CC:DD:EE:FF" (ou com "-") em 6 bytes.
fn parse_mac(mac: &str) -> Result<[u8; 6], String> {
    let parts: Vec<&str> = mac.split([':', '-']).collect();
    if parts.len() != 6 {
        return Err(format!("MAC inválido: {mac}"));
    }
    let mut bytes = [0u8; 6];
    for (i, part) in parts.iter().enumerate() {
        bytes[i] = u8::from_str_radix(part, 16).map_err(|_| format!("MAC inválido: {mac}"))?;
    }
    Ok(bytes)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parses_colon_and_dash_macs() {
        assert_eq!(
            parse_mac("01:23:45:AB:CD:EF").unwrap(),
            [0x01, 0x23, 0x45, 0xAB, 0xCD, 0xEF]
        );
        assert_eq!(
            parse_mac("01-23-45-ab-cd-ef").unwrap(),
            [0x01, 0x23, 0x45, 0xAB, 0xCD, 0xEF]
        );
    }

    #[test]
    fn rejects_malformed_mac() {
        assert!(parse_mac("01:23:45").is_err());
        assert!(parse_mac("zz:23:45:ab:cd:ef").is_err());
    }
}
