"""A reconexão do agente, e o que sobra da conexão antiga.

Uma conexão TCP pode morrer sem que nenhum dos lados saiba: a máquina virtual
suspende, o Wi-Fi troca de rede, o notebook dorme. O agente reconecta por um
socket **novo** enquanto o antigo continua pendurado no servidor — e o antigo
só morre quando o sistema operacional desiste, o que leva minutos.

O que estes testes guardam é o que acontece nesse intervalo, e depois dele.
"""

from app.agents import AgentRegistry
from app.connections import ConnectionManager
from app.main import SILENCIO_DO_AGENTE, encerrar_agente
from app.protocol import Hello
from app.screen import frame_store


class SocketFalso:
    """Só precisa ser um objeto distinto de outro: a conferência é por
    identidade, não por conteúdo."""


def _hello(device_id: str) -> Hello:
    return Hello(
        device_id=device_id,
        hostname="matebook",
        os="windows",
        agent_version="0.1.0",
    )


def _preparar(monkeypatch, device_id: str):
    """Um registro e um gerenciador limpos, no lugar dos globais do módulo."""
    import app.main as main_mod

    gerenciador = ConnectionManager()
    registro = AgentRegistry()
    monkeypatch.setattr(main_mod, "manager", gerenciador)
    monkeypatch.setattr(main_mod, "registry", registro)
    frame_store.clear(device_id)
    return gerenciador, registro


def test_a_conexao_antiga_que_morre_nao_apaga_a_sessao_nova(monkeypatch):
    """O defeito.

    O agente volta por um socket novo, e minutos depois o antigo finalmente
    morre. Antes desta correção, esse encerramento atrasado apagava o registro
    de presença e o último quadro da tela — de uma sessão que estava
    funcionando. Nada dava erro: o computador simplesmente sumia do app.
    """
    gerenciador, registro = _preparar(monkeypatch, "dev-1")
    antiga, nova = SocketFalso(), SocketFalso()

    gerenciador.register("dev-1", antiga)
    registro.register(_hello("dev-1"))
    gerenciador.register("dev-1", nova)  # a reconexão substitui
    registro.register(_hello("dev-1"))
    frame_store.put("dev-1", b"quadro-da-sessao-nova")

    ficou_offline = encerrar_agente("dev-1", antiga)

    assert ficou_offline is False
    assert gerenciador.is_online("dev-1"), "a conexão nova foi derrubada junto"
    assert gerenciador.get("dev-1") is nova
    assert registro.get("dev-1") is not None, "o computador sumiria do app"
    assert frame_store.get("dev-1") == b"quadro-da-sessao-nova"


def test_a_conexao_atual_que_morre_limpa_tudo(monkeypatch):
    """O outro lado, que precisa continuar valendo: sem reconexão nenhuma, sair
    é sair. Uma correção que só protegesse a sessão nova deixaria todo agente
    desconectado parecendo online para sempre."""
    gerenciador, registro = _preparar(monkeypatch, "dev-2")
    unica = SocketFalso()

    gerenciador.register("dev-2", unica)
    registro.register(_hello("dev-2"))
    frame_store.put("dev-2", b"quadro")

    ficou_offline = encerrar_agente("dev-2", unica)

    assert ficou_offline is True
    assert not gerenciador.is_online("dev-2")
    assert registro.get("dev-2") is None
    assert frame_store.get("dev-2") is None


def test_o_prazo_de_silencio_cobre_mais_de_uma_batida_perdida():
    """O número em si, porque errá-lo dá os dois defeitos opostos.

    Curto demais derruba a conexão por uma batida perdida em rede ruim; longo
    demais é o problema original de volta. O agente bate a cada 10s, então o
    prazo precisa cobrir mais de duas batidas e não muito mais que três — e o
    `SEM_RESPOSTA` do lado do agente (`client.rs`) usa o mesmo valor, porque a
    conexão meio-aberta engana os dois lados e os dois precisam desistir.
    """
    assert 25 <= SILENCIO_DO_AGENTE <= 40
