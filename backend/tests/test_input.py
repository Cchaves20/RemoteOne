from conftest import criar_conta
from fastapi.testclient import TestClient
from pydantic import TypeAdapter, ValidationError
from sqlalchemy import select

from app.connections import manager
from app.db import SessionLocal
from app.input import InputAction
from app.main import app
from app.models import Device, User

client = TestClient(app)

MOVE = {"kind": "mouse_move", "dx": 10, "dy": -5}


def _register(email: str = "dono@example.com") -> tuple[dict, int]:
    tokens = criar_conta(client, email=email)
    headers = {"Authorization": f"Bearer {tokens['access_token']}"}
    with SessionLocal() as db:
        user_id = db.scalar(select(User.id).where(User.email == email))
    return headers, user_id


def _pair_device(user_id: int, device_id: str = "dev-in") -> None:
    with SessionLocal() as db:
        db.add(
            Device(
                device_id=device_id,
                user_id=user_id,
                name="dell",
                os="windows",
                hostname="dell",
            )
        )
        db.commit()


def test_input_requires_authentication():
    resp = client.post("/api/v1/devices/dev-in/input", json=MOVE)
    assert resp.status_code == 401


def test_input_unknown_device_is_404():
    headers, _ = _register()
    resp = client.post("/api/v1/devices/inexistente/input", json=MOVE, headers=headers)
    assert resp.status_code == 404


def test_input_device_of_another_user_is_404():
    headers_a, user_a = _register("a@example.com")
    headers_b, _ = _register("b@example.com")
    _pair_device(user_a, "dev-a")
    # B não enxerga o dispositivo de A.
    resp = client.post("/api/v1/devices/dev-a/input", json=MOVE, headers=headers_b)
    assert resp.status_code == 404


def test_input_agent_offline_is_503():
    headers, user_id = _register()
    _pair_device(user_id)
    # Dispositivo pareado, mas sem agente conectado.
    resp = client.post("/api/v1/devices/dev-in/input", json=MOVE, headers=headers)
    assert resp.status_code == 503


def test_input_invalid_action_is_422():
    headers, user_id = _register()
    _pair_device(user_id)
    resp = client.post(
        "/api/v1/devices/dev-in/input",
        json={"kind": "mouse_move", "dx": "muito"},
        headers=headers,
    )
    assert resp.status_code == 422


class FakeWS:
    def __init__(self):
        self.sent = []

    async def send_json(self, message):
        self.sent.append(message)


def test_input_relayed_to_connected_agent():
    headers, user_id = _register()
    _pair_device(user_id)

    fake = FakeWS()
    manager.register("dev-in", fake)
    try:
        resp = client.post("/api/v1/devices/dev-in/input", json=MOVE, headers=headers)
        assert resp.status_code == 204
        assert fake.sent == [{"type": "input", "action": MOVE}]
    finally:
        manager.unregister("dev-in", fake)


def test_move_to_relayed_and_validated():
    headers, user_id = _register()
    _pair_device(user_id)
    fake = FakeWS()
    manager.register("dev-in", fake)
    try:
        # Ação válida (0–1) é retransmitida.
        action = {"kind": "mouse_move_to", "x": 0.5, "y": 0.25}
        assert client.post(
            "/api/v1/devices/dev-in/input", json=action, headers=headers
        ).status_code == 204
        assert fake.sent[-1] == {"type": "input", "action": action}
        # Fora do intervalo [0,1] → 422.
        assert client.post(
            "/api/v1/devices/dev-in/input",
            json={"kind": "mouse_move_to", "x": 1.5, "y": 0.2},
            headers=headers,
        ).status_code == 422
    finally:
        manager.unregister("dev-in", fake)


def test_keyboard_actions_relayed():
    headers, user_id = _register()
    _pair_device(user_id)
    fake = FakeWS()
    manager.register("dev-in", fake)
    actions = [
        {"kind": "key_text", "text": "Olá mundo"},
        {"kind": "key_press", "key": "enter"},
        {"kind": "key_combo", "modifiers": ["ctrl"], "key": "c"},
    ]
    try:
        for action in actions:
            resp = client.post(
                "/api/v1/devices/dev-in/input", json=action, headers=headers
            )
            assert resp.status_code == 204
        assert fake.sent == [{"type": "input", "action": a} for a in actions]
    finally:
        manager.unregister("dev-in", fake)


def test_invalid_keyboard_actions_are_422():
    headers, user_id = _register()
    _pair_device(user_id)
    fake = FakeWS()
    manager.register("dev-in", fake)
    try:
        # Tecla especial desconhecida.
        assert client.post(
            "/api/v1/devices/dev-in/input",
            json={"kind": "key_press", "key": "tecla_inexistente"},
            headers=headers,
        ).status_code == 422
        # Combo sem modificadores.
        assert client.post(
            "/api/v1/devices/dev-in/input",
            json={"kind": "key_combo", "modifiers": [], "key": "c"},
            headers=headers,
        ).status_code == 422
        # Texto vazio.
        assert client.post(
            "/api/v1/devices/dev-in/input",
            json={"kind": "key_text", "text": ""},
            headers=headers,
        ).status_code == 422
    finally:
        manager.unregister("dev-in", fake)


def test_key_replace_e_atomico_e_limitado():
    """Apagar + digitar numa ação só.

    Precisa ser atômico porque o canal de dados é não ordenado: em mensagens
    separadas, o texto novo poderia chegar antes dos backspaces.
    """
    adaptador = TypeAdapter(InputAction)
    acao = adaptador.validate_python(
        {"kind": "key_replace", "backspaces": 4, "text": "arquivo "}
    )
    assert acao.backspaces == 4
    assert acao.text == "arquivo "

    # O teto não é sobre a interface: é sobre o que uma mensagem adulterada
    # poderia mandar o computador apagar.
    for invalido in ({"backspaces": 65}, {"backspaces": -1}, {"text": ""}):
        try:
            adaptador.validate_python(
                {"kind": "key_replace", "backspaces": 1, "text": "x", **invalido}
            )
        except ValidationError:
            continue
        raise AssertionError(f"deveria recusar {invalido}")


def test_apertar_e_soltar_para_selecionar_texto():
    """Duplo clique que segura: e como se seleciona texto arrastando."""
    adaptador = TypeAdapter(InputAction)
    apertar = adaptador.validate_python(
        {"kind": "mouse_press", "button": "left", "clicks": 2}
    )
    assert apertar.clicks == 2
    # Sem clicks = aperta e segura, sem clicar antes.
    assert adaptador.validate_python({"kind": "mouse_press"}).clicks == 1
    assert adaptador.validate_python({"kind": "mouse_release"}).button == "left"

    # Triplo clique existe (seleciona o paragrafo); quadruplo nao.
    assert adaptador.validate_python({"kind": "mouse_press", "clicks": 3}).clicks == 3
    for invalido in (0, 4):
        try:
            adaptador.validate_python({"kind": "mouse_press", "clicks": invalido})
        except ValidationError:
            continue
        raise AssertionError(f"clicks={invalido} deveria ser recusado")
