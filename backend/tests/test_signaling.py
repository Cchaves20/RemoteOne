"""Testes da sinalização de WebRTC (Fase 1 do docs/webrtc-plano.md).

O backend só traduz e roteia, então dá para verificar a coisa inteira sem
WebRTC: as funções puras de tradução, o roteamento por sessão (incluindo a
recusa de sessão de outro dispositivo) e a fila de saída do viewer.
"""

import asyncio

import pytest

from app.connections import Viewer, ViewerRegistry
from app.signaling import (
    SignalingError,
    close_session,
    is_signaling,
    to_agent,
    to_viewer,
)

# --- tradução (funções puras) -------------------------------------------------


def test_is_signaling_reconhece_so_o_que_deve():
    assert is_signaling({"type": "webrtc_offer", "sdp": "v=0"})
    assert is_signaling({"type": "webrtc_ice", "candidate": ""})
    assert not is_signaling({"type": "start_stream"})
    assert not is_signaling({"sem": "tipo"})
    assert not is_signaling("nem é dict")


def test_offer_recebe_o_session_id_do_backend():
    out = to_agent({"type": "webrtc_offer", "sdp": "v=0\r\n"}, "sessao-1")
    assert out == {
        "type": "webrtc_offer",
        "session_id": "sessao-1",
        "sdp": "v=0\r\n",
    }


def test_ice_completo_e_repassado():
    out = to_agent(
        {
            "type": "webrtc_ice",
            "candidate": "candidate:1 1 udp 2130706431 192.168.0.10 54321 typ host",
            "sdp_mid": "0",
            "sdp_mline_index": 0,
        },
        "sessao-2",
    )
    assert out["session_id"] == "sessao-2"
    assert out["sdp_mid"] == "0"
    assert out["sdp_mline_index"] == 0
    assert "typ host" in out["candidate"]


def test_candidato_vazio_e_valido():
    # Candidato vazio significa "acabaram os candidatos" e precisa passar:
    # descartá-lo deixaria a outra ponta esperando para sempre.
    out = to_agent({"type": "webrtc_ice", "candidate": ""}, "s")
    assert out["candidate"] == ""
    assert out["sdp_mid"] is None
    assert out["sdp_mline_index"] is None


@pytest.mark.parametrize(
    "message",
    [
        {"type": "webrtc_offer"},  # sem sdp
        {"type": "webrtc_offer", "sdp": ""},  # sdp vazio
        {"type": "webrtc_offer", "sdp": 42},  # sdp não é texto
        {"type": "webrtc_ice"},  # sem candidate
        {"type": "webrtc_ice", "candidate": None},
        {"type": "webrtc_ice", "candidate": "c", "sdp_mid": 7},
        {"type": "webrtc_ice", "candidate": "c", "sdp_mline_index": "0"},
        # bool é subclasse de int: se passasse, viraria índice 1 calado.
        {"type": "webrtc_ice", "candidate": "c", "sdp_mline_index": True},
        {"type": "outra_coisa"},
    ],
)
def test_mensagem_malformada_e_recusada(message):
    with pytest.raises(SignalingError):
        to_agent(message, "s")


def test_to_viewer_remove_o_session_id():
    assert to_viewer(
        {"type": "webrtc_answer", "session_id": "s", "sdp": "v=0"}
    ) == {"type": "webrtc_answer", "sdp": "v=0"}


def test_close_session():
    assert close_session("abc") == {"type": "webrtc_close", "session_id": "abc"}


# --- roteamento por sessão ----------------------------------------------------


class FakeWS:
    def __init__(self):
        self.json_sent = []
        self.bytes_sent = []

    async def send_json(self, message):
        self.json_sent.append(message)

    async def send_bytes(self, data):
        self.bytes_sent.append(data)


def test_sessoes_sao_unicas_por_viewer():
    a, b = Viewer(FakeWS()), Viewer(FakeWS())
    assert a.session_id != b.session_id


def test_by_session_encontra_o_viewer_do_dispositivo():
    registry = ViewerRegistry()
    viewer = Viewer(FakeWS())
    registry.add("dev-1", viewer)
    assert registry.by_session(viewer.session_id, "dev-1") is viewer


def test_by_session_recusa_sessao_de_outro_dispositivo():
    # É a checagem que impede um agente de responder na sessão de outro PC.
    registry = ViewerRegistry()
    viewer = Viewer(FakeWS())
    registry.add("dev-1", viewer)
    assert registry.by_session(viewer.session_id, "dev-2") is None


def test_by_session_de_sessao_inexistente():
    assert ViewerRegistry().by_session("nao-existe", "dev-1") is None


def test_remover_viewer_apaga_a_sessao():
    registry = ViewerRegistry()
    viewer = Viewer(FakeWS())
    registry.add("dev-1", viewer)
    registry.remove("dev-1", viewer)
    assert registry.by_session(viewer.session_id, "dev-1") is None


# --- fila de saída do viewer --------------------------------------------------


def _drain(viewer: Viewer, websocket: FakeWS) -> None:
    """Roda o sender até ele ficar sem nada para enviar."""

    async def run():
        task = asyncio.create_task(viewer.run_sender())
        # Uma volta do event loop basta para o sender esvaziar o que há.
        await asyncio.sleep(0)
        await asyncio.sleep(0)
        task.cancel()

    asyncio.run(run())


def test_sinalizacao_nao_e_descartada_quando_acumula():
    # Frames podem ser descartados; sinalização não — perder uma resposta SDP
    # ou um candidato quebra a negociação.
    websocket = FakeWS()
    viewer = Viewer(websocket)
    viewer.signal({"type": "webrtc_answer", "sdp": "v=0"})
    viewer.signal({"type": "webrtc_ice", "candidate": "c1"})
    viewer.signal({"type": "webrtc_ice", "candidate": "c2"})
    _drain(viewer, websocket)
    assert [m.get("candidate", m["type"]) for m in websocket.json_sent] == [
        "webrtc_answer",
        "c1",
        "c2",
    ]


def test_frames_continuam_sendo_descartados():
    websocket = FakeWS()
    viewer = Viewer(websocket)
    viewer.offer(b"velho")
    viewer.offer(b"novo")
    _drain(viewer, websocket)
    assert websocket.bytes_sent == [b"novo"]


def test_sinalizacao_sai_antes_do_frame():
    # A negociação é pequena e sensível a atraso; o frame pode esperar a volta.
    websocket = FakeWS()
    viewer = Viewer(websocket)
    viewer.offer(b"frame")
    viewer.signal({"type": "webrtc_answer", "sdp": "v=0"})
    _drain(viewer, websocket)
    assert websocket.json_sent and websocket.bytes_sent == [b"frame"]
