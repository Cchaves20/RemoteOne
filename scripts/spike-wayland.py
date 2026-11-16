#!/usr/bin/env python3
"""Teste rápido: dá para controlar um Linux com Wayland sem pedir permissão toda vez?

O Wayland não deixa um programa capturar a tela nem mexer no mouse por conta
própria. O caminho oficial são os "portais" do sistema (xdg-desktop-portal):
o programa pede, e o sistema mostra uma janela de "compartilhar tela e
controle" para a pessoa aprovar. A pergunta que decide se vale fazer o agente
Linux é **quantas vezes** essa janela aparece. Se for a cada conexão, um
computador sem ninguém na frente não pode ser controlado.

Este script faz o que o agente faria:

1. abre uma sessão de controle remoto (tela + mouse e teclado), pedindo para
   o sistema **lembrar** a permissão (`persist_mode`);
2. guarda a "ficha" que o sistema devolve (`restore_token`) e a reapresenta
   na próxima vez — é ela que deveria dispensar a janela;
3. tira uma foto da tela pelo PipeWire (o canal de vídeo do Wayland);
4. move o mouse num quadradinho no meio da tela.

## Como rodar (numa sessão Wayland do Ubuntu)

    sudo apt install gstreamer1.0-tools gstreamer1.0-pipewire
    python3 scripts/spike-wayland.py

Rode três vezes: agora, de novo logo em seguida, e depois de sair e entrar na
sessão (ou reiniciar). Em cada uma, anote se a janela de permissão apareceu.

Nada é instalado e nada fica rodando: o script termina sozinho. A ficha fica em
~/.config/deskside-spike/ficha; apague a pasta para recomeçar do zero.
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
PASTA = Path.home() / ".config" / "deskside-spike"
FICHA = PASTA / "ficha"
FOTO = Path.home() / "deskside-spike.png"

# Tipos do portal.
TECLADO, PONTEIRO = 1, 2
MONITOR = 1
LEMBRAR_ATE_REVOGAR = 2


def linha(texto=""):
    print(texto, flush=True)


class Portal:
    """As chamadas ao portal, com a espera pela resposta de cada uma.

    Todo pedido ao portal volta em duas partes: a chamada responde na hora com
    o caminho de um "pedido", e o resultado de verdade chega depois, num sinal
    `Response` nesse caminho — às vezes só depois de a pessoa clicar na janela.
    """

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
        """Chama e espera o `Response`. Devolve (código, resultados, segundos)."""
        token = "deskside_" + uuid.uuid4().hex[:8]
        opcoes = dict(opcoes, handle_token=GLib.Variant("s", token))
        caminho = f"{self.prefixo}/{token}"
        resposta = {}

        def chegou(_con, _rem, _cam, _iface, _sinal, params):
            codigo, resultados = params.unpack()
            resposta["codigo"] = codigo
            resposta["resultados"] = resultados
            self.laco.quit()

        # Sem filtrar o remetente: o sinal chega com o nome único do portal, e
        # o caminho do pedido já é exclusivo deste pedido.
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
        # Dois minutos: é o tempo de a pessoa ler a janela e decidir.
        limite = GLib.timeout_add_seconds(120, self.laco.quit)
        self.laco.run()
        GLib.source_remove(limite)
        self.bus.signal_unsubscribe(inscricao)
        segundos = time.monotonic() - inicio
        if "codigo" not in resposta:
            return None, {}, segundos
        return resposta["codigo"], resposta["resultados"], segundos

    def chamar(self, interface, metodo, assinatura, argumentos):
        self.bus.call_sync(
            PORTAL, CAMINHO, interface, metodo,
            GLib.Variant(assinatura, argumentos),
            None, Gio.DBusCallFlags.NONE, -1, None,
        )

    def abrir_pipewire(self, sessao):
        resultado, fds = self.bus.call_with_unix_fd_list_sync(
            PORTAL, CAMINHO, TELA, "OpenPipeWireRemote",
            GLib.Variant("(oa{sv})", (sessao, {})),
            GLib.VariantType("(h)"), Gio.DBusCallFlags.NONE, -1, None, None,
        )
        return fds.get(resultado.unpack()[0])


def ambiente():
    linha("== Ambiente")
    linha(f"sessão: {os.environ.get('XDG_SESSION_TYPE', '?')}")
    linha(f"área de trabalho: {os.environ.get('XDG_CURRENT_DESKTOP', '?')}")
    for comando in (["gnome-shell", "--version"], ["plasmashell", "--version"]):
        try:
            saida = subprocess.run(comando, capture_output=True, text=True, timeout=5)
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


def tirar_foto(fd, no):
    """Uma foto da tela pelo PipeWire, com o GStreamer."""
    if subprocess.run(["which", "gst-launch-1.0"], capture_output=True).returncode != 0:
        linha("foto: PULADA — falta o gst-launch-1.0 "
              "(sudo apt install gstreamer1.0-tools gstreamer1.0-pipewire)")
        return
    FOTO.unlink(missing_ok=True)
    os.set_inheritable(fd, True)
    inicio = time.monotonic()
    try:
        subprocess.run(
            [
                "gst-launch-1.0", "-q", "pipewiresrc", f"fd={fd}", f"path={no}",
                "num-buffers=3", "!", "videoconvert", "!", "pngenc", "snapshot=true",
                "!", "filesink", f"location={FOTO}",
            ],
            pass_fds=(fd,), capture_output=True, timeout=15,
        )
    except subprocess.TimeoutExpired:
        pass
    if FOTO.exists() and FOTO.stat().st_size > 0:
        linha(f"foto: OK em {time.monotonic() - inicio:.1f}s → {FOTO} "
              f"({FOTO.stat().st_size // 1024} KB) — abra para conferir")
    else:
        linha("foto: FALHOU — nenhum quadro chegou pelo PipeWire em 15s")


def mexer_mouse(portal, sessao, no, largura, altura):
    """Um quadradinho de 200 px no meio da tela, em 2 segundos."""
    cx, cy = largura / 2, altura / 2
    pontos = []
    for i in range(20):
        pontos.append((cx - 100 + i * 10, cy - 100))
    for i in range(20):
        pontos.append((cx + 100, cy - 100 + i * 10))
    for i in range(20):
        pontos.append((cx + 100 - i * 10, cy + 100))
    for i in range(20):
        pontos.append((cx - 100, cy + 100 - i * 10))
    try:
        for x, y in pontos:
            portal.chamar(
                REMOTO, "NotifyPointerMotionAbsolute", "(oa{sv}udd)",
                (sessao, {}, no, float(x), float(y)),
            )
            time.sleep(0.025)
        linha("mouse: comandos aceitos — o cursor desenhou um quadrado no meio da tela?")
    except GLib.Error as e:
        linha(f"mouse: FALHOU — {e.message}")


def main():
    ambiente()
    if os.environ.get("XDG_SESSION_TYPE") != "wayland":
        linha("\nAVISO: esta sessão não é Wayland; o teste perde o sentido.")
        linha("Na tela de login, escolha a sessão 'Ubuntu' (e não 'Ubuntu em Xorg').")

    portal = Portal()
    v_remoto, v_tela = portal.versao(REMOTO), portal.versao(TELA)
    linha(f"portal RemoteDesktop v{v_remoto}, ScreenCast v{v_tela}")
    if v_remoto is None:
        sys.exit("\nNão há portal de controle remoto nesta máquina. "
                 "Instale o xdg-desktop-portal-gnome (ou -kde).")
    if v_remoto < 2:
        linha("AVISO: RemoteDesktop < v2 não sabe lembrar a permissão; "
              "a janela vai aparecer sempre.")

    ficha_antiga = FICHA.read_text().strip() if FICHA.exists() else ""
    qual = "com a ficha guardada" if ficha_antiga else "SEM ficha (primeira vez)"
    linha(f"\n== Tentativa {qual}")

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
        {
            "types": GLib.Variant("u", MONITOR),
            "multiple": GLib.Variant("b", False),
        },
    )
    if codigo != 0:
        sys.exit(f"SelectSources recusado (código {codigo}).")

    linha("Pedindo para começar. Se aparecer uma janela de permissão, aprove "
          "(e marque 'lembrar', se houver).")
    codigo, res, segundos = portal.pedir(REMOTO, "Start", "(osa{sv})", (sessao, ""), {})
    # Mais de 1,5 s quase sempre é alguém clicando numa janela.
    janela = "SIM (provável)" if segundos > 1.5 else "NÃO"
    linha(f"Start respondeu em {segundos:.1f}s — janela de permissão: {janela}")
    if codigo != 0:
        sys.exit(f"Permissão negada ou cancelada (código {codigo}).")

    nova_ficha = res.get("restore_token", "")
    if nova_ficha:
        PASTA.mkdir(parents=True, exist_ok=True)
        FICHA.write_text(nova_ficha)
        linha("ficha para a próxima vez: RECEBIDA e guardada")
    else:
        linha("ficha para a próxima vez: NÃO veio (o sistema não vai lembrar)")
    linha(f"dispositivos liberados: {res.get('devices', 0)} "
          f"(1=teclado, 2=mouse, 3=os dois)")

    streams = res.get("streams", [])
    if not streams:
        sys.exit("Nenhuma tela veio na sessão.")
    no, propriedades = streams[0]
    largura, altura = propriedades.get("size", (1920, 1080))
    linha(f"tela: nó {no} do PipeWire, {largura}x{altura}")

    fd = portal.abrir_pipewire(sessao)
    tirar_foto(fd, no)
    mexer_mouse(portal, sessao, no, largura, altura)

    linha("\n== Resumo (me mande daqui para cima)")
    linha(json.dumps({
        "tentativa": "com ficha" if ficha_antiga else "primeira",
        "janela_apareceu": janela,
        "segundos_ate_liberar": round(segundos, 1),
        "ficha_nova": bool(nova_ficha),
        "foto": FOTO.exists() and FOTO.stat().st_size > 0,
        "portal": {"RemoteDesktop": v_remoto, "ScreenCast": v_tela},
    }, ensure_ascii=False))


if __name__ == "__main__":
    main()
