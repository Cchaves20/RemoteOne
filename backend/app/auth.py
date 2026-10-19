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

import logging
from datetime import UTC, date, datetime

import jwt
from fastapi import APIRouter, BackgroundTasks, Depends, HTTPException, Request, Response, status
from fastapi.responses import JSONResponse
from fastapi.security import HTTPAuthorizationCredentials, HTTPBearer
from sqlalchemy import select
from sqlalchemy.orm import Session

from app import (
    alertas,
    cobranca,
    cofre,
    entrega,
    limite,
    segundo_fator,
    sessoes,
    telefone,
    teste,
    verificacao,
)
from app import senha as politica_de_senha
from app.config import settings
from app.db import get_db
from app.models import PasswordReset, PendingContactChange, PendingSignup, Sessao, User
from app.schemas import (
    AccessToken,
    ContactChangeStart,
    ContactChangeVerify,
    CountryOut,
    Credentials,
    DeleteAccountRequest,
    ForgotPasswordRequest,
    RecoveryCodesOut,
    RecoveryCodesRequest,
    RefreshRequest,
    ResetPasswordRequest,
    SessaoOut,
    SignupPending,
    SignupResend,
    SignupStart,
    SignupVerify,
    TokenPair,
    TwoFactorDisableRequest,
    TwoFactorEnableRequest,
    TwoFactorSetupOut,
    UpdatePasswordRequest,
    UserOut,
)
from app.security import (
    chave_confere,
    create_access_token,
    create_refresh_token,
    decode_token,
    generate_totp_secret,
    hash_password,
    nova_chave_de_sessao,
    totp_uri,
    verify_password,
)

logger = logging.getLogger("deskside")

router = APIRouter(prefix="/api/v1/auth", tags=["auth"])
_bearer = HTTPBearer(auto_error=True)


def sessao_valida(payload: dict, user: User, db: Session) -> bool:
    """O token continua valendo para **esta** conta?

    Uma pergunta que a assinatura do JWT não responde, porque ele é conferido
    sozinho, sem consultar o banco. Duas coisas dependem dela:

    1. **Trocar a senha derruba as sessões.** A troca sorteia uma
       `token_key` nova, e todo token emitido antes disso deixa de valer.
    2. **Um token não atravessa para a conta seguinte.** O SQLite reaproveita
       `INTEGER PRIMARY KEY`: apagar a conta 1 faz a próxima nascer como 1, e o
       token da apagada tem o mesmo `sub`. Como a chave é sorteada por conta, a
       da nova nunca coincide com a da morta. É a mesma armadilha que já tinha
       feito perfis de uma conta excluída reaparecerem em outra — aqui na forma
       de uma sessão inteira.

    Uma tentativa anterior usava o relógio (token emitido antes de a conta
    existir não é dela) e foi descartada: `iat` só tem segundos inteiros, então
    apagar e recriar a conta dentro do mesmo segundo passava direto. A chave
    sorteada não depende de relógio nem de folga.

    E uma terceira, por aparelho: o token aponta para uma sessão (`sid`) que
    pode ter sido encerrada sozinha — ver `app/sessoes.py`.
    """
    return chave_confere(payload, user.token_key) and sessoes.valida(db, payload, user)


def _tokens_for(user: User, sessao: Sessao) -> TokenPair:
    subject = str(user.id)
    return TokenPair(
        access_token=create_access_token(subject, user.token_key, sessao.id),
        refresh_token=create_refresh_token(
            subject, user.token_key, sessao.id, sessao.geracao
        ),
    )


def _entrar(db: Session, user: User, request: Request | None) -> TokenPair:
    """Abre uma sessão para este aparelho e devolve os tokens dela."""
    sessao = sessoes.abrir(db, user, request)
    db.commit()
    return _tokens_for(user, sessao)


def _sessao_de_quem_pede(db: Session, user: User, request: Request) -> Sessao:
    """A sessão do token desta requisição, ou uma nova se o token é de antes
    das sessões (não traz `sid`)."""
    sid = getattr(request.state, "sid", None)
    sessao = db.get(Sessao, sid) if sid else None
    if sessao is None or sessao.user_id != user.id:
        sessao = sessoes.abrir(db, user, request)
    return sessao


def get_current_user(
    request: Request,
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
    # A assinatura confere e o prazo não venceu — e ainda assim o token pode
    # estar cancelado. É aqui que a troca de senha faz efeito nas sessões que
    # já estavam abertas em outros aparelhos.
    if not sessao_valida(payload, user, db):
        raise invalid
    # As rotas de sessão precisam saber **qual** é a de quem pede.
    request.state.sid = payload.get("sid")
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


def _exigir_segundo_fator(user: User, codigo: str | None, request: Request) -> str | None:
    """Cobra o segundo fator numa ação sensível de quem já está logado.

    Com limite de tentativas, como o login: quem chegou aqui tem a sessão e a
    senha, e só falta adivinhar seis dígitos. Contado por **conta** (e não pelo
    contato, como no login) porque aqui a conta já está identificada.
    """
    if not user.totp_enabled:
        return None
    chave, ip = f"2fa:{user.id}", limite.ip_do_pedido(request)
    limite.cobrar_login(chave, ip)
    tipo = segundo_fator.exigir(user, codigo, ao_errar=lambda: limite.punir_login(chave, ip))
    limite.perdoar_login(chave, ip)
    return tipo


def _avisar_codigo_usado(
    tarefas: BackgroundTasks, user: User, tipo: str | None, ip: str | None
) -> None:
    """Um código de recuperação usado é sempre notícia — e diz quantos restam."""
    if tipo != "recuperacao":
        return
    sobram = segundo_fator.restantes(user)
    tarefas.add_task(
        alertas.enviar,
        alertas.montar(
            user,
            "codigo_usado",
            ip=ip,
            detalhe=f"Restam {sobram} código{'s' if sobram != 1 else ''}.",
        ),
    )


#: Um hash de verdade, calculado uma vez, para o login de conta que não existe.
#:
#: Sem ele, "não existe" respondia na hora e "senha errada" depois de um bcrypt:
#: a diferença de tempo dizia a um estranho quais contas existem — exatamente o
#: que a mensagem igual para os dois casos foi escrita para esconder.
_HASH_PARA_CONTA_QUE_NAO_EXISTE: str | None = None


def _hash_falso() -> str:
    global _HASH_PARA_CONTA_QUE_NAO_EXISTE
    if _HASH_PARA_CONTA_QUE_NAO_EXISTE is None:
        _HASH_PARA_CONTA_QUE_NAO_EXISTE = hash_password("nao-existe-conta-com-esta-senha")
    return _HASH_PARA_CONTA_QUE_NAO_EXISTE


def _idade(nascimento: date, hoje: date | None = None) -> int:
    """Anos completos. A conta com `(mês, dia)` evita o erro clássico de dividir
    dias por 365 e dar um ano a mais para quem faz aniversário em dezembro."""
    hoje = hoje or datetime.now(UTC).date()
    return hoje.year - nascimento.year - (
        (hoje.month, hoje.day) < (nascimento.month, nascimento.day)
    )


def _destino(
    body: SignupStart | Credentials | ForgotPasswordRequest | ContactChangeStart,
) -> tuple[str, str]:
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
        # O texto do provedor vai para o diário do servidor, **não** para a
        # tela de quem está se cadastrando.
        #
        # Antes ele ia para os dois, com o argumento de que era a única pista
        # existente. Era pista, sim — para mim, lendo o log. Na tela virou isto,
        # para um estranho tentando criar conta:
        #
        #     não consegui enviar o e-mail: (550, b'You can only send testing
        #     emails to your own email address (caiofbchaves@gmail.com). To send
        #     emails to other recipients, please verify a domain at
        #     resend.com/domains...
        #
        # Três coisas de uma vez: incompreensível para quem lê, entrega o nome
        # do provedor e o estado da conta dele, e **publica o e-mail pessoal do
        # dono** para qualquer pessoa que toque em "criar conta". A pista não se
        # perde: ela fica no log, onde eu a leio e o usuário não.
        logger.error("entrega falhou por %s: %s", canal, exc)
        # 502 e não 500: quem falhou foi um serviço de fora, e a diferença
        # importa para quem lê o log seis meses depois.
        raise _erro(
            status.HTTP_502_BAD_GATEWAY,
            "não conseguimos enviar o código agora. Tente de novo em alguns "
            "minutos; se continuar, fale com o suporte.",
        ) from exc
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
def signup_start(
    body: SignupStart, request: Request, db: Session = Depends(get_db)
) -> SignupPending:
    """Valida o formulário e manda o código. **Não cria conta nenhuma.**"""
    # Antes da validação. Cobrar só quando o formulário passa daria um jeito de
    # sondar de graça — e a validação inteira também custa CPU. Vinte por IP a
    # cada quinze minutos não incomoda ninguém real.
    limite.cobrar_envio(limite.ip_do_pedido(request))
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
def signup_verify(
    body: SignupVerify, request: Request, db: Session = Depends(get_db)
) -> TokenPair:
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

    email = pendente.destino if pendente.canal == "email" else None
    phone = pendente.destino if pendente.canal == "phone" else None
    # Trinta dias conhecendo o produto inteiro, e depois o plano grátis — nunca
    # uma conta bloqueada (ver `app/plano.py`). **Uma vez por pessoa**: quem já
    # teve teste, com este e-mail ou com uma variação dele (`+sufixo`, pontos
    # no Gmail), começa no grátis. Ver `app/teste.py`.
    plano_inicial, plano_ate = teste.plano_inicial(db, email, phone)
    user = User(
        email=email,
        phone=phone,
        hashed_password=pendente.hashed_password,
        first_name=pendente.first_name,
        last_name=pendente.last_name,
        birth_date=pendente.birth_date,
        plano=plano_inicial,
        plano_ate=plano_ate,
    )
    db.add(user)
    db.delete(pendente)
    db.commit()
    db.refresh(user)
    return _entrar(db, user, request)


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


@router.post("/password/forgot", response_model=SignupPending)
def forgot_password(
    body: ForgotPasswordRequest, request: Request, db: Session = Depends(get_db)
) -> SignupPending:
    """Manda um código para quem esqueceu a senha.

    **Responde igual exista a conta ou não.** É a decisão que separa esta rota
    do cadastro, onde dizer "e-mail já cadastrado" é necessário e esperado. Aqui
    a diferença viraria um oráculo: um estranho digitaria endereços em sequência
    e descobriria quais têm conta no Deskside. Como cada conta é um computador,
    essa lista tem valor para quem a coletasse.

    Por isso, quando o contato não existe: nada é criado, nada é enviado, e a
    resposta é a mesma — inclusive o tempo até poder pedir de novo.
    """
    # O limite entra **antes** da busca, e por isso ele também é igual para conta
    # que existe e conta que não existe. Cobrar só quando a conta existe daria de
    # volta, pela porta dos fundos, o oráculo que esta rota inteira foi escrita
    # para fechar: o 429 apareceria só nos endereços cadastrados.
    limite.cobrar_envio(limite.ip_do_pedido(request))

    destino, canal = _destino(body)
    coluna = User.email if canal == "email" else User.phone
    user = db.scalar(select(User).where(coluna == destino))

    resposta = SignupPending(
        destination=destino,
        channel=canal,
        resend_in_seconds=int(verificacao.ESPERA_REENVIO.total_seconds()),
        delivered=entrega.configurado()["email" if canal == "email" else "sms"],
    )
    if user is None:
        return resposta

    anterior = db.scalar(select(PasswordReset).where(PasswordReset.destino == destino))
    agora = datetime.now(UTC)
    if anterior is not None:
        # Pedir de novo antes da hora não gasta envio. Sem isto, o botão de
        # "reenviar" apertado dez vezes seriam dez SMS pagos.
        if not verificacao.pode_reenviar(anterior.last_sent_at):
            raise _erro(
                status.HTTP_429_TOO_MANY_REQUESTS,
                f"espere {verificacao.segundos_para_reenviar(anterior.last_sent_at)}s "
                "para pedir outro código",
            )
        db.delete(anterior)
        db.flush()

    codigo = verificacao.gerar()
    db.add(
        PasswordReset(
            user_id=user.id,
            destino=destino,
            canal=canal,
            hashed_code=verificacao.resumo(codigo),
            expires_at=verificacao.prazo(agora),
            last_sent_at=agora,
        )
    )
    db.commit()
    _enviar(destino, canal, codigo)
    return resposta


@router.post("/password/reset", response_model=TokenPair)
def reset_password(
    body: ResetPasswordRequest,
    request: Request,
    tarefas: BackgroundTasks,
    db: Session = Depends(get_db),
) -> TokenPair:
    """Confere o código e troca a senha, devolvendo a sessão já aberta.

    Entrar direto, em vez de mandar de volta ao login, é deliberado: quem
    acabou de provar posse do contato **e** escolher uma senha nova já fez tudo
    o que o login pediria, e a senha recém-criada é a que mais se esquece se a
    pessoa tiver de digitá-la de novo no minuto seguinte.
    """
    faltando = politica_de_senha.problemas(body.password)
    if faltando:
        raise _erro(
            status.HTTP_400_BAD_REQUEST, "a senha precisa de: " + ", ".join(faltando)
        )

    pedido = db.scalar(
        select(PasswordReset).where(
            PasswordReset.destino == body.destination.strip().lower()
        )
    )
    if pedido is None:
        raise _erro(
            status.HTTP_404_NOT_FOUND, "não há recuperação em andamento para este contato"
        )

    if verificacao.expirou(pedido.expires_at):
        db.delete(pedido)
        db.commit()
        raise _erro(status.HTTP_410_GONE, "o código expirou; peça outro")

    if not verificacao.confere(body.code.strip(), pedido.hashed_code):
        pedido.attempts += 1
        restantes = verificacao.MAX_TENTATIVAS - pedido.attempts
        if restantes <= 0:
            db.delete(pedido)
            db.commit()
            raise _erro(
                status.HTTP_429_TOO_MANY_REQUESTS,
                "tentativas demais; peça a recuperação de novo",
            )
        db.commit()
        raise _erro(
            status.HTTP_401_UNAUTHORIZED,
            f"código incorreto ({restantes} tentativa"
            f"{'s' if restantes > 1 else ''} restante"
            f"{'s' if restantes > 1 else ''})",
        )

    user = db.get(User, pedido.user_id)
    if user is None:
        # A conta foi excluída entre pedir e usar o código.
        db.delete(pedido)
        db.commit()
        raise _erro(status.HTTP_404_NOT_FOUND, "conta não encontrada")

    # Com a verificação em duas etapas ligada, o código do e-mail ou do SMS
    # **não basta**. Sem esta conferência, tomar o e-mail ou clonar o chip da
    # pessoa abria a conta mesmo com a verificação ligada — e a conta abre os
    # computadores dela. O pedido continua de pé enquanto o código não vem, e
    # um código errado conta nas mesmas tentativas do código do e-mail.
    tipo = None
    if user.totp_enabled:
        if not body.totp_code:
            raise _erro(status.HTTP_401_UNAUTHORIZED, segundo_fator.FALTA_CODIGO)
        tipo = segundo_fator.confere(user, body.totp_code)
        if tipo is None:
            pedido.attempts += 1
            if pedido.attempts >= verificacao.MAX_TENTATIVAS:
                db.delete(pedido)
                db.commit()
                raise _erro(
                    status.HTTP_429_TOO_MANY_REQUESTS,
                    "tentativas demais; peça a recuperação de novo",
                )
            db.commit()
            raise _erro(status.HTTP_401_UNAUTHORIZED, segundo_fator.CODIGO_ERRADO)

    user.hashed_password = hash_password(body.password)
    # Aqui a derrubada das sessões vale ainda mais do que na troca comum: quem
    # usa "esqueci minha senha" ou perdeu o acesso ou desconfia que alguém o
    # tem. Trocar a senha e deixar de pé o token de quem entrou seria trocar a
    # fechadura sem recolher a cópia da chave.
    user.token_key = nova_chave_de_sessao()
    # Todo pedido em aberto dessa conta cai junto, e não só o que foi usado: se
    # havia dois códigos válidos, o segundo continuaria trocando a senha depois.
    for aberto in db.scalars(
        select(PasswordReset).where(PasswordReset.user_id == user.id)
    ).all():
        db.delete(aberto)
    sessoes.encerrar_todas(db, user)
    db.commit()
    db.refresh(user)
    ip = limite.ip_do_pedido(request)
    tarefas.add_task(alertas.enviar, alertas.montar(user, "senha_redefinida", ip=ip))
    _avisar_codigo_usado(tarefas, user, tipo, ip)
    return _entrar(db, user, request)


@router.post("/login", response_model=TokenPair)
def login(
    body: Credentials,
    request: Request,
    tarefas: BackgroundTasks,
    db: Session = Depends(get_db),
) -> TokenPair:
    destino, canal = _destino(body)
    ip = limite.ip_do_pedido(request)
    # **Antes** de tocar no banco e no bcrypt. Cobrar depois de conferir a senha
    # deixaria metade do problema de pé: o hash é caro de propósito, e uma
    # varredura que chega até ele já consumiu a CPU do servidor mesmo sendo
    # recusada no passo seguinte.
    limite.cobrar_login(destino, ip)

    coluna = User.email if canal == "email" else User.phone
    user = db.scalar(select(User).where(coluna == destino))
    if user is None:
        # O mesmo bcrypt de uma conta que existe, para o tempo de resposta não
        # contar o que a mensagem esconde.
        verify_password(body.password, _hash_falso())
    if user is None or not verify_password(body.password, user.hashed_password):
        limite.punir_login(destino, ip)
        # Uma mensagem só para "não existe" e "senha errada": distinguir as duas
        # diria a um estranho quais contas existem.
        raise HTTPException(
            status_code=status.HTTP_401_UNAUTHORIZED,
            detail="e-mail, telefone ou senha inválidos",
        )
    # 2FA: com a senha correta, ainda exige o código do autenticador (ou um de
    # recuperação). O app reconhece os detalhes "two_factor_required" e
    # "two_factor_invalid".
    #
    # Um erro aqui conta como falha, e importa mais que no erro de senha: quem
    # chegou até este ponto **já tem a senha certa**. Sem contabilizar, o
    # segundo fator seriam seis dígitos com tentativas infinitas — um milhão de
    # combinações que um laço percorre numa tarde.
    tipo = segundo_fator.exigir(
        user, body.totp_code, ao_errar=lambda: limite.punir_login(destino, ip)
    )
    limite.perdoar_login(destino, ip)
    # O código aceito muda a conta (o passo usado, ou o código de recuperação
    # que deixa de existir).
    tokens = _entrar(db, user, request)
    tarefas.add_task(
        alertas.enviar,
        alertas.montar(user, "login", ip=ip, detalhe=sessoes.nome_do_aparelho(request)),
    )
    _avisar_codigo_usado(tarefas, user, tipo, ip)
    return tokens


@router.post(
    "/refresh",
    response_model=AccessToken,
    response_model_exclude_none=True,
    responses={401: {"description": "refresh token inválido"}},
)
def refresh(
    body: RefreshRequest,
    request: Request,
    tarefas: BackgroundTasks,
    db: Session = Depends(get_db),
) -> AccessToken | JSONResponse:
    """Um access token novo e, para o app que pede (`rotacao`), um refresh novo.

    O refresh usado deixa de valer quando o novo sai. Ver `app/sessoes.py`.
    """
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
    # O ponto que decide: é o refresh que dura 30 dias, e é ele que mantinha a
    # sessão viva depois da troca de senha renovando o access a cada hora.
    if not chave_confere(payload, user.token_key):
        raise invalid
    try:
        renovada = sessoes.renovar(
            db, user, payload, body.refresh_token, body.rotacao, request
        )
    except sessoes.Copiada as copia:
        # O mesmo refresh nas mãos de dois: não há como saber qual é o dono,
        # então a sessão cai para os dois e o dono fica sabendo. Ele entra de
        # novo; quem copiou, não.
        sessoes.encerrar(copia.sessao)
        db.commit()
        # O aviso vai junto da resposta de erro: as tarefas de um `raise`
        # nunca rodam no FastAPI.
        tarefas.add_task(
            alertas.enviar,
            alertas.montar(
                user,
                "sessao_copiada",
                ip=limite.ip_do_pedido(request),
                detalhe=copia.sessao.aparelho,
            ),
        )
        return JSONResponse(
            status_code=status.HTTP_401_UNAUTHORIZED,
            content={"detail": invalid.detail},
            background=tarefas,
        )
    if renovada is None:
        raise invalid
    sessao, geracao = renovada
    db.commit()
    subject = str(user.id)
    return AccessToken(
        access_token=create_access_token(subject, user.token_key, sessao.id),
        refresh_token=None
        if geracao is None
        else create_refresh_token(subject, user.token_key, sessao.id, geracao),
    )


@router.get("/me", response_model=UserOut)
def me(
    current_user: User = Depends(get_current_user),
    db: Session = Depends(get_db),
) -> UserOut:
    """A conta, com o plano **efetivo** — não o rótulo guardado.

    Uma conta com `plano="pago"` e prazo vencido está no grátis. Devolver o
    rótulo cru faria o app oferecer recursos que o servidor recusaria em
    seguida, e uma tela que promete o que o servidor nega é pior que uma tela
    que não promete nada.

    Vai junto `em_teste`, que o app não consegue deduzir sozinho: teste e
    assinatura chegam os dois como `pago` com trinta dias. Sem isto, toda tela
    que mostra o plano precisaria de uma segunda chamada só para saber se a
    contagem que ela exibe é um convite ou um susto.
    """
    saida = UserOut.model_validate(current_user)
    saida.recovery_codes_left = segundo_fator.restantes(current_user)
    saida.plano = cobranca.plano_de(current_user)
    saida.em_teste, saida.renova = cobranca.situacao_de(db, current_user)
    return saida


# --- aparelhos conectados -------------------------------------------------------


@router.get("/sessions", response_model=list[SessaoOut])
def list_sessions(
    request: Request,
    current_user: User = Depends(get_current_user),
    db: Session = Depends(get_db),
) -> list[SessaoOut]:
    """Os aparelhos com a conta aberta, do uso mais recente para o mais antigo."""
    atual = getattr(request.state, "sid", None)
    return [
        SessaoOut(
            id=s.id,
            aparelho=s.aparelho,
            # Com fuso: o SQLite devolve sem, e o app leria como hora local.
            criada_em=sessoes.utc(s.criada_em),
            ultimo_uso=sessoes.utc(s.ultimo_uso),
            atual=s.id == atual,
        )
        for s in sessoes.abertas(db, current_user)
    ]


@router.delete("/sessions/{sessao_id}", status_code=status.HTTP_204_NO_CONTENT)
def end_session(
    sessao_id: str,
    current_user: User = Depends(get_current_user),
    db: Session = Depends(get_db),
) -> None:
    """Encerra a sessão de um aparelho. Ele cai na próxima requisição."""
    sessao = db.get(Sessao, sessao_id)
    if not sessoes.ativa(sessao, current_user):
        raise _erro(status.HTTP_404_NOT_FOUND, "sessão não encontrada")
    sessoes.encerrar(sessao)
    db.commit()


@router.post("/sessions/revoke-others", response_model=TokenPair)
def end_other_sessions(
    request: Request,
    current_user: User = Depends(get_current_user),
    db: Session = Depends(get_db),
) -> TokenPair:
    """Encerra todas as sessões menos a de quem pede.

    Troca também a `token_key`, como a troca de senha: é o que derruba os
    tokens de antes das sessões, que não têm uma para encerrar. Por isso
    devolve tokens novos para este aparelho.
    """
    current_user.token_key = nova_chave_de_sessao()
    sessao = _sessao_de_quem_pede(db, current_user, request)
    sessoes.encerrar_todas(db, current_user, menos=sessao.id)
    db.commit()
    db.refresh(current_user)
    return _tokens_for(current_user, sessao)


@router.post("/logout", status_code=status.HTTP_204_NO_CONTENT)
def logout(
    request: Request,
    current_user: User = Depends(get_current_user),
    db: Session = Depends(get_db),
) -> None:
    """Encerra a sessão deste aparelho no servidor.

    Antes, sair só apagava os tokens do celular: o refresh continuava valendo
    por 30 dias para quem tivesse uma cópia.
    """
    sid = getattr(request.state, "sid", None)
    sessao = db.get(Sessao, sid) if sid else None
    if sessao is not None and sessao.user_id == current_user.id:
        sessoes.encerrar(sessao)
        db.commit()


# --- trocar o contato da conta ------------------------------------------------
#
# Três rotas onde antes havia dois `PATCH` que trocavam na hora. A troca imediata
# abria dois buracos de uma vez: apontar a conta para um endereço que não é seu —
# e perdê-la —, e **ocupar aquele contato** na restrição de unicidade, impedindo
# que o dono real se cadastrasse. É o mesmo buraco que o cadastro em duas etapas
# fechou do outro lado, e ele continuava aberto por aqui.
#
# Os `PATCH /me/email` e `PATCH /me/phone` **saíram**. Enquanto existissem, o
# código seria decoração: bastaria chamar a rota velha para trocar sem provar
# nada. Há um teste guardando a porta fechada, porque reabri-la por engano não
# quebraria mais nada.


def _troca_pendente(db: Session, user: User) -> PendingContactChange:
    achada = db.scalar(
        select(PendingContactChange).where(PendingContactChange.user_id == user.id)
    )
    if achada is None:
        raise _erro(status.HTTP_404_NOT_FOUND, "não há troca de contato em andamento")
    return achada


def _resposta_de_codigo(destino: str, canal: str, entregue: bool) -> SignupPending:
    return SignupPending(
        destination=destino,
        channel=canal,
        resend_in_seconds=int(verificacao.ESPERA_REENVIO.total_seconds()),
        delivered=entregue,
    )


@router.post("/me/contact/start", response_model=SignupPending)
def contact_change_start(
    body: ContactChangeStart,
    request: Request,
    current_user: User = Depends(get_current_user),
    db: Session = Depends(get_db),
) -> SignupPending:
    """Manda um código para o contato **novo**. Nada muda na conta ainda.

    Pede a senha **e** o segundo fator: trocar o contato é o passo que tira a
    conta do dono de vez, porque a recuperação de senha passa a ir para o
    endereço novo.
    """
    if not verify_password(body.current_password, current_user.hashed_password):
        raise _erro(status.HTTP_401_UNAUTHORIZED, "senha atual incorreta")
    _exigir_segundo_fator(current_user, body.totp_code, request)

    # O telefone passa pela **mesma normalização** do cadastro (dentro do
    # `_destino`). Sem isso, gravar "(11) 98765-4321" produziria uma forma que o
    # login — que normaliza — nunca encontraria: a pessoa trocaria o número e
    # ficaria fora da própria conta sem entender por quê.
    destino, canal = _destino(body)
    if destino in (current_user.email, current_user.phone):
        raise _erro(status.HTTP_400_BAD_REQUEST, "este já é o contato da conta")
    _livre(db, destino, canal)

    anterior = db.scalar(
        select(PendingContactChange).where(
            PendingContactChange.user_id == current_user.id
        )
    )
    agora = datetime.now(UTC)
    if anterior is not None:
        # A espera vale para o **mesmo** destino, que é o caso de apertar
        # "enviar" de novo. Trocar de destino é o caso de ter digitado errado, e
        # fazer esperar um minuto para corrigir um erro de digitação seria
        # castigo sem ganho nenhum.
        if anterior.destino == destino and not verificacao.pode_reenviar(
            anterior.last_sent_at
        ):
            raise _erro(
                status.HTTP_429_TOO_MANY_REQUESTS,
                f"espere {verificacao.segundos_para_reenviar(anterior.last_sent_at)}s "
                "para pedir outro código",
            )
        db.delete(anterior)
        db.flush()

    codigo = verificacao.gerar()
    db.add(
        PendingContactChange(
            user_id=current_user.id,
            destino=destino,
            canal=canal,
            hashed_code=verificacao.resumo(codigo),
            expires_at=verificacao.prazo(agora),
            last_sent_at=agora,
        )
    )
    db.commit()

    return _resposta_de_codigo(destino, canal, _enviar(destino, canal, codigo))


@router.post("/me/contact/resend", response_model=SignupPending)
def contact_change_resend(
    current_user: User = Depends(get_current_user),
    db: Session = Depends(get_db),
) -> SignupPending:
    """Outro código para a mesma troca, com prazo novo e tentativas zeradas.

    Sem corpo: qual troca reenviar sai do token. Zerar as tentativas é o certo —
    elas contam contra *aquele* código, e o que a pessoa vai digitar é outro.
    """
    pendente = _troca_pendente(db, current_user)
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

    return _resposta_de_codigo(
        pendente.destino,
        pendente.canal,
        _enviar(pendente.destino, pendente.canal, codigo),
    )


@router.post("/me/contact/verify", response_model=UserOut)
def contact_change_verify(
    body: ContactChangeVerify,
    tarefas: BackgroundTasks,
    current_user: User = Depends(get_current_user),
    db: Session = Depends(get_db),
) -> User:
    """Confere o código e **aí sim** troca o contato da conta."""
    pendente = _troca_pendente(db, current_user)

    if verificacao.expirou(pendente.expires_at):
        db.delete(pendente)
        db.commit()
        raise _erro(status.HTTP_410_GONE, "o código expirou; peça outro")

    if not verificacao.confere(body.code.strip(), pendente.hashed_code):
        pendente.attempts += 1
        restantes = verificacao.MAX_TENTATIVAS - pendente.attempts
        if restantes <= 0:
            # Descarta a troca inteira, e não só o código: seis dígitos com
            # tentativas infinitas se adivinham, e reaproveitar a mesma pendência
            # com um código novo devolveria as tentativas de graça.
            db.delete(pendente)
            db.commit()
            raise _erro(
                status.HTTP_429_TOO_MANY_REQUESTS,
                "tentativas demais; recomece a troca",
            )
        db.commit()
        raise _erro(
            status.HTTP_401_UNAUTHORIZED,
            f"código incorreto ({restantes} tentativa"
            f"{'s' if restantes > 1 else ''} restante"
            f"{'s' if restantes > 1 else ''})",
        )

    # Entre começar e confirmar, alguém pode ter ficado com o contato — inclusive
    # outra pessoa que tinha a mesma troca pendente. Sem esta conferência o
    # `commit` estouraria a unicidade e viraria um 500.
    _livre(db, pendente.destino, pendente.canal)

    # O aviso vai para o contato **antigo**: se quem trocou foi um invasor, o
    # novo é dele, e o antigo é o único que o dono ainda lê.
    antigo = alertas.para(current_user)
    aviso = alertas.montar(
        current_user,
        "contato_trocado",
        detalhe=alertas.mascarar(pendente.destino),
        destino=antigo,
    )

    # O contato novo **substitui** o antigo: a conta se identifica por um só, e é
    # por ele que se entra. Deixar os dois preenchidos daria duas formas de login
    # para uma conta que só provou uma delas.
    if pendente.canal == "email":
        current_user.email = pendente.destino
        current_user.phone = None
    else:
        current_user.phone = pendente.destino
        current_user.email = None

    db.delete(pendente)
    db.commit()
    db.refresh(current_user)
    tarefas.add_task(alertas.enviar, aviso)
    return current_user


@router.patch("/me/password", response_model=TokenPair)
def update_password(
    body: UpdatePasswordRequest,
    request: Request,
    tarefas: BackgroundTasks,
    current_user: User = Depends(get_current_user),
    db: Session = Depends(get_db),
) -> TokenPair:
    """Troca a senha da conta (exige a senha atual) e **derruba as outras sessões**.

    Devolve um par de tokens novo, e não o 204 de antes, por causa da derrubada:
    incrementar a geração cancela todos os tokens da conta, **inclusive o de
    quem está fazendo a troca**. Sem devolver o substituto, a pessoa trocaria a
    senha e seria expulsa do próprio aparelho no momento seguinte — o app
    guarda o novo par e nem percebe que houve corte.

    Quem some são as outras: qualquer sessão aberta em outro celular, tablet ou
    computador para de valer na requisição seguinte, e é isso que se espera de
    trocar a senha por desconfiança.
    """
    if not verify_password(body.current_password, current_user.hashed_password):
        raise HTTPException(
            status_code=status.HTTP_401_UNAUTHORIZED, detail="senha atual incorreta"
        )
    tipo = _exigir_segundo_fator(current_user, body.totp_code, request)
    current_user.hashed_password = hash_password(body.new_password)
    current_user.token_key = nova_chave_de_sessao()
    sessao = _sessao_de_quem_pede(db, current_user, request)
    sessoes.encerrar_todas(db, current_user, menos=sessao.id)
    db.commit()
    db.refresh(current_user)
    ip = limite.ip_do_pedido(request)
    tarefas.add_task(alertas.enviar, alertas.montar(current_user, "senha_trocada", ip=ip))
    _avisar_codigo_usado(tarefas, current_user, tipo, ip)
    return _tokens_for(current_user, sessao)


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
    current_user.totp_secret = cofre.guardar(secret)  # pendente até confirmar
    db.commit()
    return TwoFactorSetupOut(
        secret=secret, otpauth_uri=totp_uri(secret, _rotulo(current_user))
    )


@router.post("/2fa/enable", response_model=None)
def two_factor_enable(
    body: TwoFactorEnableRequest,
    tarefas: BackgroundTasks,
    current_user: User = Depends(get_current_user),
    db: Session = Depends(get_db),
) -> Response | RecoveryCodesOut:
    """Ativa o 2FA confirmando um código do autenticador.

    Com `recovery_codes: true` (o app novo sempre manda), devolve os dez códigos
    de recuperação. Sem, responde 204 como antes — o app que já está nos
    celulares confere esse 204, e quebrá-lo seria quebrar a ativação para quem
    ainda não atualizou.
    """
    if current_user.totp_enabled:
        raise HTTPException(
            status_code=status.HTTP_409_CONFLICT, detail="2FA já está ativo"
        )
    if not current_user.totp_secret:
        raise HTTPException(
            status_code=status.HTTP_400_BAD_REQUEST,
            detail="inicie a configuração do 2FA antes",
        )
    if segundo_fator.confere(current_user, body.code) != "totp":
        raise HTTPException(
            status_code=status.HTTP_401_UNAUTHORIZED, detail="código inválido"
        )
    current_user.totp_enabled = True
    codigos = segundo_fator.gerar_codigos(current_user) if body.recovery_codes else None
    db.commit()
    tarefas.add_task(alertas.enviar, alertas.montar(current_user, "2fa_ligado"))
    if codigos is None:
        return Response(status_code=status.HTTP_204_NO_CONTENT)
    return RecoveryCodesOut(codes=codigos)


@router.post("/2fa/recovery-codes", response_model=RecoveryCodesOut)
def recovery_codes(
    body: RecoveryCodesRequest,
    request: Request,
    tarefas: BackgroundTasks,
    current_user: User = Depends(get_current_user),
    db: Session = Depends(get_db),
) -> RecoveryCodesOut:
    """Gera códigos de recuperação novos; os anteriores param de valer."""
    if not current_user.totp_enabled:
        raise _erro(status.HTTP_409_CONFLICT, "ligue a verificação em duas etapas antes")
    _exigir_segundo_fator(current_user, body.totp_code, request)
    codigos = segundo_fator.gerar_codigos(current_user)
    db.commit()
    tarefas.add_task(alertas.enviar, alertas.montar(current_user, "codigos_novos"))
    return RecoveryCodesOut(codes=codigos)


@router.post("/2fa/disable", status_code=status.HTTP_204_NO_CONTENT)
def two_factor_disable(
    body: TwoFactorDisableRequest,
    request: Request,
    tarefas: BackgroundTasks,
    current_user: User = Depends(get_current_user),
    db: Session = Depends(get_db),
) -> None:
    """Desativa o 2FA e apaga o segredo e os códigos de recuperação.

    Exige a senha **e** o código: com só a senha, quem tivesse o celular
    desbloqueado da pessoa desligaria a proteção que existe justamente para
    quando a senha vaza.
    """
    if not verify_password(body.password, current_user.hashed_password):
        raise HTTPException(
            status_code=status.HTTP_401_UNAUTHORIZED, detail="senha incorreta"
        )
    _exigir_segundo_fator(current_user, body.totp_code, request)
    current_user.totp_enabled = False
    current_user.totp_secret = None
    current_user.totp_ultimo_passo = None
    current_user.recovery_codes = "[]"
    db.commit()
    tarefas.add_task(
        alertas.enviar,
        alertas.montar(current_user, "2fa_desligado", ip=limite.ip_do_pedido(request)),
    )


@router.delete("/me", status_code=status.HTTP_204_NO_CONTENT)
def delete_account(
    body: DeleteAccountRequest,
    request: Request,
    current_user: User = Depends(get_current_user),
    db: Session = Depends(get_db),
) -> None:
    """Exclui a conta e todos os dispositivos vinculados (senha e, se ligada, a
    verificação em duas etapas)."""
    if not verify_password(body.password, current_user.hashed_password):
        raise HTTPException(
            status_code=status.HTTP_401_UNAUTHORIZED, detail="senha incorreta"
        )
    _exigir_segundo_fator(current_user, body.totp_code, request)
    db.delete(current_user)
    db.commit()
