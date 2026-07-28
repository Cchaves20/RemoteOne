"""Ações de entrada (mouse) — corpo do endpoint de input e relay ao agente.

O formato de fio espelha `agent/src/input.rs`. O backend valida a ação e a
retransmite ao agente dentro do envelope `{"type": "input", "action": {...}}`.
"""

from typing import Annotated, Literal

from pydantic import BaseModel, Field


class MouseMove(BaseModel):
    kind: Literal["mouse_move"] = "mouse_move"
    dx: int
    dy: int


class MouseMoveTo(BaseModel):
    """Posição absoluta em fração da tela (0.0–1.0) — modo toque direto."""

    kind: Literal["mouse_move_to"] = "mouse_move_to"
    x: float = Field(ge=0.0, le=1.0)
    y: float = Field(ge=0.0, le=1.0)


class MouseClick(BaseModel):
    kind: Literal["mouse_click"] = "mouse_click"
    button: Literal["left", "right", "middle"] = "left"


class MouseScroll(BaseModel):
    kind: Literal["mouse_scroll"] = "mouse_scroll"
    dy: int


# Teclas especiais e modificadores aceitos (espelham agent/src/input.rs).
SpecialKey = Literal[
    "enter", "backspace", "tab", "escape", "space", "delete",
    "up", "down", "left", "right", "home", "end", "page_up", "page_down",
    "f1", "f2", "f3", "f4", "f5", "f6", "f7", "f8", "f9", "f10", "f11", "f12",
]
Modifier = Literal["ctrl", "alt", "shift", "meta"]


class MousePress(BaseModel):
    """Aperta um botão e segura, depois de `clicks - 1` cliques completos.

    É o que permite selecionar texto: `clicks=2` faz o agente dar um clique e
    apertar de novo sem soltar - como o Windows entende "duplo clique e
    arrasta", que estende a seleção palavra por palavra.

    Os cliques são dados pelo agente, em sequência local: em mensagens
    separadas, a latência da rede poderia espaçá-los além do intervalo de duplo
    clique do Windows, e a seleção viraria dois cliques soltos.
    """

    kind: Literal["mouse_press"] = "mouse_press"
    button: Literal["left", "right", "middle"] = "left"
    clicks: int = Field(default=1, ge=1, le=3)


class MouseRelease(BaseModel):
    """Solta um botão que estava segurado."""

    kind: Literal["mouse_release"] = "mouse_release"
    button: Literal["left", "right", "middle"] = "left"


class KeyText(BaseModel):
    kind: Literal["key_text"] = "key_text"
    text: str = Field(min_length=1, max_length=4096)


class KeyPress(BaseModel):
    kind: Literal["key_press"] = "key_press"
    key: SpecialKey


class KeyCombo(BaseModel):
    kind: Literal["key_combo"] = "key_combo"
    modifiers: list[Modifier] = Field(min_length=1)
    key: str = Field(min_length=1, max_length=16)


class KeyReplace(BaseModel):
    """Apaga `backspaces` caracteres e digita `text` — numa mensagem só.

    Existe por causa do canal de dados, que é **não ordenado** de propósito
    (ver `agent/src/datachannel.rs`): mandar os backspaces e o texto separados
    permitiria que chegassem fora de ordem e embaralhassem a palavra. Como uma
    ação única, ou chega inteira ou não chega.

    O teto de 64 não é sobre a interface — é sobre o que uma mensagem
    adulterada poderia mandar o computador fazer.
    """

    kind: Literal["key_replace"] = "key_replace"
    backspaces: int = Field(ge=0, le=64)
    text: str = Field(min_length=1, max_length=256)


InputAction = Annotated[
    MouseMove
    | MouseMoveTo
    | MouseClick
    | MousePress
    | MouseRelease
    | MouseScroll
    | KeyText
    | KeyPress
    | KeyCombo
    | KeyReplace,
    Field(discriminator="kind"),
]
