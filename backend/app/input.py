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


InputAction = Annotated[
    MouseMove | MouseMoveTo | MouseClick | MouseScroll | KeyText | KeyPress | KeyCombo,
    Field(discriminator="kind"),
]
