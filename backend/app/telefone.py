"""Números de telefone: o código do país, a limpeza e a validação.

Pura e testável. A mesma tabela existe no app (`client/lib/models/pais.dart`),
porque é ela que desenha o seletor de país — e ter a lista só no servidor
obrigaria o app a buscá-la pela rede antes de mostrar um formulário.

**Por que uma tabela à mão e não a `libphonenumber`.** A biblioteca do Google é
a resposta certa para quem precisa formatar, classificar (fixo/móvel) e validar
faixas de numeração de 240 países. Aqui o que se precisa é bem menos: saber que
o número tem a cara certa antes de gastar um SMS com ele. Uma tabela de trinta
países com o intervalo de dígitos faz isso, cabe numa tela, e é a mesma nos dois
lados sem uma dependência nativa a mais no iOS. Quando o produto for vendido
fora desta lista, é aqui que se troca.
"""

from dataclasses import dataclass

#: O que separa "o número não existe" de "o número não foi digitado direito".
#: Nenhum país tem número nacional com menos de 4 dígitos nem mais de 15 — o
#: E.164 limita o total (país + nacional) a 15.
E164_MAXIMO = 15


@dataclass(frozen=True)
class Pais:
    """Um país no seletor: a bandeira, o código de discagem e o tamanho aceito.

    `minimo`/`maximo` são o número **nacional**, sem o código do país e sem o
    zero de tronco (o `0` que se disca antes do DDD dentro do Brasil).
    """

    iso: str
    nome: str
    ddi: str
    minimo: int
    maximo: int

    @property
    def bandeira(self) -> str:
        """A bandeira como emoji, derivada do ISO em vez de guardada.

        Cada letra vira o "indicador regional" correspondente; o par forma a
        bandeira. Guardar o emoji na tabela seria guardar o que já está no
        código do país.
        """
        return "".join(chr(0x1F1E6 + ord(c) - ord("A")) for c in self.iso)


#: Os países atendidos, com o Brasil na frente por ser o mercado inicial.
#:
#: O intervalo de dígitos é o do número nacional. O Brasil aceita 10 e 11
#: porque fixo tem 10 (DDD + 8) e celular tem 11 (DDD + 9 dígitos, com o nono
#: dígito) — e um cadastro que só aceitasse 11 recusaria um telefone fixo
#: legítimo.
PAISES: list[Pais] = [
    Pais("BR", "Brasil", "55", 10, 11),
    Pais("PT", "Portugal", "351", 9, 9),
    Pais("US", "Estados Unidos", "1", 10, 10),
    Pais("CA", "Canadá", "1", 10, 10),
    Pais("AR", "Argentina", "54", 10, 11),
    Pais("CL", "Chile", "56", 9, 9),
    Pais("CO", "Colômbia", "57", 10, 10),
    Pais("MX", "México", "52", 10, 10),
    Pais("PY", "Paraguai", "595", 9, 9),
    Pais("PE", "Peru", "51", 9, 9),
    Pais("UY", "Uruguai", "598", 8, 9),
    Pais("BO", "Bolívia", "591", 8, 8),
    Pais("ES", "Espanha", "34", 9, 9),
    Pais("FR", "França", "33", 9, 9),
    Pais("IT", "Itália", "39", 9, 11),
    Pais("DE", "Alemanha", "49", 10, 11),
    Pais("GB", "Reino Unido", "44", 10, 10),
    Pais("IE", "Irlanda", "353", 9, 9),
    Pais("NL", "Países Baixos", "31", 9, 9),
    Pais("BE", "Bélgica", "32", 9, 9),
    Pais("CH", "Suíça", "41", 9, 9),
    Pais("AT", "Áustria", "43", 10, 13),
    Pais("SE", "Suécia", "46", 9, 9),
    Pais("NO", "Noruega", "47", 8, 8),
    Pais("DK", "Dinamarca", "45", 8, 8),
    Pais("FI", "Finlândia", "358", 9, 10),
    Pais("PL", "Polônia", "48", 9, 9),
    Pais("JP", "Japão", "81", 10, 10),
    Pais("AU", "Austrália", "61", 9, 9),
    Pais("NZ", "Nova Zelândia", "64", 8, 10),
    Pais("ZA", "África do Sul", "27", 9, 9),
    Pais("AO", "Angola", "244", 9, 9),
    Pais("MZ", "Moçambique", "258", 9, 9),
]

_POR_ISO = {p.iso: p for p in PAISES}


def pais(iso: str) -> Pais | None:
    return _POR_ISO.get((iso or "").strip().upper())


def so_digitos(bruto: str) -> str:
    """Fica só com os algarismos.

    Espaço, parêntese, hífen, ponto e o `+` são enfeite de leitura — quem digita
    "(11) 98765-4321" quer o mesmo número de quem digita "11987654321", e
    recusar um dos dois seria recusar por causa da pontuação.
    """
    return "".join(c for c in (bruto or "") if c.isdigit())


def normalizar(bruto: str, iso: str) -> str | None:
    """O número em E.164 (`+5511987654321`), ou `None` se não parece um número.

    O que ela resolve, além de tirar a pontuação:

    - **O zero de tronco.** Dentro do Brasil se disca `0` antes do DDD, e muita
      gente escreve `011 98765-4321`. Esse zero não existe no número
      internacional, e mandá-lo junto daria um destino inexistente.
    - **O código do país digitado junto.** Quem escreve `+55 11 98765-4321` com
      o Brasil escolhido no seletor não quer `+55 55 11...`.
    """
    p = pais(iso)
    if p is None:
        return None

    digitos = so_digitos(bruto)
    if not digitos:
        return None

    # O DDI já veio digitado: tira, mas só se o que sobra ainda for um número
    # possível. Sem essa checagem, um número que por acaso começa com os
    # mesmos dígitos do país seria mutilado - o `55` do Brasil é o começo
    # legítimo de um DDD 55 (Rio Grande do Sul).
    if digitos.startswith(p.ddi):
        resto = digitos[len(p.ddi) :]
        if p.minimo <= len(resto) <= p.maximo:
            digitos = resto

    # O zero de tronco, pelo mesmo cuidado: só sai se o que sobra couber.
    if digitos.startswith("0"):
        resto = digitos.lstrip("0")
        if p.minimo <= len(resto) <= p.maximo:
            digitos = resto

    if not (p.minimo <= len(digitos) <= p.maximo):
        return None
    e164 = f"+{p.ddi}{digitos}"
    if len(e164) - 1 > E164_MAXIMO:
        return None
    return e164


def valido(bruto: str, iso: str) -> bool:
    return normalizar(bruto, iso) is not None
