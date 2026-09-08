"""Rotas de assinatura: validar uma compra e ouvir as lojas.

Três portas, com naturezas de segurança **muito** diferentes, e vale ter isso
claro antes de ler o código:

- `POST /api/v1/assinatura/validar` — fala o nosso aplicativo, autenticado pelo
  token da conta. Sabemos quem é; não sabemos se a compra existe.
- `GET  /api/v1/assinatura` — idem, só leitura.
- `POST /webhooks/{loja}` — fala a loja, para um endereço sem senha, aberto na
  internet. **Não** sabemos quem é: quem diz é a assinatura criptográfica do
  corpo, conferida dentro de `app/lojas.py`. Qualquer pessoa pode bater aqui, e
  o desenho parte disso.

## Por que o webhook existe

Sem ele, a renovação do mês seguinte só seria percebida quando a pessoa abrisse
o aplicativo — e quem cancelasse continuaria com plano pago até alguém reparar.
É o webhook que torna a cobrança automática; o resto é o que a torna correta.
"""

from __future__ import annotations

import hashlib
import logging

from fastapi import APIRouter, Depends, HTTPException, Request, status
from pydantic import BaseModel, Field
from sqlalchemy.orm import Session

from app import assinatura as regras
from app import cobranca, lojas
from app.assinatura import em_utc
from app.auth import get_current_user
from app.config import settings
from app.db import get_db
from app.models import Assinatura, User
from app.plano import Plano

logger = logging.getLogger("deskside")

router = APIRouter()

#: Teto do corpo de uma notificação de loja.
#:
#: Existe porque `/webhooks/{loja}` é o único endereço deste servidor que aceita
#: `POST` de qualquer pessoa, sem token, e lê o corpo inteiro na memória. Uma
#: notificação da Apple tem dezenas de kilobytes; isto é uma ordem de grandeza
#: de folga, e continua sendo pequeno o bastante para não derrubar uma VM de
#: 1 GB de RAM por acidente ou de propósito.
MAX_CORPO_WEBHOOK = 256 * 1024


def resumo_do_id(loja: regras.Loja, id_original: str) -> str:
    """O que vai ao banco no lugar do identificador da loja.

    A loja entra no resumo para o mesmo identificador em lojas diferentes não
    colidir — e, mais importante, para o resumo de uma não servir de chave de
    busca na outra.
    """
    return hashlib.sha256(f"{loja.value}:{id_original}".encode()).hexdigest()


class ValidarIn(BaseModel):
    #: "apple" ou "google".
    loja: regras.Loja
    #: O comprovante opaco que a loja entregou ao aplicativo.
    #:
    #: Limite generoso porque um JWS da Apple é grande, mas **existe**: sem
    #: teto, um corpo de dezenas de megabytes atravessa a validação do Pydantic
    #: e chega à verificação, que é a parte cara.
    comprovante: str = Field(min_length=8, max_length=32_768)


class AssinaturaOut(BaseModel):
    """O que o aplicativo precisa saber, e nada além disso.

    Sem `id_hash`, sem comprovante e sem identificador de loja. O aplicativo não
    tem o que fazer com nenhum dos três, e uma resposta que os carregasse os
    espalharia por diários de rede, capturas de tela de suporte e relatórios de
    erro de terceiros.
    """

    plano: str
    ativa: bool
    expira_em: str | None = None
    loja: str | None = None
    estado: str | None = None


def _resposta(user: User, atual: Assinatura | None) -> AssinaturaOut:
    #: A conta é a fonte da verdade, e não a linha da assinatura: quem foi
    #: liberado à mão não tem assinatura nenhuma e continua pago.
    plano = cobranca.plano_de(user)
    return AssinaturaOut(
        plano=plano.value,
        ativa=plano is Plano.PAGO,
        expira_em=user.plano_ate.isoformat() if user.plano_ate else None,
        loja=atual.loja if atual else None,
        estado=atual.estado if atual else None,
    )


def _aplicar(db: Session, user: User, compra: regras.Compra) -> Assinatura:
    """Grava a compra e põe o plano da conta em dia.

    O ponto delicado é o vínculo: um comprovante vale para **uma** conta. A
    restrição de unicidade em `id_hash` é quem garante isso no banco; esta
    função é quem transforma a violação num 409 legível em vez de um erro 500.
    """
    id_hash = resumo_do_id(compra.loja, compra.id_original)
    existente = (
        db.query(Assinatura).filter(Assinatura.id_hash == id_hash).one_or_none()
    )

    if existente is not None and existente.user_id != user.id:
        # A fraude mais barata contra compra em loja: assinar uma vez e passar o
        # comprovante adiante. Recusar aqui é o que faz uma assinatura valer uma
        # conta — e o texto não diz de quem é, porque isso confirmaria a
        # existência da outra conta a quem está tentando.
        raise HTTPException(
            status_code=status.HTTP_409_CONFLICT,
            detail="esta compra já está vinculada a outra conta do Deskside",
        )

    if existente is not None and not regras.deve_aplicar(existente.visto_em, compra):
        # Notificação repetida ou fora de ordem. Não é erro: é o comportamento
        # normal das lojas, que reenviam até receber confirmação.
        return existente

    alvo = existente or Assinatura(user_id=user.id, id_hash=id_hash)
    alvo.loja = compra.loja.value
    alvo.product_id = compra.product_id
    alvo.estado = compra.estado.value
    alvo.ambiente = compra.ambiente.value
    alvo.expira_em = compra.expira_em
    alvo.visto_em = compra.visto_em
    if existente is None:
        db.add(alvo)

    _sincronizar_plano(user, compra)
    db.commit()
    db.refresh(alvo)
    return alvo


def _sincronizar_plano(user: User, compra: regras.Compra) -> None:
    """Escreve o resultado da compra no plano da conta.

    Rebaixar é tão importante quanto promover, e é a metade que se esquece: sem
    o `else`, um reembolso gravaria o estado novo na assinatura e deixaria a
    conta paga para sempre.

    E o que **não** acontece aqui: derrubar quem foi liberado à mão. Uma conta
    com `plano_ate` nulo e plano pago é uma cortesia dada por `python -m
    app.conta`, sem prazo — uma compra de loja que expirou não desfaz isso.
    """
    ate = regras.ate_quando(compra, aceitar_sandbox=settings.aceitar_sandbox)
    if ate is not None:
        user.plano = "pago"
        # Só para frente: uma notificação atrasada não pode encurtar um prazo
        # que uma renovação mais nova já esticou.
        if user.plano_ate is None or em_utc(user.plano_ate) < em_utc(ate):
            user.plano_ate = ate
        return

    # Daqui para baixo, a compra não vale mais.
    if user.plano_ate is None:
        return  # cortesia sem prazo: não é desta compra que ela veio
    if compra.expira_em is None or em_utc(user.plano_ate) <= em_utc(compra.expira_em):
        user.plano = "gratis"


@router.post("/api/v1/assinatura/validar", response_model=AssinaturaOut)
def validar(
    corpo: ValidarIn,
    current_user: User = Depends(get_current_user),
    db: Session = Depends(get_db),
) -> AssinaturaOut:
    """O aplicativo acabou de comprar; o servidor confere com a loja.

    Chamado também no "restaurar compras", que a Apple exige — e é o mesmo
    caminho de propósito: restaurar é revalidar, e ter dois caminhos para a
    mesma decisão é ter duas chances de eles discordarem.
    """
    verificador = lojas.verificador_de(corpo.loja)
    try:
        compra = verificador.verificar(corpo.comprovante)
    except lojas.ComprovanteInvalido as recusa:
        # 402 e não 400: a requisição está bem formada, o que falta é um
        # pagamento válido.
        raise HTTPException(
            status_code=status.HTTP_402_PAYMENT_REQUIRED, detail=str(recusa)
        ) from recusa
    except lojas.LojaError as falha:
        raise HTTPException(
            status_code=status.HTTP_502_BAD_GATEWAY,
            detail=f"não consegui falar com a loja: {falha}",
        ) from falha
    except NotImplementedError as falta:
        raise HTTPException(
            status_code=status.HTTP_503_SERVICE_UNAVAILABLE,
            detail="assinatura por loja ainda não está configurada neste servidor",
        ) from falta

    atual = _aplicar(db, current_user, compra)
    return _resposta(current_user, atual)


@router.get("/api/v1/assinatura", response_model=AssinaturaOut)
def minha_assinatura(
    current_user: User = Depends(get_current_user),
    db: Session = Depends(get_db),
) -> AssinaturaOut:
    """O estado que o aplicativo mostra na tela de plano."""
    atual = (
        db.query(Assinatura)
        .filter(Assinatura.user_id == current_user.id)
        .order_by(Assinatura.atualizada_em.desc())
        .first()
    )
    return _resposta(current_user, atual)


@router.post("/webhooks/{loja}", status_code=status.HTTP_204_NO_CONTENT)
async def webhook(loja: regras.Loja, request: Request, db: Session = Depends(get_db)) -> None:
    """A loja avisando que algo mudou: renovou, cancelou, falhou, reembolsou.

    ## Três decisões que este punhado de linhas embute

    **A assinatura do corpo é conferida antes de qualquer leitura**, dentro de
    `lojas.ler_notificacao`. Este endereço não pede senha — não pode: quem bate
    aqui é a Apple, e ela não tem como fazer login. O que separa a loja de um
    impostor é criptografia, e nada mais.

    **Responder 204 mesmo para o que não reconhecemos.** Uma notificação de uma
    assinatura de conta já apagada, ou de um produto que não existe mais, não é
    erro nosso. Devolver 500 faria a loja reenviar em intervalos crescentes por
    dias, e a fila de notificações **de verdade** ficaria atrás dela.

    **Nada do corpo vai para o diário.** A notificação carrega o comprovante
    assinado, e no caso do Google um token que é credencial. O que se registra é
    o que aconteceu, nunca com o quê.
    """
    # Teto antes de ler. `request.body()` traz o corpo inteiro para a memória, e
    # este endereço é aberto na internet e não pede senha: sem limite, um `POST`
    # de um gigabyte derruba um servidor de 1 GB de RAM sem precisar de conta,
    # de token e de nada. Uma notificação da Apple não passa de dezenas de
    # kilobytes; 256 KB é folga de uma ordem de grandeza.
    tamanho = request.headers.get("content-length")
    if tamanho and tamanho.isdigit() and int(tamanho) > MAX_CORPO_WEBHOOK:
        raise HTTPException(
            status_code=status.HTTP_413_REQUEST_ENTITY_TOO_LARGE,
            detail="corpo grande demais para uma notificação de loja",
        )

    corpo = await request.body()
    if len(corpo) > MAX_CORPO_WEBHOOK:
        # O cabeçalho pode mentir, ou faltar (`Transfer-Encoding: chunked`).
        # Conferir de novo depois de ler é o que fecha o buraco de verdade — o
        # `if` acima só evita ler à toa quando o remetente é honesto.
        raise HTTPException(
            status_code=status.HTTP_413_REQUEST_ENTITY_TOO_LARGE,
            detail="corpo grande demais para uma notificação de loja",
        )

    try:
        compra = lojas.verificador_de(loja).ler_notificacao(corpo)
    except (lojas.LojaError, NotImplementedError) as recusa:
        # 400 e não 204: aqui a loja **precisa** saber que não foi aceito, senão
        # uma notificação legítima que falhou na conferência sumiria em silêncio
        # — e com ela a renovação, ou o reembolso, de alguém.
        logger.warning("notificação de %s recusada: %s", loja.value, recusa)
        raise HTTPException(
            status_code=status.HTTP_400_BAD_REQUEST, detail="notificação recusada"
        ) from recusa

    id_hash = resumo_do_id(compra.loja, compra.id_original)
    alvo = db.query(Assinatura).filter(Assinatura.id_hash == id_hash).one_or_none()
    if alvo is None:
        # Conta apagada, ou compra que nunca foi validada pelo aplicativo. Não
        # há a quem aplicar, e insistir não muda isso.
        logger.info("notificação de %s sem assinatura correspondente", loja.value)
        return

    if not regras.deve_aplicar(alvo.visto_em, compra):
        return

    dono = db.get(User, alvo.user_id)
    if dono is None:
        return

    alvo.estado = compra.estado.value
    alvo.expira_em = compra.expira_em
    alvo.visto_em = compra.visto_em
    _sincronizar_plano(dono, compra)
    db.commit()
    logger.info(
        "assinatura %s atualizada por notificação: %s", alvo.id, compra.estado.value
    )
