"""Rotas de autenticação: cadastro em duas etapas, login, refresh e /me.

O cadastro tem **duas etapas** e a conta só existe depois da segunda:

1. `POST /auth/signup/start` recebe o formulário inteiro, valida tudo (senha,
   telefone, idade, e-mail livre) e manda um código de seis dígitos. Nada é
   criado em `users` — o que se cria é um `PendingSignup`.
2. `POST /auth/signup/verify` confere o código e **aí sim** cria a conta,
   devolvendo os tokens.

A ordem importa e não é arbitrária. Validar tudo antes de enviar evita gastar um
SMS para depois dizer "a senha precisa de um número". E adiar a criação da conta
fecha um buraco concreto: um `User` não verificado ocuparia o e-mail na
restrição de unicidade, e bastaria digitar o endereço de outra pessoa para
**impedir que ela se cadastre** — sem nunca provar que o endereço é seu.

Os métodos externos (Google, Apple, Microsoft) entram por cima desta base:
produzem a identidade e reaproveitam a mesma emissão de tokens.
"""

from datetime import UTC, date, datetime

import jwt
from fastapi import APIRouter, Depends, HTTPException, status
from fastapi.security import HTTPAuthorizationCredentials, HTTPBearer
from sqlalchemy import select
from sqlalchemy.orm import Session

from app import entrega, telefone, verificacao
from app import senha as politica_de_senha
from app.config import settings
from app.db import get_db
from app.models import PendingSignup, User
from app.schemas import (
    AccessToken,
    CountryOut,
    Credentials,
    DeleteAccountRequest,
    RefreshRequest,
    SignupPending,
    SignupResend,
    SignupStart,
    SignupVerify,
    TokenPair,
    TwoFactorDisableRequest,
    TwoFactorEnableRequest,
    TwoFactorSetupOut,
    UpdateEmailRequest,
    UpdatePasswordRequest,
    UserOut,
)
from app.security import (
    create_access_token,
    create_refresh_token,
    decode_token,
    generate_totp_secret,
    hash_password,
    totp_uri,
    verify_password,
    verify_totp,
)

router = APIRouter(prefix="/api/v1/auth", tags=["auth"])
_bearer = HTTPBearer(auto_error=True)


def _tokens_for(user: User) -> TokenPair:
    subject = str(user.id)
    return TokenPair(
        access_token=create_access_token(subject),
        refresh_token=create_refresh_token(subject),
    )


def get_current_user(
    credentials: HTTPAuthorizationCredentials = Depends(_bearer),
    db: Session = Depends(get_db),
) -> User:
    """Resolve o usuário autenticado a partir do access token (Bearer)."""
    invalid = HTTPException(
        status_code=status.HTTP_401_UNAUTHORIZED,
        detail="credenciais inválidas",
        headers={"WWW-Authenticate": "Bearer"},
    )
    try:
        payload = decode_token(credentials.credentials)
    except jwt.PyJWTError as exc:
        raise invalid from exc

    if payload.get("type") != "access":
        raise invalid

    user = db.get(User, int(payload["sub"]))
    if user is None:
        raise invalid
    return user


def _rotulo(user: User) -> str:
    """Como a conta se identifica em texto — para o app autenticador, por ora.

    Uma conta por telefone não tem e-mail, e o `otpauth://` precisa de **algum**
    nome: sem ele o Google Authenticator mostra uma linha em branco e a pessoa
    não sabe qual dos códigos é o do Deskside.
    """
    return user.email or user.phone or f"conta {user.id}"


def _erro(codigo: int, detalhe: str) -> HTTPException:
    return HTTPException(status_code=codigo, detail=detalhe)


def _idade(nascimento: date, hoje: date | None = None) -> int:
    """Anos completos. A conta com `(mês, dia)` evita o erro clássico de dividir
    dias por 365 e dar um ano a mais para quem faz aniversário em dezembro."""
    hoje = hoje or datetime.now(UTC).date()
    return hoje.year - nascimento.year - (
        (hoje.month, hoje.day) < (nascimento.month, nascimento.day)
    )


def _destino(body: SignupStart | Credentials) -> tuple[str, str]:
    """O identificador normalizado e o canal, ou um 400 explicando o quê.

    Normalizar aqui, num lugar só, é o que impede `Caio@X.com` e `caio@x.com` de
    virarem duas contas — e `(11) 98765-4321` e `11987654321` de virarem outras
    duas.
    """
    if body.email is not None:
        return str(body.email).strip().lower(), "email"

    pais = telefone.pais(body.country or "")
    if pais is None:
        raise _erro(status.HTTP_400_BAD_REQUEST, "país desconhecido")
    numero = telefone.normalizar(body.phone or "", pais.iso)
    if numero is None:
        raise _erro(
            status.HTTP_400_BAD_REQUEST,
            f"número de telefone inválido para {pais.nome} "
            f"(esperado {pais.minimo}–{pais.maximo} dígitos com DDD)",
        )
    return numero, "phone"


def _livre(db: Session, destino: str, canal: str) -> None:
    """Recusa quem já tem conta.

    Diz **qual** é o problema, ao contrário do login, e de propósito: aqui a
    informação "este e-mail já tem conta" é o que a pessoa precisa para ir
    entrar em vez de tentar cadastrar de novo. O anonimato que se protege no
    login não se protege num formulário de cadastro — qualquer serviço revela
    isso, porque a alternativa é não conseguir explicar o erro.
    """
    coluna = User.email if canal == "email" else User.phone
    if db.scalar(select(User).where(coluna == destino)) is not None:
        rotulo = "e-mail" if canal == "email" else "telefone"
        raise _erro(status.HTTP_409_CONFLICT, f"{rotulo} já cadastrado")


def _enviar(destino: str, canal: str, codigo: str) -> bool:
    """Manda o código. Devolve se ele saiu de verdade ou foi para o diário."""
    try:
        if canal == "email":
            entrega.entregador.email(destino, codigo)
        else:
            entrega.entregador.sms(destino, codigo)
    except entrega.EntregaError as exc:
        # 502 e não 500: quem falhou foi um serviço de fora, e a mensagem dele
        # é a única pista que existe (número não verificado, sem saldo).
        raise _erro(status.HTTP_502_BAD_GATEWAY, str(exc)) from exc
    return entrega.configurado()[
        "email" if canal == "email" else "sms"
    ]


@router.get("/countries", response_model=list[CountryOut])
def countries() -> list[CountryOut]:
    """Os países do seletor de telefone.

    Vem do servidor mesmo o app tendo a própria cópia (que é o que desenha a
    tela sem esperar rede): é aqui que a lista cresce quando o produto passar a
    atender um país novo, e um app mais velho não precisa ser reinstalado para
    o número passar a ser aceito.
    """
    return [
        CountryOut(iso=p.iso, name=p.nome, dial_code=p.ddi, flag=p.bandeira)
        for p in telefone.PAISES
    ]


@router.post(
    "/signup/start", response_model=SignupPending, status_code=status.HTTP_201_CREATED
)
def signup_start(body: SignupStart, db: Session = Depends(get_db)) -> SignupPending:
    """Valida o formulário e manda o código. **Não cria conta nenhuma.**"""
    faltando = politica_de_senha.problemas(body.password)
    if faltando:
        raise _erro(
            status.HTTP_400_BAD_REQUEST, "a senha precisa de: " + ", ".join(faltando)
        )

    hoje = datetime.now(UTC).date()
    if body.birth_date > hoje:
        raise _erro(status.HTTP_400_BAD_REQUEST, "data de nascimento no futuro")
    anos = _idade(body.birth_date, hoje)
    if anos > 120:
        raise _erro(status.HTTP_400_BAD_REQUEST, "confira a data de nascimento")
    if anos < settings.idade_minima:
        raise _erro(
            status.HTTP_400_BAD_REQUEST,
            f"é preciso ter pelo menos {settings.idade_minima} anos",
        )

    destino, canal = _destino(body)
    _livre(db, destino, canal)

    # Recomeçar substitui o cadastro pendente anterior. Guardar os dois deixaria
    # dois códigos válidos para o mesmo destino, e o segundo confundiria quem
    # ainda estava esperando o primeiro.
    anterior = db.scalar(select(PendingSignup).where(PendingSignup.destino == destino))
    if anterior is not None:
        db.delete(anterior)
        db.flush()

    codigo = verificacao.gerar()
    agora = datetime.now(UTC)
    pendente = PendingSignup(
        destino=destino,
        canal=canal,
        hashed_password=hash_password(body.password),
        first_name=body.first_name.strip(),
        last_name=body.last_name.strip(),
        birth_date=body.birth_date,
        hashed_code=verificacao.resumo(codigo),
        expires_at=verificacao.prazo(agora),
        last_sent_at=agora,
    )
    db.add(pendente)
    db.commit()

    entregue = _enviar(destino, canal, codigo)
    return SignupPending(
        destination=destino,
        channel=canal,
        resend_in_seconds=int(verificacao.ESPERA_REENVIO.total_seconds()),
        delivered=entregue,
    )


@router.post("/signup/resend", response_model=SignupPending)
def signup_resend(body: SignupResend, db: Session = Depends(get_db)) -> SignupPending:
    """Manda outro código, com um novo prazo — e zera as tentativas erradas.

    Zerar é o certo: as tentativas contam contra *aquele* código, e o que a
    pessoa vai digitar agora é outro.
    """
    pendente = _pendente(db, body.destination)
    if not verificacao.pode_reenviar(pendente.last_sent_at):
        raise _erro(
            status.HTTP_429_TOO_MANY_REQUESTS,
            f"espere {verificacao.segundos_para_reenviar(pendente.last_sent_at)}s "
            "para pedir outro código",
        )

    codigo = verificacao.gerar()
    agora = datetime.now(UTC)
    pendente.hashed_code = verificacao.resumo(codigo)
    pendente.expires_at = verificacao.prazo(agora)
    pendente.last_sent_at = agora
    pendente.attempts = 0
    db.commit()

    entregue = _enviar(pendente.destino, pendente.canal, codigo)
    return SignupPending(
        destination=pendente.destino,
        channel=pendente.canal,
        resend_in_seconds=int(verificacao.ESPERA_REENVIO.total_seconds()),
        delivered=entregue,
    )


@router.post(
    "/signup/verify", response_model=TokenPair, status_code=status.HTTP_201_CREATED
)
def signup_verify(body: SignupVerify, db: Session = Depends(get_db)) -> TokenPair:
    """Confere o código e cria a conta."""
    pendente = _pendente(db, body.destination)

    if verificacao.expirou(pendente.expires_at):
        db.delete(pendente)
        db.commit()
        raise _erro(status.HTTP_410_GONE, "o código expirou; peça outro")

    if not verificacao.confere(body.code.strip(), pendente.hashed_code):
        pendente.attempts += 1
        restantes = verificacao.MAX_TENTATIVAS - pendente.attempts
        if restantes <= 0:
            # Descarta o cadastro inteiro, e não só o código: seis dígitos com
            # tentativas infinitas se adivinham, e reaproveitar o mesmo
            # pendente com um código novo devolveria as tentativas de graça.
            db.delete(pendente)
            db.commit()
            raise _erro(
                status.HTTP_429_TOO_MANY_REQUESTS,
                "tentativas demais; recomece o cadastro",
            )
        db.commit()
        raise _erro(
            status.HTTP_401_UNAUTHORIZED,
            f"código incorreto ({restantes} tentativa"
            f"{'s' if restantes > 1 else ''} restante"
            f"{'s' if restantes > 1 else ''})",
        )

    # Entre o início e a confirmação alguém pode ter cadastrado o mesmo destino.
    # Sem esta conferência, o `commit` estouraria a unicidade e viraria um 500.
    _livre(db, pendente.destino, pendente.canal)

    user = User(
        email=pendente.destino if pendente.canal == "email" else None,
        phone=pendente.destino if pendente.canal == "phone" else None,
        hashed_password=pendente.hashed_password,
        first_name=pendente.first_name,
        last_name=pendente.last_name,
        birth_date=pendente.birth_date,
    )
    db.add(user)
    db.delete(pendente)
    db.commit()
    db.refresh(user)
    return _tokens_for(user)


def _pendente(db: Session, destino: str) -> PendingSignup:
    # `lower()` serve ao e-mail e não faz mal ao telefone, que é só `+` e
    # dígitos — é o mesmo tratamento que o destino recebeu ao ser gravado.
    achado = db.scalar(
        select(PendingSignup).where(PendingSignup.destino == destino.strip().lower())
    )
    if achado is None:
        raise _erro(
            status.HTTP_404_NOT_FOUND,
            "não há cadastro em andamento para este contato",
        )
    return achado


@router.post("/login", response_model=TokenPair)
def login(body: Credentials, db: Session = Depends(get_db)) -> TokenPair:
    destino, canal = _destino(body)
    coluna = User.email if canal == "email" else User.phone
    user = db.scalar(select(User).where(coluna == destino))
    if user is None or not verify_password(body.password, user.hashed_password):
        # Uma mensagem só para "não existe" e "senha errada": distinguir as duas
        # diria a um estranho quais contas existem.
        raise HTTPException(
            status_code=status.HTTP_401_UNAUTHORIZED,
            detail="e-mail, telefone ou senha inválidos",
        )
    # 2FA: com a senha correta, ainda exige o código do autenticador. O app
    # reconhece os detalhes "two_factor_required"/"two_factor_invalid".
    if user.totp_enabled:
        if not body.totp_code:
            raise HTTPException(
                status_code=status.HTTP_401_UNAUTHORIZED, detail="two_factor_required"
            )
        if not verify_totp(user.totp_secret or "", body.totp_code):
            raise HTTPException(
                status_code=status.HTTP_401_UNAUTHORIZED, detail="two_factor_invalid"
            )
    return _tokens_for(user)


@router.post("/refresh", response_model=AccessToken)
def refresh(body: RefreshRequest, db: Session = Depends(get_db)) -> AccessToken:
    invalid = HTTPException(
        status_code=status.HTTP_401_UNAUTHORIZED, detail="refresh token inválido"
    )
    try:
        payload = decode_token(body.refresh_token)
    except jwt.PyJWTError as exc:
        raise invalid from exc

    if payload.get("type") != "refresh":
        raise invalid
    user = db.get(User, int(payload["sub"]))
    if user is None:
        raise invalid
    return AccessToken(access_token=create_access_token(str(user.id)))


@router.get("/me", response_model=UserOut)
def me(current_user: User = Depends(get_current_user)) -> User:
    return current_user


@router.patch("/me/email", response_model=UserOut)
def update_email(
    body: UpdateEmailRequest,
    current_user: User = Depends(get_current_user),
    db: Session = Depends(get_db),
) -> User:
    """Troca o e-mail da conta (exige a senha atual)."""
    if not verify_password(body.current_password, current_user.hashed_password):
        raise HTTPException(
            status_code=status.HTTP_401_UNAUTHORIZED, detail="senha atual incorreta"
        )
    if body.new_email != current_user.email:
        taken = db.scalar(select(User).where(User.email == body.new_email))
        if taken is not None:
            raise HTTPException(
                status_code=status.HTTP_409_CONFLICT, detail="e-mail já cadastrado"
            )
        current_user.email = body.new_email
        db.commit()
        db.refresh(current_user)
    return current_user


@router.patch("/me/password", status_code=status.HTTP_204_NO_CONTENT)
def update_password(
    body: UpdatePasswordRequest,
    current_user: User = Depends(get_current_user),
    db: Session = Depends(get_db),
) -> None:
    """Troca a senha da conta (exige a senha atual)."""
    if not verify_password(body.current_password, current_user.hashed_password):
        raise HTTPException(
            status_code=status.HTTP_401_UNAUTHORIZED, detail="senha atual incorreta"
        )
    current_user.hashed_password = hash_password(body.new_password)
    db.commit()


@router.post("/2fa/setup", response_model=TwoFactorSetupOut)
def two_factor_setup(
    current_user: User = Depends(get_current_user),
    db: Session = Depends(get_db),
) -> TwoFactorSetupOut:
    """Gera um segredo TOTP e o URI para o QR Code. Ainda não ativa o 2FA."""
    if current_user.totp_enabled:
        raise HTTPException(
            status_code=status.HTTP_409_CONFLICT, detail="2FA já está ativo"
        )
    secret = generate_totp_secret()
    current_user.totp_secret = secret  # pendente até confirmar o código
    db.commit()
    return TwoFactorSetupOut(
        secret=secret, otpauth_uri=totp_uri(secret, _rotulo(current_user))
    )


@router.post("/2fa/enable", status_code=status.HTTP_204_NO_CONTENT)
def two_factor_enable(
    body: TwoFactorEnableRequest,
    current_user: User = Depends(get_current_user),
    db: Session = Depends(get_db),
) -> None:
    """Ativa o 2FA confirmando um código do autenticador."""
    if current_user.totp_enabled:
        raise HTTPException(
            status_code=status.HTTP_409_CONFLICT, detail="2FA já está ativo"
        )
    if not current_user.totp_secret:
        raise HTTPException(
            status_code=status.HTTP_400_BAD_REQUEST,
            detail="inicie a configuração do 2FA antes",
        )
    if not verify_totp(current_user.totp_secret, body.code):
        raise HTTPException(
            status_code=status.HTTP_401_UNAUTHORIZED, detail="código inválido"
        )
    current_user.totp_enabled = True
    db.commit()


@router.post("/2fa/disable", status_code=status.HTTP_204_NO_CONTENT)
def two_factor_disable(
    body: TwoFactorDisableRequest,
    current_user: User = Depends(get_current_user),
    db: Session = Depends(get_db),
) -> None:
    """Desativa o 2FA (exige a senha atual) e apaga o segredo."""
    if not verify_password(body.password, current_user.hashed_password):
        raise HTTPException(
            status_code=status.HTTP_401_UNAUTHORIZED, detail="senha incorreta"
        )
    current_user.totp_enabled = False
    current_user.totp_secret = None
    db.commit()


@router.delete("/me", status_code=status.HTTP_204_NO_CONTENT)
def delete_account(
    body: DeleteAccountRequest,
    current_user: User = Depends(get_current_user),
    db: Session = Depends(get_db),
) -> None:
    """Exclui a conta e todos os dispositivos vinculados (exige a senha)."""
    if not verify_password(body.password, current_user.hashed_password):
        raise HTTPException(
            status_code=status.HTTP_401_UNAUTHORIZED, detail="senha incorreta"
        )
    db.delete(current_user)
    db.commit()
