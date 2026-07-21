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


class MouseClick(BaseModel):
    kind: Literal["mouse_click"] = "mouse_click"
    button: Literal["left", "right", "middle"] = "left"


class MouseScroll(BaseModel):
    kind: Literal["mouse_scroll"] = "mouse_scroll"
    dy: int


InputAction = Annotated[
    MouseMove | MouseClick | MouseScroll, Field(discriminator="kind")
]
