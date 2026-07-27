import pytest

from app.protocol import (
    Ack,
    Error,
    Heartbeat,
    Hello,
    WebrtcAnswer,
    WebrtcIce,
    Welcome,
    parse_client_message,
)


def test_parse_hello():
    msg = parse_client_message(
        {
            "type": "hello",
            "device_id": "dev-1",
            "hostname": "dell-g5",
            "os": "windows",
            "agent_version": "0.1.0",
        }
    )
    assert isinstance(msg, Hello)
    assert msg.device_id == "dev-1"
    assert msg.os == "windows"


def test_parse_heartbeat():
    assert isinstance(parse_client_message({"type": "heartbeat"}), Heartbeat)


def test_parse_unknown_type_raises():
    with pytest.raises(ValueError):
        parse_client_message({"type": "banana"})


def test_parse_missing_field_raises():
    with pytest.raises(ValueError):
        parse_client_message({"type": "hello", "device_id": "x"})


def test_server_messages_wire_format():
    # O formato de fio precisa casar com o agente Rust.
    assert Welcome(server_version="0.1.0").model_dump() == {
        "type": "welcome",
        "server_version": "0.1.0",
    }
    assert Ack().model_dump() == {"type": "ack"}
    assert Error(message="x").model_dump() == {"type": "error", "message": "x"}


def test_heartbeat_wire_format():
    assert Heartbeat().model_dump() == {"type": "heartbeat"}


def test_parse_webrtc_answer():
    msg = parse_client_message(
        {"type": "webrtc_answer", "session_id": "s1", "sdp": "v=0\r\n"}
    )
    assert isinstance(msg, WebrtcAnswer)
    assert msg.session_id == "s1"
    assert msg.sdp == "v=0\r\n"


def test_parse_webrtc_ice_com_e_sem_campos_opcionais():
    completo = parse_client_message(
        {
            "type": "webrtc_ice",
            "session_id": "s1",
            "candidate": "candidate:1 1 udp 2130706431 10.0.0.2 5000 typ host",
            "sdp_mid": "0",
            "sdp_mline_index": 0,
        }
    )
    assert isinstance(completo, WebrtcIce)
    assert completo.sdp_mid == "0" and completo.sdp_mline_index == 0

    # Fim dos candidatos: candidato vazio e sem os opcionais.
    minimo = parse_client_message(
        {"type": "webrtc_ice", "session_id": "s1", "candidate": ""}
    )
    assert isinstance(minimo, WebrtcIce)
    assert minimo.candidate == ""
    assert minimo.sdp_mid is None and minimo.sdp_mline_index is None


def test_webrtc_ice_sem_session_id_e_recusado():
    with pytest.raises(ValueError):
        parse_client_message({"type": "webrtc_ice", "candidate": "c"})
