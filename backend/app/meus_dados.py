"""Uma cópia de tudo o que o Deskside guarda sobre a conta (LGPD, art. 18).

O direito de acesso e de portabilidade antes dependia de um e-mail e de alguém
montar a resposta à mão. Aqui sai na hora, num JSON que a pessoa guarda ou leva
para outro serviço.

## O que entra e o que não entra

Entra tudo o que é **sobre a pessoa**: a conta, os computadores, os perfis, as
automações, os aparelhos conectados e as assinaturas.

**Não entram os segredos**, ainda que guardados na conta: o hash da senha, o
segredo do 2FA, os códigos de recuperação, a chave das sessões e o segredo de
cada computador. Não são informação sobre a pessoa - são credenciais, e um
arquivo de exportação esquecido numa pasta de downloads não pode virar uma
chave da conta. A lista mora em `SEGREDOS`, e o teste confere cada um.
"""

from __future__ import annotations

from datetime import UTC, date, datetime

from fastapi import APIRouter, Depends
from sqlalchemy.inspection import inspect as inspecionar
from sqlalchemy.orm import Session

from app.auth import get_current_user
from app.db import get_db
from app.models import User

router = APIRouter(prefix="/api/v1/auth", tags=["conta"])

#: Colunas que nunca saem, em tabela nenhuma.
SEGREDOS = frozenset(
    {
        "hashed_password",
        "totp_secret",
        "totp_ultimo_passo",
        "recovery_codes",
        "token_key",
        "agent_secret",
        "agent_secret_pendente",
        "geracao",
        "id_hash",
        "user_id",
    }
)


def _linha(obj) -> dict:
    """As colunas de uma linha, sem os segredos, em tipos que o JSON aceita."""
    saida = {}
    for coluna in inspecionar(obj).mapper.column_attrs:
        nome = coluna.key
        if nome in SEGREDOS:
            continue
        valor = getattr(obj, nome)
        if isinstance(valor, datetime | date):
            valor = valor.isoformat()
        saida[nome] = valor
    return saida


@router.get("/me/export")
def exportar(
    current_user: User = Depends(get_current_user),
    db: Session = Depends(get_db),
) -> dict:
    """Tudo o que está guardado sobre esta conta, menos as credenciais."""
    conta = _linha(current_user)
    conta["verificacao_em_duas_etapas"] = bool(current_user.totp_enabled)
    return {
        "gerado_em": datetime.now(UTC).isoformat(),
        "conta": conta,
        "computadores": [_linha(d) for d in current_user.devices],
        "perfis": [_linha(p) for p in current_user.profiles],
        "ordem_dos_perfis": _linha(current_user.profile_layout)
        if current_user.profile_layout
        else None,
        "automacoes": [_linha(a) for a in current_user.automations],
        "widget": _linha(current_user.widget) if current_user.widget else None,
        "aparelhos_conectados": [_linha(s) for s in current_user.sessoes],
        "assinaturas": [_linha(a) for a in current_user.assinaturas],
        "observacao": (
            "As credenciais (senha, verificação em duas etapas, chaves de sessão "
            "e segredos dos computadores) não entram nesta cópia. Dúvidas: "
            "contato@deskside.com.br."
        ),
    }
