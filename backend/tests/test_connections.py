import asyncio

from app.connections import ConnectionManager, Viewer, ViewerRegistry


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


class FakeViewer:
    _next = 0

    def __init__(self):
        self.offered = []
        # O registro indexa viewers por sessão (sinalização de WebRTC), então o
        # dublê precisa de um id único como o Viewer de verdade.
        FakeViewer._next += 1
        self.session_id = f"sessao-{FakeViewer._next}"

    def offer(self, frame):
        self.offered.append(frame)


def test_viewer_registry_count_and_broadcast():
    reg = ViewerRegistry()
    a = FakeViewer()
    b = FakeViewer()
    assert reg.add("dev", a) == 1
    assert reg.add("dev", b) == 2
    assert reg.count("dev") == 2

    reg.broadcast("dev", b"frame")
    assert a.offered == [b"frame"]
    assert b.offered == [b"frame"]

    assert reg.remove("dev", a) == 1
    assert reg.remove("dev", b) == 0
    assert reg.count("dev") == 0


def test_viewer_drops_stale_frames():
    """O sender envia só o frame mais recente; os intermediários são descartados."""

    class FakeWS:
        def __init__(self):
            self.sent = []

        async def send_bytes(self, data):
            self.sent.append(data)
            await asyncio.sleep(0)

    async def scenario():
        ws = FakeWS()
        viewer = Viewer(ws)
        viewer.offer(b"a")
        viewer.offer(b"b")
        viewer.offer(b"c")  # só o 'c' fica pendente
        task = asyncio.create_task(viewer.run_sender())
        await asyncio.sleep(0.05)
        task.cancel()
        return ws.sent

    sent = asyncio.run(scenario())
    assert sent == [b"c"]
