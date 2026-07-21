import pytest

from app.protocol import Ack, Error, Heartbeat, Hello, Welcome, parse_client_message


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
