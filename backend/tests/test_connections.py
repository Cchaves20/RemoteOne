import asyncio

from app.connections import ConnectionManager


class FakeWebSocket:
    def __init__(self) -> None:
        self.sent: list[dict] = []

    async def send_json(self, message: dict) -> None:
        self.sent.append(message)


def test_send_to_registered_agent():
    mgr = ConnectionManager()
    ws = FakeWebSocket()
    mgr.register("dev-1", ws)
    assert mgr.is_online("dev-1")

    ok = asyncio.run(mgr.send_to_agent("dev-1", {"type": "ping"}))
    assert ok is True
    assert ws.sent == [{"type": "ping"}]


def test_send_to_missing_agent_returns_false():
    mgr = ConnectionManager()
    assert asyncio.run(mgr.send_to_agent("fantasma", {"x": 1})) is False


def test_unregister_only_removes_matching_socket():
    mgr = ConnectionManager()
    first = FakeWebSocket()
    second = FakeWebSocket()
    mgr.register("dev-1", first)
    # Uma reconexão substitui o socket; desregistrar o antigo não derruba o novo.
    mgr.register("dev-1", second)
    mgr.unregister("dev-1", first)
    assert mgr.is_online("dev-1")
    mgr.unregister("dev-1", second)
    assert not mgr.is_online("dev-1")
