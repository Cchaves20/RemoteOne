from app.agents import AgentRegistry
from app.protocol import Hello


def _hello(device_id: str = "dev-1") -> Hello:
    return Hello(
        device_id=device_id,
        hostname="dell-g5",
        os="windows",
        agent_version="0.1.0",
    )


def test_register_and_list():
    reg = AgentRegistry()
    reg.register(_hello())
    agents = reg.list()
    assert len(agents) == 1
    assert agents[0].device_id == "dev-1"


def test_heartbeat_updates_last_seen():
    reg = AgentRegistry()
    info = reg.register(_hello())
    first_seen = info.last_seen
    assert reg.heartbeat("dev-1") is True
    assert reg.get("dev-1").last_seen >= first_seen


def test_heartbeat_unknown_device_returns_false():
    reg = AgentRegistry()
    assert reg.heartbeat("fantasma") is False


def test_unregister_removes_agent():
    reg = AgentRegistry()
    reg.register(_hello())
    reg.unregister("dev-1")
    assert reg.list() == []
    assert reg.get("dev-1") is None


def test_register_same_device_twice_keeps_one():
    reg = AgentRegistry()
    reg.register(_hello("dev-1"))
    reg.register(_hello("dev-1"))
    assert len(reg.list()) == 1
