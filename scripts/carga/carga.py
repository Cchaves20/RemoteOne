"""Teste de carga do backend: finge ser muitos computadores e celulares.

Cada **computador** abre o `/ws/agent` como o agente de verdade: `hello`,
`heartbeat` a cada 10 s, e responde ao que o servidor repassa (primeiro plano,
lista de programas, métricas, oferta de vídeo). Cada **celular** entra na conta,
abre a tela de um computador (`/ws/viewer`), negocia o vídeo uma vez e pede o
que o app pede durante o uso: primeiro plano a cada 3 s, programas abertos a
cada 10 s e, com `--painel`, as métricas a cada 2 s.

O vídeo em si não passa por aqui: no Deskside ele vai direto do computador ao
celular (WebRTC), e o servidor só ajuda os dois a se acharem. O que este teste
mede é o servidor: conexões abertas, a fila de mensagens e as perguntas que
atravessam ele até o computador e voltam.

A carga sobe em **degraus**: a cada degrau entram mais computadores e
celulares, e o degrau fica de pé por `--segundos`. Ao fim de cada um sai uma
linha com os tempos de resposta (p50, p95, p99) e os erros. Se o p95 passar de
`--teto-ms` ou os erros passarem de `--teto-erros`, a subida **para**: o
degrau anterior é o que o servidor aguenta.

Sem conta (`--contas` ausente), os computadores entram sem parear — é o que
dá para medir num servidor de verdade sem criar contas nele. Com o arquivo de
`preparar_local.py`, cada computador entra pareado e ganha um celular.

Exemplos:

    python carga.py --url http://127.0.0.1:8000 --contas contas.json \\
        --degraus 50,100,200,400 --celulares-por-degrau 25,50,100,200

    python carga.py --url https://deskside.com.br --degraus 25,50,100,200
"""

from __future__ import annotations

import argparse
import asyncio
import json
import os
import random
import statistics
import sys
import time
from dataclasses import dataclass, field

import httpx
import websockets

#: O que o agente de verdade manda no `heartbeat` (ver `agent/src/client.rs`).
BATIDA_SEGUNDOS = 10
#: O que o app de verdade pede durante a tela aberta (`remote_screen.dart`).
PRIMEIRO_PLANO_SEGUNDOS = 3
ABERTOS_SEGUNDOS = 10
PAINEL_SEGUNDOS = 2

#: Quanto o computador leva para responder cada pergunta (ms). No Windows a
#: lista de programas abertos passa por um PowerShell: 1 a 2 s é o normal.
#: Ajustável por `--atraso-programas-ms`.
ATRASO_MS = {"list_apps": 0, "foreground_info": 0, "system_info": 0}

#: Um SDP de mentira, do tamanho de um de verdade: o servidor só o repassa.
SDP_FALSO = "v=0\r\n" + "a=x-carga:" + "0" * 2500 + "\r\n"


# --- medidas -----------------------------------------------------------------


@dataclass
class Medidas:
    """Tempos (ms) e erros por tipo de operação, zerados a cada degrau."""

    tempos: dict[str, list[float]] = field(default_factory=dict)
    erros: dict[str, int] = field(default_factory=dict)
    exemplos: dict[str, str] = field(default_factory=dict)

    def tempo(self, nome: str, ms: float) -> None:
        self.tempos.setdefault(nome, []).append(ms)

    def erro(self, nome: str, motivo: str) -> None:
        self.erros[nome] = self.erros.get(nome, 0) + 1
        self.exemplos.setdefault(nome, motivo[:160])

    def zerar(self) -> Medidas:
        antigo = Medidas(self.tempos, self.erros, self.exemplos)
        self.tempos, self.erros, self.exemplos = {}, {}, {}
        return antigo


def percentil(valores: list[float], p: float) -> float:
    if not valores:
        return 0.0
    ordenados = sorted(valores)
    indice = min(len(ordenados) - 1, max(0, round(p / 100 * (len(ordenados) - 1))))
    return ordenados[indice]


MEDIDAS = Medidas()


async def medir(nome: str, corrotina):
    """Mede uma operação; erro conta como erro e não derruba quem chamou."""
    inicio = time.perf_counter()
    try:
        resultado = await corrotina
    except Exception as e:  # noqa: BLE001 - qualquer falha é dado do teste
        MEDIDAS.erro(nome, f"{type(e).__name__}: {e}")
        return None
    MEDIDAS.tempo(nome, (time.perf_counter() - inicio) * 1000)
    return resultado


# --- o computador ------------------------------------------------------------


def url_ws(base: str, caminho: str) -> str:
    return base.replace("https://", "wss://").replace("http://", "ws://") + caminho


class Computador:
    """Um agente falso. Pareado quando recebe `segredo`."""

    def __init__(self, base: str, device_id: str, segredo: str | None, parar: asyncio.Event):
        self.base = base
        self.device_id = device_id
        self.segredo = segredo
        self.parar = parar
        self.pronto = asyncio.Event()
        self._batidas: list[float] = []

    async def rodar(self) -> None:
        inicio = time.perf_counter()
        try:
            async with websockets.connect(
                url_ws(self.base, "/ws/agent"),
                open_timeout=20,
                ping_interval=None,
                max_size=None,
            ) as ws:
                hello = {
                    "type": "hello",
                    "device_id": self.device_id,
                    "hostname": f"carga-{self.device_id[-6:]}",
                    "os": "Linux",
                    "agent_version": "carga",
                    "secret": self.segredo if self.segredo is not None else "",
                }
                await ws.send(json.dumps(hello))
                welcome = json.loads(await asyncio.wait_for(ws.recv(), 20))
                if welcome.get("type") != "welcome":
                    raise RuntimeError(f"esperava welcome, veio {welcome.get('type')}")
                MEDIDAS.tempo("computador_entra", (time.perf_counter() - inicio) * 1000)
                self.pronto.set()
                batedor = asyncio.create_task(self._bater(ws))
                try:
                    await self._ouvir(ws)
                finally:
                    batedor.cancel()
        except Exception as e:  # noqa: BLE001
            if not self.parar.is_set():
                MEDIDAS.erro("computador_conexao", f"{type(e).__name__}: {e}")
        finally:
            self.pronto.set()

    async def _bater(self, ws) -> None:
        # Espalhado no tempo, como computadores ligados em horas diferentes.
        await asyncio.sleep(random.uniform(0, BATIDA_SEGUNDOS))
        while not self.parar.is_set():
            self._batidas.append(time.perf_counter())
            await ws.send(json.dumps({"type": "heartbeat"}))
            await asyncio.sleep(BATIDA_SEGUNDOS)
        await ws.close()

    async def _ouvir(self, ws) -> None:
        async for bruto in ws:
            if isinstance(bruto, bytes):
                continue
            msg = json.loads(bruto)
            tipo = msg.get("type")
            if ATRASO_MS.get(tipo):
                # Responde depois, sem segurar as outras mensagens: o agente de
                # verdade também atende em paralelo.
                asyncio.create_task(self._responder_depois(ws, msg))
                continue
            await self._responder(ws, msg)

    async def _responder_depois(self, ws, msg: dict) -> None:
        await asyncio.sleep(ATRASO_MS[msg["type"]] / 1000)
        try:
            await self._responder(ws, msg)
        except Exception:  # noqa: BLE001 - conexão fechada no meio
            pass

    async def _responder(self, ws, msg: dict) -> None:
        tipo = msg.get("type")
        if tipo == "ack":
            if self._batidas:
                enviada = self._batidas.pop(0)
                MEDIDAS.tempo("batida", (time.perf_counter() - enviada) * 1000)
        elif tipo == "foreground_info":
            await ws.send(json.dumps({
                "type": "foreground_app",
                "request_id": msg["request_id"],
                "app": {"name": "Editor", "exe": "editor.exe"},
            }))
        elif tipo == "list_apps":
            await ws.send(json.dumps({
                "type": "app_list",
                "request_id": msg["request_id"],
                "apps": [{"id": str(1000 + i), "name": f"Programa {i}"} for i in range(8)],
            }))
        elif tipo == "system_info":
            await ws.send(json.dumps({
                "type": "system_stats",
                "request_id": msg["request_id"],
                "stats": {
                    "cpu_percent": 12.5, "memory_used": 4 << 30,
                    "memory_total": 16 << 30, "disk_used": 100 << 30,
                    "disk_total": 500 << 30, "disk_name": "C:",
                    "uptime_seconds": 3600,
                },
            }))
        elif tipo == "webrtc_offer":
            await ws.send(json.dumps({
                "type": "webrtc_answer",
                "session_id": msg["session_id"],
                "sdp": SDP_FALSO,
            }))
        elif tipo == "error":
            MEDIDAS.erro("computador_recusado", msg.get("message", ""))


# --- o celular -----------------------------------------------------------------


class Celular:
    """Um app falso, com a tela de um computador aberta."""

    def __init__(self, base: str, cliente: httpx.AsyncClient, conta: dict,
                 painel: bool, parar: asyncio.Event):
        self.base = base
        self.cliente = cliente
        self.conta = conta
        self.painel = painel
        self.parar = parar
        self.pronto = asyncio.Event()

    async def _entrar(self) -> str:
        r = await self.cliente.post(
            "/api/v1/auth/login",
            json={"email": self.conta["email"], "password": self.conta["senha"]},
        )
        r.raise_for_status()
        return r.json()["access_token"]

    async def rodar(self) -> None:
        token = await medir("celular_login", self._entrar())
        if token is None:
            self.pronto.set()
            return
        cabecalho = {"Authorization": f"Bearer {token}"}
        device = self.conta["device_id"]
        try:
            async with websockets.connect(
                url_ws(self.base, f"/ws/viewer/{device}"),
                open_timeout=20, ping_interval=None, max_size=None,
            ) as ws:
                await ws.send(json.dumps({"token": token}))
                inicio = time.perf_counter()
                await ws.send(json.dumps({"type": "webrtc_offer", "sdp": SDP_FALSO}))
                while True:
                    bruto = await asyncio.wait_for(ws.recv(), 20)
                    if isinstance(bruto, bytes):
                        continue
                    if json.loads(bruto).get("type") == "webrtc_answer":
                        break
                MEDIDAS.tempo("video_negocia", (time.perf_counter() - inicio) * 1000)
                self.pronto.set()
                tarefas = [
                    self._repetir("primeiro_plano", PRIMEIRO_PLANO_SEGUNDOS,
                                  f"/api/v1/devices/{device}/foreground", cabecalho),
                    self._repetir("programas_abertos", ABERTOS_SEGUNDOS,
                                  f"/api/v1/devices/{device}/apps?kind=running", cabecalho),
                ]
                if self.painel:
                    tarefas.append(self._repetir("metricas", PAINEL_SEGUNDOS,
                                                 f"/api/v1/devices/{device}/system", cabecalho))
                drenar = asyncio.create_task(self._drenar(ws))
                try:
                    await asyncio.gather(*tarefas)
                finally:
                    drenar.cancel()
        except Exception as e:  # noqa: BLE001
            if not self.parar.is_set():
                MEDIDAS.erro("celular_tela", f"{type(e).__name__}: {e}")
        finally:
            self.pronto.set()

    async def _drenar(self, ws) -> None:
        async for _ in ws:
            pass

    async def _repetir(self, nome: str, intervalo: float, caminho: str, cabecalho: dict) -> None:
        await asyncio.sleep(random.uniform(0, intervalo))
        while not self.parar.is_set():
            async def pedir():
                r = await self.cliente.get(caminho, headers=cabecalho)
                if r.status_code != 200:
                    raise RuntimeError(f"HTTP {r.status_code}: {r.text[:80]}")
            await medir(nome, pedir())
            await asyncio.sleep(intervalo)


# --- o servidor (só quando roda na mesma máquina) ------------------------------


def uso_do_processo(pid: int, antes: tuple[float, float] | None):
    """CPU (% de um núcleo desde a última leitura) e memória (MB) do servidor."""
    try:
        with open(f"/proc/{pid}/stat") as f:
            campos = f.read().rsplit(")", 1)[1].split()
        ticks = int(campos[11]) + int(campos[12])
        with open(f"/proc/{pid}/status") as f:
            rss = next(int(linha.split()[1]) for linha in f if linha.startswith("VmRSS"))
    except (OSError, StopIteration, ValueError):
        return None, None, antes
    agora = (time.monotonic(), ticks / os.sysconf("SC_CLK_TCK"))
    cpu = None
    if antes is not None:
        cpu = 100 * (agora[1] - antes[1]) / max(1e-6, agora[0] - antes[0])
    return cpu, rss / 1024, agora


# --- os degraus ------------------------------------------------------------------


def resumo(m: Medidas) -> dict:
    linhas = {}
    for nome in sorted(set(m.tempos) | set(m.erros)):
        t = m.tempos.get(nome, [])
        linhas[nome] = {
            "n": len(t),
            "p50": round(percentil(t, 50), 1),
            "p95": round(percentil(t, 95), 1),
            "p99": round(percentil(t, 99), 1),
            "max": round(max(t), 1) if t else 0.0,
            "erros": m.erros.get(nome, 0),
            "exemplo_de_erro": m.exemplos.get(nome),
        }
    return linhas


async def saude(cliente: httpx.AsyncClient) -> None:
    """O `/health` medido a cada segundo: o tempo de um pedido simples com o
    servidor carregado é o que uma pessoa de verdade sentiria abrindo o app."""
    async def pedir():
        r = await cliente.get("/health")
        r.raise_for_status()
    await medir("saude", pedir())


async def principal(args) -> int:
    contas = []
    if args.contas:
        with open(args.contas) as f:
            contas = json.load(f)
    degraus = [int(x) for x in args.degraus.split(",")]
    celulares_degraus = (
        [int(x) for x in args.celulares_por_degrau.split(",")]
        if args.celulares_por_degrau else [0] * len(degraus)
    )
    ATRASO_MS["list_apps"] = args.atraso_programas_ms
    if contas and max(degraus) > len(contas):
        print(f"só há {len(contas)} contas para {max(degraus)} computadores", file=sys.stderr)
        return 2

    parar = asyncio.Event()
    limites = httpx.Limits(max_connections=2000, max_keepalive_connections=2000)
    resultados = []
    computadores: list[asyncio.Task] = []
    celulares: list[asyncio.Task] = []
    quebrou_em = None
    prefixo = args.prefixo or f"carga-{os.getpid()}"

    async with httpx.AsyncClient(base_url=args.url, timeout=30, limits=limites) as cliente:
        uso_antes = None
        pares = zip(degraus, celulares_degraus, strict=True)
        for numero, (alvo, alvo_celulares) in enumerate(pares, 1):
            # Entram em lotes, como gente chegando, e não num estouro só.
            novos = []
            for i in range(len(computadores), alvo):
                if contas:
                    c = contas[i]
                    comp = Computador(args.url, c["device_id"], c["segredo"], parar)
                else:
                    comp = Computador(args.url, f"{prefixo}-{i:05d}", None, parar)
                computadores.append(asyncio.create_task(comp.rodar()))
                novos.append(comp)
                if len(novos) % 25 == 0:
                    await asyncio.sleep(0.5)
            await asyncio.gather(*(c.pronto.wait() for c in novos))
            # Os celulares entram no ritmo de `--entrada-por-segundo`: o login
            # custa um bcrypt de propósito, e uma multidão entrando no mesmo
            # segundo é outro teste (ver o resumo "entrada").
            novos_celulares = []
            for i in range(len(celulares), min(alvo_celulares, alvo)):
                cel = Celular(args.url, cliente, contas[i], args.painel, parar)
                celulares.append(asyncio.create_task(cel.rodar()))
                novos_celulares.append(cel)
                await asyncio.sleep(1 / args.entrada_por_segundo)
            await asyncio.gather(*(c.pronto.wait() for c in novos_celulares))

            # A entrada fica fora da medida do uso contínuo, num resumo à parte.
            entrada = resumo(MEDIDAS.zerar())
            fim = time.monotonic() + args.segundos
            cpus, memorias = [], []
            while time.monotonic() < fim:
                await saude(cliente)
                if args.pid:
                    cpu, mem, uso_antes = uso_do_processo(args.pid, uso_antes)
                    if cpu is not None:
                        cpus.append(cpu)
                    if mem is not None:
                        memorias.append(mem)
                await asyncio.sleep(1)

            m = MEDIDAS.zerar()
            linha = {
                "degrau": numero,
                "computadores": alvo,
                "celulares": min(alvo_celulares, alvo),
                "entrada": entrada,
                "medidas": resumo(m),
            }
            if cpus:
                linha["servidor"] = {
                    "cpu_media": round(statistics.mean(cpus), 1),
                    "cpu_max": round(max(cpus), 1),
                    "memoria_mb": round(max(memorias), 1),
                }
            resultados.append(linha)
            imprimir(linha)

            total = sum(v["n"] + v["erros"] for v in linha["medidas"].values())
            erros = sum(v["erros"] for v in linha["medidas"].values())
            # O atraso que o próprio computador simulado leva não é do servidor.
            descontar = {"programas_abertos": args.atraso_programas_ms}
            pior_p95 = max(
                (v["p95"] - descontar.get(nome, 0) for nome, v in linha["medidas"].items()),
                default=0,
            )
            if erros > args.teto_erros * max(1, total) or pior_p95 > args.teto_ms:
                quebrou_em = numero
                print(f"\nparou no degrau {numero}: p95 {pior_p95} ms, {erros}/{total} erros")
                break

        parar.set()
        for t in computadores + celulares:
            t.cancel()
        await asyncio.gather(*computadores, *celulares, return_exceptions=True)

    if args.saida:
        with open(args.saida, "w") as f:
            json.dump({"url": args.url, "degraus": resultados, "parou_no_degrau": quebrou_em},
                      f, indent=2, ensure_ascii=False)
    return 0


def imprimir(linha: dict) -> None:
    servidor = linha.get("servidor")
    extra = (f"  servidor: CPU {servidor['cpu_media']}% (máx {servidor['cpu_max']}%),"
             f" {servidor['memoria_mb']} MB") if servidor else ""
    print(f"\n== degrau {linha['degrau']}: {linha['computadores']} computadores,"
          f" {linha['celulares']} celulares{extra}")
    print(f"   {'operação':<20}{'n':>7}{'p50':>9}{'p95':>9}{'p99':>9}{'máx':>9}{'erros':>7}")
    for nome, v in linha.get("entrada", {}).items():
        if nome in ("celular_login", "video_negocia", "computador_entra"):
            print(f"   entrada: {nome:<20}{v['n']:>7}{v['p50']:>9}{v['p95']:>9}"
                  f"{v['p99']:>9}{v['max']:>9}{v['erros']:>7}")
    for nome, v in linha["medidas"].items():
        print(f"   {nome:<20}{v['n']:>7}{v['p50']:>9}{v['p95']:>9}{v['p99']:>9}"
              f"{v['max']:>9}{v['erros']:>7}")
        if v["exemplo_de_erro"]:
            print(f"      ex.: {v['exemplo_de_erro']}")


if __name__ == "__main__":
    p = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    p.add_argument("--url", required=True, help="endereço do backend (http/https)")
    p.add_argument("--contas", help="arquivo do preparar_local.py (computadores pareados)")
    p.add_argument("--degraus", default="25,50,100,200", help="computadores em cada degrau")
    p.add_argument("--celulares-por-degrau", help="celulares em cada degrau (exige --contas)")
    p.add_argument("--painel", action="store_true", help="celulares com as métricas abertas")
    p.add_argument("--atraso-programas-ms", type=int, default=0,
                   help="quanto o computador leva para listar os programas abertos")
    p.add_argument("--entrada-por-segundo", type=float, default=4,
                   help="celulares que entram por segundo")
    p.add_argument("--segundos", type=int, default=60, help="duração de cada degrau")
    p.add_argument("--teto-ms", type=float, default=1000, help="p95 que para a subida")
    p.add_argument("--teto-erros", type=float, default=0.01, help="fração de erros que para")
    p.add_argument("--pid", type=int, help="PID do servidor, quando roda na mesma máquina")
    p.add_argument("--prefixo", help="início do device_id dos computadores sem conta")
    p.add_argument("--saida", help="grava o resultado em JSON")
    sys.exit(asyncio.run(principal(p.parse_args())))
