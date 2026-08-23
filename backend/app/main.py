import asyncio
import hmac
import json
import logging
from contextlib import asynccontextmanager

import jwt
from fastapi import Depends, FastAPI, WebSocket, WebSocketDisconnect
from sqlalchemy.orm import Session

from app import entrega, pairing
from app.agents import AgentRegistry
from app.auth import router as auth_router
from app.auth import get_current_user, sessao_valida
from app.automations import enviar_agenda
from app.automations import router as automations_router
from app.config import settings
from app.connections import Viewer, manager, viewers
from app.db import SessionLocal, get_db, init_db
from app.devices import router as devices_router
from app.ice import ice_servers
from app.models import User
from app.profiles import router as profiles_router
from app.protocol import (
    Ack,
    AppList,
    AutomationResult,
    BrightnessState,
    Clipboard,
    ClipboardChanged,
    Error,
    FileChunk,
    FileDone,
    FileList,
    Foreground,
    Hello,
    KeepAwakeState,
    LaunchManyResult,
    MonitorList,
    PairCode,
    Paired,
    PresentationState,
    SystemStats,
    Unpair,
    Unpaired,
    WebrtcAnswer,
    WebrtcIce,
    Welcome,
    parse_client_message,
)
from app.rpc import pending
from app.screen import frame_store
from app.security import decode_token
from app.signaling import (
    SignalingError,
    close_session,
    is_signaling,
    to_agent,
    to_viewer,
)
from app.transfers import transfers

logger = logging.getLogger("deskside")


@asynccontextmanager
async def lifespan(_app: FastAPI):
    # Cria as tabelas ausentes na subida (MVP; futuramente via Alembic).
    init_db()
    yield


app = FastAPI(title=settings.app_name, version=settings.version, lifespan=lifespan)
app.include_router(auth_router)
app.include_router(devices_router)
app.include_router(profiles_router)
app.include_router(automations_router)

# Registro de agentes conectados (em memória; ver app/agents.py).
registry = AgentRegistry()


# Recursos que este código sabe fazer, para dar de responder "o que está no ar
# é novo?" sem adivinhação. A versão do app sobe devagar e não serve para isso;
# um recurso que aparece aqui é um recurso que o binário implantado tem.
#
# Nasceu de um problema repetido: por três vezes um defeito foi rastreado até
# um componente desatualizado, e cada diagnóstico começou por dedução em vez de
# medida. `curl /health` agora responde direto.
FEATURES = [
    "pairing",
    "input",
    "screen-jpeg",
    "apps",
    "wake-on-lan",
    "totp",
    "webrtc-signaling",
    "system-stats",
    "media-keys",
    "file-transfer",
    "foreground-app",
    "audio-stream",
    "ice-servers",
    "clipboard",
    "monitors",
    "control-profiles",
    "keep-awake",
    "brightness",
    "launch-many",
    "window-zones",
    "automations",
    "signup-verification",
    "session-revocation",
    "contact-verification",
    "close-all",
    "focus-app",
    "automation-schedule",
    "save-all",
    "presentation-mode",
    "rate-limit",
    # O agente sabe se tirar da conta sozinho (botão de desinstalar da janela).
    "agent-unpair",
    # Planos: versão grátis permanente, paga sem limitação. Ver app/plano.py.
    "planos",
]


@app.get("/health")
def health() -> dict:
    """Disponibilidade e o que este backend implementa.

    Usada pela CI, por orquestradores e para conferir qual código está no ar.
    """
    return {
        "status": "ok",
        "version": settings.version,
        "features": FEATURES,
        # Quais caminhos de verificação entregam de verdade. Sem isto, "o
        # código não chegou" começaria por dedução: o binário no ar pode ser
        # mais velho que o `.env`, o `.env` pode ter um nome de variável
        # errado, e nada disso aparece de fora.
        "delivery": entrega.configurado(),
    }


@app.get("/api/v1")
def api_root() -> dict[str, str]:
    """Raiz da API v1. Autenticação e pareamento entram aqui (Etapas 2 e 5)."""
    return {"name": settings.app_name}


@app.get("/api/v1/agents")
def list_agents(
    current_user: User = Depends(get_current_user),
    db: Session = Depends(get_db),
) -> dict:
    """Os computadores **desta conta** que estão conectados agora.

    Já foi público, e era o defeito mais grave que esta revisão encontrou.

    O que devolvia: `device_id` e `hostname` de **todos** os agentes conectados,
    de todas as contas, sem autenticação nenhuma. Parecia inofensivo — uma
    listagem de diagnóstico —, mas o `device_id` é a única credencial que o
    canal `/ws/agent` exige. Publicá-lo entregava, a quem só sabia o endereço do
    servidor, a chave de todo computador que estivesse ligado no momento.

    O encadeamento: pegar os ids aqui, abrir um `/ws/agent` com o id de outra
    pessoa e passar a ser aquele computador aos olhos do servidor — que sobrepõe
    o registro sem perguntar. O agente de verdade fica órfão (o dono vê o
    computador cair) e o impostor passa a receber o que o dono manda: cada tecla
    digitada, o conteúdo da área de transferência, os pedidos de arquivo. Podia
    responder com a tela que quisesse.

    Nada disso exigia conta, senha ou token. Só o endereço do site.

    Agora exige login e mostra **apenas os aparelhos do próprio dono** — que é
    tudo para o que a listagem servia.
    """
    meus = {d.device_id for d in pairing.list_devices(db, current_user)}
    return {"agents": [a.as_dict() for a in registry.list() if a.device_id in meus]}


async def _mandar_agenda(device_id: str) -> None:
    """Entrega a este computador as automações que ele deve disparar sozinho.

    Falha em silêncio de propósito: um erro aqui não pode derrubar a conexão do
    agente. Sem agenda, o computador continua servindo para tudo o mais - e a
    próxima reconexão tenta de novo.
    """
    try:
        with SessionLocal() as db:
            device = pairing.get_device(db, device_id)
            if device is None:
                return
            await enviar_agenda(db, device.user_id, device_id)
    except Exception:
        logger.exception("falha ao enviar a agenda para %s", device_id)


def _paired_email(device_id: str) -> str | None:
    """Como a conta dona do dispositivo se identifica, ou None se não pareado.

    E-mail **ou telefone**: desde que a conta possa ser criada por telefone, o
    e-mail é opcional, e devolver `None` para uma conta que existe faria a
    janela do agente dizer "não pareado" numa máquina pareada.
    """
    with SessionLocal() as db:
        device = pairing.get_device(db, device_id)
        if device is None:
            return None
        return device.user.email or device.user.phone or f"conta {device.user.id}"


def _segredo_do_aparelho(device_id: str) -> str | None:
    """O segredo guardado para este computador, para reentregá-lo ao agente."""
    with SessionLocal() as db:
        device = pairing.get_device(db, device_id)
        return device.agent_secret if device else None


def _pairing_intro(hello: Hello) -> dict:
    """Mensagem enviada logo após o welcome: `paired` se já vinculado, senão `pair_code`."""
    email = _paired_email(hello.device_id)
    if email is not None:
        return Paired(user_email=email).model_dump()
    with SessionLocal() as db:
        code = pairing.create_pairing_request(
            db, hello.device_id, hello.hostname, hello.os, settings.pairing_ttl_seconds
        )
    return PairCode(code=code, expires_in_seconds=settings.pairing_ttl_seconds).model_dump()


class SegredoRecusado(Exception):
    """O agente não provou ser este computador."""


def _autorizar_agente(device_id: str, apresentado: str | None) -> tuple[str | None, bool]:
    """Confere o segredo do agente.

    Devolve `(segredo_a_entregar, autenticado)`. O segundo é o que separa "esta
    conexão passou" de "esta conexão **provou** ser este computador", e a
    diferença importa para as ações destrutivas: enquanto a compatibilidade com
    agentes antigos estiver aberta, passar é fácil demais.

    É verdadeiro em dois casos, e o segundo não é frouxidão: quando o segredo
    apresentado confere, e quando **este servidor acabou de entregar** o segredo
    nesta mesma conexão. O socket que recebeu o segredo é, por definição,
    aquele em que o servidor confia — e sem isso, parear e desistir em seguida
    exigiria reconectar antes de poder desparear.
    

    Antes desta conferência, o canal `/ws/agent` **não tinha autenticação**: o
    `device_id` era a credencial, e ele nunca foi tratado como uma — aparece no
    diário, no banco, em todo backup e no caminho da URL do canal de tela. Quem
    o obtivesse por qualquer desses caminhos passava a ser aquele computador,
    recebendo cada tecla que o dono digitasse.

    Os três casos, e cada um existe por um motivo:

    **Não pareado.** Autorizado sem segredo. É preciso: o agente precisa
    conectar para receber o código de pareamento, e ainda não há vínculo a
    proteger. Ele só recebe um segredo quando alguém o reivindicar.

    **Pareado e sem segredo** (linha criada antes desta mudança). Se o agente
    disser que sabe guardar um — mandando `secret: ""` —, emite. É adoção na
    primeira conexão, e ela dura uma conexão só: da segunda em diante o segredo
    é exigido.

    **Pareado e com segredo.** Compara em tempo constante. Errar fecha a
    conexão.

    O caso que exige cuidado é o quarto, e ele é a razão de `secret` ter três
    estados: um agente **antigo** manda `None`, porque não conhece o campo.
    Emitir um segredo para ele seria trancá-lo do lado de fora na reconexão
    seguinte — o computador ficaria offline para sempre, sem nada na tela
    explicando por quê, e o dono não teria como adivinhar que precisa atualizar.
    Então `None` não adota: é aceito enquanto `exigir_segredo_do_agente` for
    falso, e recusado depois que essa trava se fechar.
    """
    with SessionLocal() as db:
        device = pairing.get_device(db, device_id)
        if device is None:
            return None, False  # ainda não pareado: nada a proteger

        if apresentado is None:
            if settings.exigir_segredo_do_agente:
                raise SegredoRecusado("agente sem segredo")
            return None, False

        if not device.agent_secret:
            if not apresentado:
                novo = pairing.novo_segredo_de_agente()
                device.agent_secret = novo
                db.commit()
                logger.info("segredo emitido na adoção do aparelho %s", device_id)
                return novo, True
            # Apresentou um segredo que o servidor não conhece. Não é adoção —
            # é alguém com um segredo de outro lugar, ou um banco restaurado
            # por cima. De qualquer forma, não se aceita o que não se emitiu.
            raise SegredoRecusado("segredo desconhecido")

        if not apresentado or not hmac.compare_digest(apresentado, device.agent_secret):
            raise SegredoRecusado("segredo inválido")
        return None, True


def _client_public_ip(websocket: WebSocket) -> str | None:
    """IP público do agente. Atrás do Caddy, vem no cabeçalho X-Forwarded-For."""
    forwarded = websocket.headers.get("x-forwarded-for")
    if forwarded:
        return forwarded.split(",")[0].strip()
    return websocket.client.host if websocket.client else None


def _update_device_presence(device_id: str, mac: str | None, public_ip: str | None) -> None:
    """Guarda o MAC e o último IP público do dispositivo pareado (Wake-on-LAN)."""
    with SessionLocal() as db:
        device = pairing.get_device(db, device_id)
        if device is None:
            return
        changed = False
        if mac and device.mac_address != mac:
            device.mac_address = mac
            changed = True
        if public_ip and device.last_public_ip != public_ip:
            device.last_public_ip = public_ip
            changed = True
        if changed:
            db.commit()


@app.websocket("/ws/agent")
async def agent_ws(websocket: WebSocket) -> None:
    """Canal do agente desktop.

    Fluxo: o agente envia `hello` (identificação), o backend responde
    `welcome` e o registra como online. Se o dispositivo ainda não está
    pareado, o backend envia um `pair_code` para o agente exibir; quando o
    usuário reivindica o código no app, o agente recebe `paired`. Em seguida o
    agente envia `heartbeat` periodicamente, respondido com `ack`.
    """
    await websocket.accept()
    device_id: str | None = None
    paired_notified = False
    try:
        # A primeira mensagem precisa ser um hello.
        first = await websocket.receive_json()
        try:
            message = parse_client_message(first)
        except ValueError:
            await websocket.send_json(Error(message="mensagem inválida").model_dump())
            await websocket.close()
            return

        if not isinstance(message, Hello):
            await websocket.send_json(
                Error(message="esperado hello como primeira mensagem").model_dump()
            )
            await websocket.close()
            return

        device_id = message.device_id
        hostname = message.hostname
        os_name = message.os
        mac_addr = message.mac

        # **Antes** de registrar. Registrar sobrepõe a conexão anterior daquele
        # device_id, então fazer isso antes de conferir o segredo entregaria a
        # arma pela culatra: bastaria um hello inválido para derrubar o agente
        # de verdade, mesmo sendo recusado logo em seguida.
        try:
            segredo_emitido, autenticado = _autorizar_agente(device_id, message.secret)
        except SegredoRecusado as recusa:
            logger.warning("agente recusado (%s): %s", recusa, device_id)
            await websocket.send_json(Error(message=str(recusa)).model_dump())
            await websocket.close(code=4401)
            return

        pareado = _paired_email(device_id) is not None
        public_ip = _client_public_ip(websocket)
        registry.register(message)
        manager.register(device_id, websocket, public_ip)
        _update_device_presence(device_id, mac_addr, public_ip)
        logger.info("agente conectado: %s (%s)", device_id, message.hostname)
        await websocket.send_json(
            Welcome(
                server_version=settings.version,
                # Credencial de TURN **só para quem está pareado**. Ela ia junto
                # com todo welcome, e como o canal não autenticava, qualquer
                # pessoa abria um socket com um id inventado e recebia relay
                # válido por 12 horas — um relay aberto pago com a banda deste
                # servidor. Quem ainda não pareou não transmite nada, então não
                # precisa dela.
                ice_servers=ice_servers(f"agent-{device_id}") if pareado else [],
                secret=segredo_emitido,
            ).model_dump()
        )

        intro = _pairing_intro(message)
        paired_notified = intro["type"] == "paired"
        await websocket.send_json(intro)

        # A agenda vai **na conexão**, e não só quando alguém edita: o
        # computador que passou a noite desligado precisa saber o que roda hoje
        # antes de a hora chegar, e ninguém vai abrir o app para "sincronizar".
        await _mandar_agenda(device_id)

        while True:
            # Com prazo, e não um `receive()` nu. Um socket TCP pode morrer sem
            # que nenhum dos lados saiba - a máquina virtual suspende, o Wi-Fi
            # troca de rede -, e o `receive()` sem prazo espera por isso para
            # sempre. O agente reconecta por outro socket e este fica pendurado,
            # vivo aos olhos do servidor, até o sistema operacional desistir.
            #
            # O agente manda `heartbeat` a cada 10s; três batidas de silêncio
            # não são rede ruim, são conexão morta.
            try:
                packet = await asyncio.wait_for(
                    websocket.receive(), timeout=SILENCIO_DO_AGENTE
                )
            except TimeoutError:
                logger.info("agente calado por %ss: %s", SILENCIO_DO_AGENTE, device_id)
                break
            if packet["type"] == "websocket.disconnect":
                break

            # Frame de tela (binário): guarda o mais recente e o oferece aos
            # apps que estão assistindo (não bloqueia; cada um envia no seu
            # ritmo, descartando frames velhos).
            if packet.get("bytes") is not None:
                frame_store.put(device_id, packet["bytes"])
                viewers.broadcast(device_id, packet["bytes"])
                continue

            text = packet.get("text")
            if text is None:
                continue
            try:
                message = parse_client_message(json.loads(text))
            except (ValueError, json.JSONDecodeError):
                await websocket.send_json(Error(message="mensagem inválida").model_dump())
                continue

            if isinstance(message, Unpair):
                # **Exige segredo provado**, e não a mera conexão. Enquanto a
                # compatibilidade com agentes antigos estiver aberta, qualquer
                # um que soubesse o `device_id` conseguiria conectar — e sem
                # esta guarda conseguiria também apagar o pareamento de outra
                # pessoa. Um botão de sabotagem, do lado errado da porta.
                if not autenticado:
                    await websocket.send_json(
                        Error(message="desparear exige o segredo do aparelho").model_dump()
                    )
                    continue
                with SessionLocal() as db:
                    device = pairing.get_device(db, device_id)
                    if device is not None:
                        pairing.remove_device(db, device_id, device.user)
                logger.info("aparelho desparelhado pelo próprio agente: %s", device_id)
                await websocket.send_json(Unpaired().model_dump())
                paired_notified = False
            elif isinstance(message, AppList):
                # Resposta a um pedido de lista de aplicativos: entrega a quem
                # está esperando (o endpoint HTTP que fez a pergunta).
                pending.resolve(
                    message.request_id, [a.model_dump() for a in message.apps]
                )
            elif isinstance(message, MonitorList):
                pending.resolve(
                    message.request_id,
                    {
                        "monitors": [m.model_dump() for m in message.monitors],
                        "selected": message.selected,
                    },
                )
            elif isinstance(message, FileList):
                pending.resolve(
                    message.request_id,
                    {
                        "listing": message.listing.model_dump()
                        if message.listing
                        else None,
                        "error": message.error,
                    },
                )
            elif isinstance(message, FileChunk):
                # Pedaço de um arquivo indo ao celular. O `await` aqui é o que
                # segura o agente quando o celular não consome: a fila enche e
                # este socket para de ser drenado.
                download = transfers.get(message.transfer_id)
                if download is not None:
                    await download.push(message.seq, message.data)
            elif isinstance(message, FileDone):
                # Serve aos dois sentidos: fim de um download (fila) ou a
                # confirmação de um envio (pedido pendente).
                download = transfers.get(message.transfer_id)
                if download is not None:
                    await download.finish(message.ok, message.detail)
                else:
                    pending.resolve(
                        message.transfer_id,
                        {"ok": message.ok, "detail": message.detail},
                    )
            elif isinstance(message, Clipboard):
                pending.resolve(
                    message.request_id,
                    {
                        "text": message.text,
                        "files": [f.model_dump() for f in message.files],
                        "ignored": message.ignored,
                        "image": message.image,
                        "image_mime": message.image_mime,
                        "image_width": message.image_width,
                        "image_height": message.image_height,
                    },
                )
            elif isinstance(message, ClipboardChanged):
                # Aviso sem pedido: vai para quem estiver com a tela aberta.
                # Se ninguém estiver, some - e é o certo: guardar o que alguém
                # copiou no computador para entregar depois seria guardar
                # justamente o tipo de coisa que não se deve guardar.
                enviados = viewers.notify(
                    device_id, {"type": "clipboard", "text": message.text}
                )
                logger.debug("área de transferência → %s viewer(s)", enviados)
            elif isinstance(message, Foreground):
                # Primeiro plano: o `None` é resposta legítima (nenhuma janela
                # em foco), então vai como está para quem perguntou.
                pending.resolve(
                    message.request_id,
                    {"app": message.app.model_dump() if message.app else None},
                )
            elif isinstance(message, KeepAwakeState):
                pending.resolve(
                    message.request_id,
                    {
                        "enabled": message.enabled,
                        "holding": message.holding,
                        "source": message.source,
                    },
                )
            elif isinstance(message, LaunchManyResult):
                pending.resolve(
                    message.request_id,
                    {"results": [r.model_dump() for r in message.results]},
                )
            elif isinstance(message, AutomationResult):
                # Uma resposta só, no fim da sequência inteira. O `error` sobe
                # mesmo quando `ok` é verdadeiro: é onde cabe o aviso de que a
                # janela abriu mas não foi para o lugar pedido - aviso não é
                # falha, e esconder não ajudaria ninguém.
                pending.resolve(
                    message.request_id,
                    {"results": [r.model_dump() for r in message.results]},
                )
            elif isinstance(message, PresentationState):
                pending.resolve(
                    message.request_id,
                    {
                        "on": message.on,
                        "auto": message.auto,
                        "detected": message.detected,
                        "supported": message.supported,
                    },
                )
            elif isinstance(message, BrightnessState):
                # O erro vai junto em vez de virar exceção: quem pediu precisa
                # saber *por que* não deu (monitor externo, por exemplo), e um
                # 500 genérico jogaria fora a única explicação que existe.
                pending.resolve(
                    message.request_id,
                    {"level": message.level, "error": message.error},
                )
            elif isinstance(message, SystemStats):
                # Métricas medidas: entrega a quem pediu (o endpoint HTTP).
                pending.resolve(message.request_id, message.stats.model_dump())
            elif isinstance(message, (WebrtcAnswer, WebrtcIce)):
                # Sinalização de volta: acha o app daquela sessão e repassa.
                # `by_session` confere que a sessão é deste dispositivo — sem
                # isso, um agente poderia responder na sessão de outro PC.
                viewer = viewers.by_session(message.session_id, device_id)
                if viewer is None:
                    logger.info(
                        "sinalização descartada: sessão %s não é de %s",
                        message.session_id,
                        device_id,
                    )
                else:
                    viewer.signal(to_viewer(message.model_dump()))
            elif isinstance(message, Hello):
                # Re-identificação (ex.: após reconexão na mesma sessão).
                device_id = message.device_id
                hostname = message.hostname
                os_name = message.os
                mac_addr = message.mac
                public_ip = _client_public_ip(websocket)
                registry.register(message)
                manager.register(device_id, websocket, public_ip)
                _update_device_presence(device_id, mac_addr, public_ip)
                await websocket.send_json(
                    Welcome(
                        server_version=settings.version,
                        ice_servers=ice_servers(f"agent-{device_id}"),
                    ).model_dump()
                )
            else:  # Heartbeat
                registry.heartbeat(device_id)
                await websocket.send_json(Ack().model_dump())
                # Detecta mudanças de pareamento entre heartbeats:
                #  - vinculado agora → avisa o agente (`paired`);
                #  - desvinculado no app → gera e reexibe um novo código, para o
                #    usuário poder reparear sem reiniciar o agente.
                now_paired = _paired_email(device_id) is not None
                if now_paired and not paired_notified:
                    email = _paired_email(device_id)
                    # O segredo vai junto do aviso de pareamento: é o instante
                    # em que ele nasce (`pairing.claim` o sorteia), e é a única
                    # vez que o servidor pode entregá-lo. Guardar para depois
                    # deixaria o aparelho pareado e sem segredo por um tempo —
                    # que é exatamente a janela de adoção por quem chegar antes.
                    await websocket.send_json(
                        Paired(
                            user_email=email, secret=_segredo_do_aparelho(device_id)
                        ).model_dump()
                    )
                    # O servidor acabou de entregar o segredo por este socket:
                    # daqui em diante ele é uma conexão autenticada. Sem isto,
                    # parear e desistir em seguida exigiria reconectar antes de
                    # poder desparear — e ninguém entenderia por quê.
                    autenticado = True
                    paired_notified = True
                    # Acabou de parear: guarda MAC/IP para o Wake-on-LAN.
                    _update_device_presence(device_id, mac_addr, public_ip)
                elif not now_paired and paired_notified:
                    paired_notified = False
                    with SessionLocal() as db:
                        code = pairing.create_pairing_request(
                            db, device_id, hostname, os_name, settings.pairing_ttl_seconds
                        )
                    await websocket.send_json(
                        PairCode(
                            code=code, expires_in_seconds=settings.pairing_ttl_seconds
                        ).model_dump()
                    )
    except WebSocketDisconnect:
        pass
    finally:
        if device_id is not None:
            if encerrar_agente(device_id, websocket):
                logger.info("agente desconectado: %s", device_id)
            else:
                logger.info(
                    "conexão antiga de %s encerrada; a nova continua", device_id
                )


def encerrar_agente(device_id: str, websocket) -> bool:
    """Desfaz o registro **desta** conexão. Devolve se o agente ficou offline.

    Existe por causa de uma assimetria que só aparece na reconexão. O
    `manager.unregister` já conferia se a conexão registrada era esta antes de
    remover; o registro de presença e o último quadro da tela não conferiam
    nada. Só que o agente volta por um **socket novo** enquanto o antigo ainda
    está pendurado — a conexão meio-aberta pode levar minutos para morrer —, e
    ao morrer ela apagava estado da sessão nova, que estava funcionando.

    É a mesma armadilha das cascatas do `User` e do estado que sobrava no app: o
    que não for descartado com cuidado não fica esquecido e inofensivo, some com
    o que é de outro.

    Função, e não o corpo do `finally`, para poder ser testada sem depender de
    duas conexões WebSocket de verdade fechando na ordem certa.
    """
    substituido = (
        manager.is_online(device_id) and manager.get(device_id) is not websocket
    )
    manager.unregister(device_id, websocket)
    if substituido:
        return False
    registry.unregister(device_id)
    frame_store.clear(device_id)
    return True


#: De quanto em quanto tempo uma sessão de tela **já aberta** reconfere se ainda
#: pode existir.
#:
#: Meio minuto é o atraso máximo entre "expulsar alguém" e a expulsão acontecer
#: de fato. Mais curto não melhora nada perceptível e multiplica consultas ao
#: banco por espectador; mais longo deixa uma janela grande justamente no
#: momento em que a pessoa está com pressa.
REVALIDAR_VIEWER_SEGUNDOS = 30


async def _vigiar_vinculo(websocket: WebSocket, credencial: dict, device_id: str) -> None:
    """Fecha a sessão de tela quando a conta deixa de poder vê-la.

    Numa tarefa à parte porque o laço principal precisa de um `receive()` que
    **nunca** seja cancelado: cancelar uma leitura de WebSocket no meio pode
    descartar a mensagem que estava chegando, e aqui as mensagens são a
    sinalização do WebRTC — perder uma é o vídeo não abrir.

    Dorme e confere, em vez de ser acordada por um evento, porque a revogação
    acontece noutro processo (uma troca de senha por HTTP) e não há evento a
    escutar. Trinta segundos é o atraso máximo entre expulsar alguém e a
    expulsão acontecer.
    """
    try:
        while True:
            await asyncio.sleep(REVALIDAR_VIEWER_SEGUNDOS)
            if not _vinculo_do_viewer_vale(credencial, device_id):
                logger.info("sessão de tela revogada: %s", device_id)
                await websocket.close(code=4401)
                return
    except asyncio.CancelledError:
        pass


def _vinculo_do_viewer_vale(payload: dict, device_id: str) -> bool:
    """A conta do token ainda pode ver este dispositivo?

    Separado do `_authenticate_viewer` porque a reconferência **não** olha a
    validade do token, e isso é deliberado.

    O `exp` do access token dura 15 minutos e existe para limitar o estrago de
    um token roubado — ou seja, para limitar quantas conexões **novas** ele
    abre. Aplicá-lo a uma conexão já autenticada derrubaria toda sessão de
    controle no meio, a cada quinze minutos, e trocaria um problema de segurança
    por um defeito que qualquer usuário encontra no primeiro uso longo.

    O que precisa ser reconferido é **revogação**, e é o que esta função faz: a
    conta ainda existe, o aparelho ainda é dela, e a geração de sessão do token
    ainda é a atual. Trocar a senha, desparear o computador ou apagar a conta
    passam a fechar a tela em até `REVALIDAR_VIEWER_SEGUNDOS`.
    """
    with SessionLocal() as db:
        device = pairing.get_device(db, device_id)
        if device is None or str(device.user_id) != str(payload.get("sub")):
            return False
        user = db.get(User, device.user_id)
        return user is not None and sessao_valida(payload, user)


def _authenticate_viewer(token: str, device_id: str) -> dict | None:
    """Valida o token e a posse do dispositivo para assistir à tela.

    Devolve o conteúdo do token quando vale, e `None` quando não — quem chama
    precisa guardá-lo para reconferir o vínculo enquanto a sessão durar, sem ter
    de reabrir o token a cada meio minuto.

    A conferência de geração (`sessao_valida`) é a que não pode faltar: sem ela,
    trocar a senha fecharia as rotas HTTP e deixaria aberto justamente o canal
    que mostra a tela do computador e recebe teclado e mouse.
    """
    try:
        payload = decode_token(token)
    except jwt.PyJWTError:
        return None
    if payload.get("type") != "access":
        return None
    return payload if _vinculo_do_viewer_vale(payload, device_id) else None


# Paradas de transmissão agendadas por dispositivo. Ao sair o último viewer,
# o stream é mantido "aquecido" por alguns segundos antes de parar de fato —
# assim, voltar à tela logo em seguida é instantâneo (Etapa de refino #16).
#: Silêncio máximo de um agente antes de o servidor fechar a conexão.
#:
#: Três batidas do heartbeat de 10s, com folga. O par disto vive no agente
#: (`SEM_RESPOSTA`, em `client.rs`): os dois lados precisam desistir, porque a
#: conexão meio-aberta engana os dois.
SILENCIO_DO_AGENTE = 35

_pending_stops: dict[str, asyncio.Task] = {}
_STREAM_GRACE_SECONDS = 8

# Faixas aceitas para o ajuste de qualidade/desempenho vindo do app.
_FPS_RANGE = (1, 30)
_QUALITY_RANGE = (20, 90)
_WIDTH_RANGE = (640, 1920)


def _clamp(value: int, bounds: tuple[int, int]) -> int:
    low, high = bounds
    return max(low, min(high, value))


def _start_stream_message(auth: dict) -> dict:
    """Monta o start_stream com a qualidade pedida pelo app (ou o padrão)."""
    message: dict = {"type": "start_stream", "max_fps": settings.stream_fps}
    fps = auth.get("fps")
    if isinstance(fps, int):
        message["max_fps"] = _clamp(fps, _FPS_RANGE)
    quality = auth.get("quality")
    if isinstance(quality, int):
        message["quality"] = _clamp(quality, _QUALITY_RANGE)
    max_width = auth.get("max_width")
    if isinstance(max_width, int):
        message["max_width"] = _clamp(max_width, _WIDTH_RANGE)
    return message


async def _delayed_stop(device_id: str) -> None:
    try:
        await asyncio.sleep(_STREAM_GRACE_SECONDS)
    except asyncio.CancelledError:
        return
    _pending_stops.pop(device_id, None)
    if viewers.count(device_id) == 0:
        await manager.send_to_agent(device_id, {"type": "stop_stream"})
        frame_store.clear(device_id)


@app.websocket("/ws/viewer/{device_id}")
async def viewer_ws(websocket: WebSocket, device_id: str) -> None:
    """Canal do app para assistir à tela em tempo real.

    O app envia `{"token": "..."}` como primeira mensagem; autenticado e sendo
    dono do dispositivo, passa a receber os frames JPEG (binários) empurrados
    pelo backend. A transmissão do agente é ligada ao conectar o primeiro
    viewer e desligada alguns segundos após o último sair (stream aquecido).
    """
    await websocket.accept()
    viewer = Viewer(websocket)
    registered = False
    sender_task: asyncio.Task | None = None
    vigia: asyncio.Task | None = None
    try:
        auth = await websocket.receive_json()
        credencial = _authenticate_viewer(auth.get("token", ""), device_id)
        if credencial is None:
            await websocket.close(code=4401)  # não autorizado
            return

        count = viewers.add(device_id, viewer)
        registered = True
        sender_task = asyncio.create_task(viewer.run_sender())

        # Se havia uma parada agendada, o agente ainda está transmitindo
        # (aquecido): cancela a parada e a entrada é instantânea. Senão, e
        # sendo o primeiro viewer, liga a transmissão (cold start) com a
        # qualidade que o app pediu no handshake.
        pending = _pending_stops.pop(device_id, None)
        if pending is not None:
            pending.cancel()
        elif count == 1:
            await manager.send_to_agent(
                device_id, _start_stream_message(auth)
            )

        # Oferece o último frame guardado, se houver (exibe algo na hora).
        cached = frame_store.get(device_id)
        if cached is not None:
            viewer.offer(cached)

        # Daqui em diante os frames são empurrados pelo sender. O que chega do
        # app é sinalização de WebRTC, repassada ao agente com o `session_id`
        # desta conexão.
        # A revalidação vive numa tarefa própria, e **não** num prazo em volta
        # do `receive()`. A primeira versão fazia isso, e estava errada:
        # `asyncio.wait_for` **cancela** a leitura quando o prazo estoura, e uma
        # leitura de WebSocket cancelada no meio pode levar junto a mensagem que
        # estava chegando. O sintoma foi um teste de sinalização que falhava em
        # duas execuções de cada três — e em produção seria uma oferta de WebRTC
        # perdida de vez em quando, com o vídeo "às vezes não abre".
        #
        # Com a tarefa separada, o `receive()` nunca é interrompido: quem
        # verifica dorme, confere e fecha o socket se o vínculo caiu.
        vigia = asyncio.create_task(_vigiar_vinculo(websocket, credencial, device_id))
        while True:
            packet = await websocket.receive()
            if packet["type"] == "websocket.disconnect":
                break
            text = packet.get("text")
            if text is None:
                continue
            try:
                incoming = json.loads(text)
            except json.JSONDecodeError:
                viewer.signal({"type": "error", "message": "json inválido"})
                continue
            if not is_signaling(incoming):
                continue  # mensagem desconhecida: ignorada, não é erro fatal
            try:
                outgoing = to_agent(incoming, viewer.session_id)
            except SignalingError as exc:
                viewer.signal({"type": "error", "message": str(exc)})
                continue
            if not await manager.send_to_agent(device_id, outgoing):
                viewer.signal(
                    {"type": "error", "message": "computador não está conectado"}
                )
    except WebSocketDisconnect:
        pass
    finally:
        if vigia is not None:
            vigia.cancel()
        if sender_task is not None:
            sender_task.cancel()
        if registered:
            remaining = viewers.remove(device_id, viewer)
            # Avisa o agente que a sessão morreu, para ele soltar a conexão
            # WebRTC correspondente em vez de mantê-la pendurada.
            await manager.send_to_agent(device_id, close_session(viewer.session_id))
            if remaining == 0 and device_id not in _pending_stops:
                # Agenda a parada com carência (mantém o stream aquecido).
                _pending_stops[device_id] = asyncio.create_task(
                    _delayed_stop(device_id)
                )
