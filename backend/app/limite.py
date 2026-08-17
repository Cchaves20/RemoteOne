"""Limite de tentativas nos caminhos que ninguém precisa estar logado para usar.

Três endpoints são abertos por natureza — `/login`, `/signup/start` e
`/password/forgot` — e cada um paga um preço por tentativa:

- **`/login` gasta um bcrypt.** O hash é caro *de propósito*, e isso corta nos
  dois sentidos: encarece a adivinhação de senha e faz do login o jeito mais
  barato de consumir a CPU do servidor. Não é preciso nem acertar a senha; basta
  tentar. Num servidor de camada gratuita, isso derruba o serviço para todos.
- **`/signup/start` e `/password/forgot` gastam uma entrega.** SMS custa
  dinheiro, e um laço nesses dois é ao mesmo tempo uma conta a pagar e um jeito
  de encher de mensagens o telefone de outra pessoa.

## Por identificador **e** por IP

Os dois, porque cada um sozinho tem um furo grande:

- **Só por IP**: quem tem uma botnet ou uma lista de proxies tenta a mesma senha
  em mil contas, um endereço por tentativa, e nada dispara.
- **Só por conta**: qualquer pessoa tranca a sua conta de propósito. É um jeito
  de negar serviço com dez requisições.

## Espera crescente, e não conta trancada

Trancar a conta entrega ao atacante exatamente o que ele quer: você fora dela.
Aqui a conta nunca fica indisponível — o que cresce é a **espera** entre
tentativas, e ela desaparece sozinha. Cinco erros seguidos custam meio minuto;
insistir custa mais, até um teto. Quem errou a senha de verdade espera trinta
segundos uma vez; quem está varrendo senhas leva séculos.

O limite por IP é **muito** mais folgado que o por conta, e isso não é descuido:
celular em rede móvel compartilha um punhado de IPs entre milhares de pessoas
(NAT da operadora). Um limite por IP apertado tiraria do ar bairros inteiros por
causa de um vizinho que errou a senha.

## Sem sono do lado do servidor

A resposta é 429 com `Retry-After`, e **não** uma requisição que dorme. Dormir
seria dar ao atacante o que ele buscava: cada tentativa passaria a segurar uma
conexão e uma tarefa do servidor, e o limite viraria a própria arma.

## Em memória, e por que basta

O contador vive no processo. O servidor roda com um trabalhador só (ver o
`Dockerfile`), então não há estado dividido a sincronizar, e reiniciar zera as
contagens — o que é aceitável porque reiniciar não está nas mãos de quem ataca.
Se um dia houver mais de um trabalhador, isto precisa virar Redis, e este
parágrafo é o aviso.
"""

import time
from dataclasses import dataclass, field

#: Erros seguidos que uma **conta** aguenta antes de a espera começar.
#:
#: Cinco porque errar a senha três ou quatro vezes é rotina de gente que tem
#: várias senhas parecidas, e punir isso seria punir o dono da conta.
LIMIAR_CONTA = 5

#: Erros seguidos vindos do **mesmo IP** antes de a espera começar.
#:
#: Muito mais alto, e de propósito: em rede móvel, milhares de pessoas
#: compartilham um punhado de endereços. Apertar aqui tiraria do ar quem nunca
#: errou nada.
LIMIAR_IP = 40

#: Depois de quanto tempo sem tentativa a contagem é esquecida.
#:
#: Sem esse esquecimento, um erro hoje somaria com um erro no mês que vem, e a
#: pessoa acabaria em espera longa sem ter feito nada de errado.
JANELA_SEGUNDOS = 15 * 60

#: A primeira espera, e o teto dela.
#:
#: Trinta segundos é o bastante para tornar a varredura inviável e curto o
#: bastante para quem só errou a senha não achar que o app travou. O teto existe
#: para a espera não crescer até virar, na prática, uma conta trancada.
ESPERA_INICIAL = 30
ESPERA_MAXIMA = 15 * 60


def espera_apos(falhas: int, limiar: int) -> int:
    """Quantos segundos esperar depois de `falhas` erros. Zero = pode tentar.

    Dobra a cada erro além do limiar. Dobrar e não somar porque a diferença
    aparece exatamente onde importa: somando, cem tentativas custariam meia hora
    ao atacante; dobrando, as primeiras dez já o levam ao teto e o resto do dia
    rende oito tentativas.
    """
    excedentes = falhas - limiar
    if excedentes < 0:
        return 0
    return min(ESPERA_INICIAL * 2**excedentes, ESPERA_MAXIMA)


@dataclass
class _Contagem:
    falhas: int = 0
    ultima: float = 0.0


@dataclass
class Limitador:
    """Conta falhas por chave e diz quanto falta esperar.

    O relógio entra por fora (`agora`) para os testes poderem viajar no tempo.
    Sem isso, verificar "a espera acaba depois de trinta segundos" exigiria um
    teste que dorme trinta segundos — e um teste lento é um teste que alguém
    desliga.
    """

    limiar: int
    #: Teto de chaves guardadas.
    #:
    #: Existe porque a chave vem de fora: mil e um e-mails inventados criariam
    #: mil e uma entradas, e o limite viraria um jeito de consumir a memória do
    #: servidor. Ao encher, o mais antigo sai.
    max_chaves: int = 10_000
    _contagens: dict[str, _Contagem] = field(default_factory=dict)

    def falta_esperar(self, chave: str, agora: float | None = None) -> int:
        """Segundos que ainda faltam para esta chave poder tentar. Zero = já pode."""
        agora = time.monotonic() if agora is None else agora
        c = self._contagens.get(chave)
        if c is None or self._expirou(c, agora):
            return 0
        espera = espera_apos(c.falhas, self.limiar)
        if espera == 0:
            return 0
        restante = c.ultima + espera - agora
        # Arredonda para cima: devolver 0 quando ainda falta meio segundo diria
        # "pode tentar" para quem seria recusado no instante seguinte.
        return max(0, int(restante) + (1 if restante % 1 else 0))

    def registrar_falha(self, chave: str, agora: float | None = None) -> None:
        agora = time.monotonic() if agora is None else agora
        c = self._contagens.get(chave)
        if c is None or self._expirou(c, agora):
            c = _Contagem()
            self._contagens[chave] = c
        c.falhas += 1
        c.ultima = agora
        self._limpar(agora)

    def registrar_acerto(self, chave: str) -> None:
        """Esquece as falhas desta chave.

        Só o acerto zera, e é o que separa "errei a senha e acertei" de "estou
        varrendo senhas": quem acerta volta ao começo, quem só erra acumula.
        """
        self._contagens.pop(chave, None)

    def _expirou(self, c: _Contagem, agora: float) -> bool:
        return agora - c.ultima > JANELA_SEGUNDOS

    def _limpar(self, agora: float) -> None:
        """Joga fora o que expirou; se ainda estiver cheio, o mais antigo sai."""
        if len(self._contagens) <= self.max_chaves:
            return
        for chave in [k for k, c in self._contagens.items() if self._expirou(c, agora)]:
            del self._contagens[chave]
        while len(self._contagens) > self.max_chaves:
            mais_antiga = min(self._contagens, key=lambda k: self._contagens[k].ultima)
            del self._contagens[mais_antiga]


#: Os dois limitadores do processo. Um por dimensão, com limiares diferentes.
por_conta = Limitador(limiar=LIMIAR_CONTA)
por_ip = Limitador(limiar=LIMIAR_IP)


def zerar_tudo() -> None:
    """Esquece todas as contagens. Existe para os testes não vazarem um no outro."""
    por_conta._contagens.clear()
    por_ip._contagens.clear()
    por_ip_envio._contagens.clear()


#: Entregas (SMS/e-mail) partindo do mesmo IP, antes de a espera começar.
#:
#: Separado dos outros dois porque a natureza é outra: em `/login` o que custa é
#: a **falha**, e acertar zera. Em `/signup/start` e `/password/forgot` **toda**
#: requisição custa uma entrega, dê ou não em conta criada — então o que se
#: conta aqui é a requisição, não o erro.
#:
#: Repetir para o *mesmo* destino já era barrado (`verificacao.pode_reenviar`, 60
#: segundos). O que faltava era o outro eixo: um IP varrendo mil telefones
#: diferentes, que é ao mesmo tempo uma conta a pagar e uma máquina de encher o
#: telefone de estranhos.
#:
#: Vinte é um meio: folgado para uma família atrás do mesmo IP, apertado para
#: quem está varrendo. Se algum dia o produto crescer numa rede corporativa, este
#: é o número que vai precisar subir.
LIMIAR_IP_ENVIO = 20

por_ip_envio = Limitador(limiar=LIMIAR_IP_ENVIO)


def ip_do_pedido(request) -> str:
    """O IP de quem pediu, atravessando o proxy.

    Atrás do Caddy, `request.client.host` é sempre o próprio contêiner — usar
    esse valor faria **todo mundo** compartilhar a mesma contagem, e o limite por
    IP viraria um limite global: o primeiro atacante tiraria o serviço do ar para
    todos os outros usuários. O endereço real vem no `X-Forwarded-For`, e o
    primeiro da lista é o cliente.
    """
    encaminhado = request.headers.get("x-forwarded-for")
    if encaminhado:
        return encaminhado.split(",")[0].strip()
    return request.client.host if request.client else "desconhecido"


def _recusar(segundos: int):
    """O 429 com `Retry-After`.

    Cabeçalho **e** texto: o cabeçalho é o que um cliente bem-educado obedece
    sozinho, e o texto é o que a pessoa lê. Sem o texto, o app mostraria "erro
    429" e ninguém saberia que basta esperar.
    """
    from fastapi import HTTPException, status

    minutos = segundos // 60
    quando = f"{minutos} min" if minutos >= 1 else f"{segundos}s"
    return HTTPException(
        status_code=status.HTTP_429_TOO_MANY_REQUESTS,
        detail=f"Muitas tentativas. Tente de novo em {quando}.",
        headers={"Retry-After": str(segundos)},
    )


def cobrar_login(destino: str, ip: str) -> None:
    """Recusa a tentativa de login se ainda há espera pendente.

    A conta primeiro, o IP depois: a espera da conta é a que quase sempre
    dispara, e olhar a mais provável antes deixa a resposta mais direta.
    """
    for chave, limitador in ((destino, por_conta), (ip, por_ip)):
        falta = limitador.falta_esperar(chave)
        if falta > 0:
            raise _recusar(falta)


def punir_login(destino: str, ip: str) -> None:
    """Registra uma senha errada nas duas dimensões."""
    por_conta.registrar_falha(destino)
    por_ip.registrar_falha(ip)


def perdoar_login(destino: str, ip: str) -> None:
    """Zera a contagem da conta que acabou de entrar.

    **A conta, e não o IP.** Zerar o IP daria a quem tem uma conta válida um
    jeito de limpar o próprio orçamento entre rodadas: erra trinta vezes, entra
    na conta que é sua, erra trinta de novo. A conta zera porque quem acertou a
    senha provou ser o dono; o IP continua contando porque a máquina é a mesma.
    """
    por_conta.registrar_acerto(destino)


def cobrar_envio(ip: str) -> None:
    """Recusa — e já contabiliza — um pedido que gasta SMS ou e-mail.

    Contabiliza na hora, e não depois, porque aqui não existe "deu errado": a
    entrega sai de qualquer forma. Esperar por um resultado que não vem deixaria
    o contador sempre em zero, e o limite existiria só no papel.
    """
    falta = por_ip_envio.falta_esperar(ip)
    if falta > 0:
        raise _recusar(falta)
    por_ip_envio.registrar_falha(ip)
