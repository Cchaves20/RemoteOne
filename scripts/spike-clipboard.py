#!/usr/bin/env python3
"""Teste rápido: o Wayland deixa o agente ler e escrever a área de transferência?

No X11 qualquer programa lê e escreve a área de transferência. No Wayland
não: só a janela em foco — e o agente não tem janela. O caminho que sobra é o
mesmo portal da tela e do controle (RemoteDesktop), que desde 2023 tem um
pedaço para a área de transferência (`org.freedesktop.portal.Clipboard`). Ele
só vale dentro de uma sessão de controle remoto, que é exatamente quando o
celular quer copiar e colar.

Três perguntas, nesta ordem:

1. Este Ubuntu oferece o portal de área de transferência?
2. Pedir a área de transferência faz a janela de permissão voltar a aparecer
   (a ficha guardada continua valendo)?
3. Funciona nos dois sentidos: o que se copia no computador chega ao
   programa, e o que o programa põe ali sai no Ctrl+V do computador?

## Como rodar (numa sessão Wayland do Ubuntu)

    python3 spike-clipboard.py

Rode duas vezes: a primeira (que deve mostrar a janela de permissão) e logo em
seguida a segunda (que não deveria). O script diz quando copiar e quando colar.

Nada é instalado e nada fica rodando. A ficha fica em
~/.config/deskside-spike/ficha-clipboard; apague-a para recomeçar do zero.
"""

import json
import os
import subprocess
import sys
import time
import uuid
from pathlib import Path

try:
    import gi

    gi.require_version("Gio", "2.0")
    from gi.repository import Gio, GLib
except (ImportError, ValueError):
    sys.exit("Falta o python3-gi: sudo apt install python3-gi")

PORTAL = "org.freedesktop.portal.Desktop"
CAMINHO = "/org/freedesktop/portal/desktop"
REMOTO = "org.freedesktop.portal.RemoteDesktop"
TELA = "org.freedesktop.portal.ScreenCast"
AREA = "org.freedesktop.portal.Clipboard"
FICHA = Path.home() / ".config" / "deskside-spike" / "ficha-clipboard"

TECLADO, PONTEIRO = 1, 2
MONITOR = 1
LEMBRAR_ATE_REVOGAR = 2

TEXTO = ["text/plain;charset=utf-8", "text/plain", "UTF8_STRING", "STRING", "TEXT"]
ENVIADO = "Deskside: ção é à 123"


def linha(texto=""):
    print(texto, flush=True)


class Portal:
    """As chamadas ao portal. Ver `spike-wayland.py` para o porquê da espera."""

    def __init__(self):
        self.bus = Gio.bus_get_sync(Gio.BusType.SESSION, None)
        remetente = self.bus.get_unique_name()[1:].replace(".", "_")
        self.prefixo = f"{CAMINHO}/request/{remetente}"
        self.laco = GLib.MainLoop()

    def versao(self, interface):
        try:
            r = self.bus.call_sync(
                PORTAL, CAMINHO, "org.freedesktop.DBus.Properties", "Get",
                GLib.Variant("(ss)", (interface, "version")),
                GLib.VariantType("(v)"), Gio.DBusCallFlags.NONE, -1, None,
            )
            return r.unpack()[0]
        except GLib.Error:
            return None

    def pedir(self, interface, metodo, assinatura, argumentos, opcoes):
        token = "deskside_" + uuid.uuid4().hex[:8]
        opcoes = dict(opcoes, handle_token=GLib.Variant("s", token))
        caminho = f"{self.prefixo}/{token}"
        resposta = {}

        def chegou(_con, _rem, _cam, _iface, _sinal, params):
            codigo, resultados = params.unpack()
            resposta["codigo"] = codigo
            resposta["resultados"] = resultados
            self.laco.quit()

        inscricao = self.bus.signal_subscribe(
            None, "org.freedesktop.portal.Request", "Response", caminho,
            None, Gio.DBusSignalFlags.NONE, chegou,
        )
        inicio = time.monotonic()
        self.bus.call_sync(
            PORTAL, CAMINHO, interface, metodo,
            GLib.Variant(assinatura, (*argumentos, opcoes)),
            GLib.VariantType("(o)"), Gio.DBusCallFlags.NONE, -1, None,
        )
        limite = GLib.timeout_add_seconds(120, self.laco.quit)
        self.laco.run()
        GLib.source_remove(limite)
        self.bus.signal_unsubscribe(inscricao)
        segundos = time.monotonic() - inicio
        if "codigo" not in resposta:
            return None, {}, segundos
        return resposta["codigo"], resposta["resultados"], segundos

    def chamar(self, metodo, assinatura, argumentos):
        self.bus.call_sync(
            PORTAL, CAMINHO, AREA, metodo, GLib.Variant(assinatura, argumentos),
            None, Gio.DBusCallFlags.NONE, -1, None,
        )

    def chamar_com_fd(self, metodo, assinatura, argumentos):
        """Para os métodos que devolvem um descritor de arquivo."""
        resultado, fds = self.bus.call_with_unix_fd_list_sync(
            PORTAL, CAMINHO, AREA, metodo, GLib.Variant(assinatura, argumentos),
            GLib.VariantType("(h)"), Gio.DBusCallFlags.NONE, 10_000, None, None,
        )
        return fds.get(resultado.unpack()[0])

    def esperar(self, segundos):
        limite = GLib.timeout_add_seconds(segundos, self.laco.quit)
        self.laco.run()
        GLib.source_remove(limite)


def ambiente():
    linha("== Ambiente")
    linha(f"sessão: {os.environ.get('XDG_SESSION_TYPE', '?')}")
    linha(f"área de trabalho: {os.environ.get('XDG_CURRENT_DESKTOP', '?')}")
    try:
        saida = subprocess.run(["gnome-shell", "--version"], capture_output=True,
                               text=True, timeout=5)
        if saida.stdout.strip():
            linha(saida.stdout.strip())
    except (OSError, subprocess.TimeoutExpired):
        pass
    try:
        with open("/etc/os-release") as f:
            for texto in f:
                if texto.startswith("PRETTY_NAME="):
                    linha(texto.split("=", 1)[1].strip().strip('"'))
    except OSError:
        pass


def ler_tudo(fd):
    partes = []
    total = 0
    while total < 1_000_000:
        bloco = os.read(fd, 65536)
        if not bloco:
            break
        partes.append(bloco)
        total += len(bloco)
    os.close(fd)
    return b"".join(partes)


def main():
    ambiente()
    if os.environ.get("XDG_SESSION_TYPE") != "wayland":
        linha("\nAVISO: esta sessão não é Wayland; o teste perde o sentido.")

    portal = Portal()
    v_remoto, v_area = portal.versao(REMOTO), portal.versao(AREA)
    linha(f"portal RemoteDesktop v{v_remoto}, Clipboard v{v_area}")
    resumo = {"portal": {"RemoteDesktop": v_remoto, "Clipboard": v_area}}
    if v_area is None:
        linha("\nEste Ubuntu NÃO oferece o portal de área de transferência.")
        linha("\n== Resumo (me mande daqui para cima)")
        linha(json.dumps(resumo, ensure_ascii=False))
        return

    ficha_antiga = FICHA.read_text().strip() if FICHA.exists() else ""
    linha(f"\n== Tentativa {'com a ficha guardada' if ficha_antiga else 'SEM ficha (primeira vez)'}")

    codigo, res, _ = portal.pedir(
        REMOTO, "CreateSession", "(a{sv})", (),
        {"session_handle_token": GLib.Variant("s", "deskside_sessao")},
    )
    if codigo != 0:
        sys.exit(f"Não abriu a sessão (código {codigo}).")
    sessao = res["session_handle"]

    opcoes = {
        "types": GLib.Variant("u", TECLADO | PONTEIRO),
        "persist_mode": GLib.Variant("u", LEMBRAR_ATE_REVOGAR),
    }
    if ficha_antiga:
        opcoes["restore_token"] = GLib.Variant("s", ficha_antiga)
    codigo, _, _ = portal.pedir(REMOTO, "SelectDevices", "(oa{sv})", (sessao,), opcoes)
    if codigo != 0:
        sys.exit(f"SelectDevices recusado (código {codigo}).")
    codigo, _, _ = portal.pedir(
        TELA, "SelectSources", "(oa{sv})", (sessao,),
        {"types": GLib.Variant("u", MONITOR), "multiple": GLib.Variant("b", False)},
    )
    if codigo != 0:
        sys.exit(f"SelectSources recusado (código {codigo}).")

    # Antes do Start: é a regra do portal.
    try:
        portal.chamar("RequestClipboard", "(oa{sv})", (sessao, {}))
        pedido = "aceito"
    except GLib.Error as e:
        pedido = f"RECUSADO — {e.message}"
    linha(f"pedido da área de transferência: {pedido}")

    linha("Pedindo para começar. Se aparecer uma janela de permissão, aprove "
          "(e marque 'lembrar', se houver).")
    codigo, res, segundos = portal.pedir(REMOTO, "Start", "(osa{sv})", (sessao, ""), {})
    janela = "SIM (provável)" if segundos > 1.5 else "NÃO"
    linha(f"Start respondeu em {segundos:.1f}s — janela de permissão: {janela}")
    if codigo != 0:
        sys.exit(f"Permissão negada ou cancelada (código {codigo}).")
    nova_ficha = res.get("restore_token", "")
    if nova_ficha:
        FICHA.parent.mkdir(parents=True, exist_ok=True)
        FICHA.write_text(nova_ficha)
    liberada = bool(res.get("clipboard_enabled", False))
    linha(f"área de transferência liberada na sessão: {'SIM' if liberada else 'NÃO'}")
    resumo.update({
        "tentativa": "com ficha" if ficha_antiga else "primeira",
        "janela_apareceu": janela,
        "ficha_nova": bool(nova_ficha),
        "liberada": liberada,
    })

    # --- 1. do computador para o programa --------------------------------
    lido = {}

    def dono_mudou(_con, _rem, _cam, _iface, _sinal, params):
        sessao_sinal, opcoes_sinal = params.unpack()
        if sessao_sinal != sessao or opcoes_sinal.get("session_is_owner"):
            return
        tipos = opcoes_sinal.get("mime_types", [])
        tipo = next((t for t in TEXTO if t in tipos), None)
        if tipo is None:
            lido["tipos"] = tipos
            return
        try:
            fd = portal.chamar_com_fd("SelectionRead", "(os)", (sessao, tipo))
            texto = ler_tudo(fd).decode("utf-8", "replace")
            lido["texto"] = texto
            portal.laco.quit()
        except GLib.Error as e:
            lido["erro"] = e.message
            portal.laco.quit()

    inscricao = portal.bus.signal_subscribe(
        None, AREA, "SelectionOwnerChanged", CAMINHO, None,
        Gio.DBusSignalFlags.NONE, dono_mudou,
    )
    linha("\n>>> AGORA: no computador, selecione um texto qualquer (num editor ou "
          "no navegador) e aperte Ctrl+C. Espero 30 s.")
    portal.esperar(30)
    portal.bus.signal_unsubscribe(inscricao)
    if "texto" in lido:
        linha(f"copiado no computador chegou ao programa: SIM → {lido['texto'][:80]!r}")
        resumo["computador_para_programa"] = "sim"
    elif "erro" in lido:
        linha(f"copiado no computador: aviso chegou, leitura FALHOU — {lido['erro']}")
        resumo["computador_para_programa"] = f"falhou: {lido['erro']}"
    elif "tipos" in lido:
        linha(f"copiado no computador: chegou, mas sem texto (tipos {lido['tipos']})")
        resumo["computador_para_programa"] = "sem texto"
    else:
        linha("copiado no computador: NADA chegou em 30 s")
        resumo["computador_para_programa"] = "nada"

    # --- 2. do programa para o computador --------------------------------
    entregas = []

    def pediram(_con, _rem, _cam, _iface, _sinal, params):
        sessao_sinal, tipo, serie = params.unpack()
        if sessao_sinal != sessao:
            return
        try:
            fd = portal.chamar_com_fd("SelectionWrite", "(ou)", (sessao, serie))
            os.write(fd, ENVIADO.encode("utf-8"))
            os.close(fd)
            portal.chamar("SelectionWriteDone", "(oub)", (sessao, serie, True))
            entregas.append(tipo)
        except GLib.Error as e:
            entregas.append(f"erro: {e.message}")

    inscricao = portal.bus.signal_subscribe(
        None, AREA, "SelectionTransfer", CAMINHO, None,
        Gio.DBusSignalFlags.NONE, pediram,
    )
    try:
        portal.chamar("SetSelection", "(oa{sv})",
                      (sessao, {"mime_types": GLib.Variant("as", TEXTO)}))
        linha(f"\n>>> AGORA: num editor de texto do computador, aperte Ctrl+V. "
              f"Deveria aparecer: {ENVIADO}")
        linha("Espero 30 s.")
        portal.esperar(30)
    except GLib.Error as e:
        linha(f"pôr texto na área de transferência: FALHOU — {e.message}")
    portal.bus.signal_unsubscribe(inscricao)
    linha(f"o computador pediu o texto {len(entregas)} vez(es): {entregas}")
    resumo["programa_para_computador"] = entregas

    linha("\n== Resumo (me mande daqui para cima, e diga se o Ctrl+V colou o texto)")
    linha(json.dumps(resumo, ensure_ascii=False))


if __name__ == "__main__":
    main()
