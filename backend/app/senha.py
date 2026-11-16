"""A política de senha, em um lugar só.

Pura e sem dependência de nada: é chamada pelo cadastro, pela troca de senha, e
os testes a exercitam direto. As mesmas cinco regras existem no app, em
`client/lib/services/senha.dart`, porque a pessoa precisa ver o que falta
**enquanto digita** — mandar ao servidor para descobrir que faltava um número
seria uma viagem para dizer o óbvio.

Duas cópias da mesma regra é uma fonte de verdade a mais do que se gostaria, e
aqui vale: a do servidor é a que **decide** (o app pode ser adulterado, ou
simplesmente estar velho), a do app é a que **explica**. Se elas divergirem, o
servidor recusa e o app mostra o motivo que veio de lá.
"""

import re

#: O piso de tamanho. Oito é o mínimo de qualquer recomendação atual, e este
#: produto guarda a chave de um computador inteiro.
TAMANHO_MINIMO = 8

#: Teto. Não é aperto: o bcrypt trunca em 72 **bytes**, e uma senha maior que
#: isso seria silenciosamente cortada — duas senhas diferentes passariam a abrir
#: a mesma conta. Recusar é melhor que truncar em silêncio.
TAMANHO_MAXIMO = 72

#: O que conta como caractere especial: tudo que não é letra nem número.
#: Definir por exclusão, e não por uma lista de símbolos, evita a pergunta "o
#: `ç` conta?" e aceita o que qualquer teclado do mundo produz.
_ESPECIAL = re.compile(r"[^A-Za-z0-9]")


def problemas(senha: str) -> list[str]:
    """As regras que esta senha ainda não cumpre, na ordem em que se mostram.

    Devolve uma lista, e não o primeiro erro: quem está criando uma senha quer
    ver a lista inteira de uma vez. Um formulário que revela uma exigência por
    vez faz a pessoa tentar cinco vezes para descobrir cinco regras.
    """
    faltando: list[str] = []
    if len(senha) < TAMANHO_MINIMO:
        faltando.append(f"pelo menos {TAMANHO_MINIMO} caracteres")
    if not any(c.isupper() for c in senha):
        faltando.append("uma letra maiúscula")
    if not any(c.islower() for c in senha):
        faltando.append("uma letra minúscula")
    if not any(c.isdigit() for c in senha):
        faltando.append("um número")
    if not _ESPECIAL.search(senha):
        faltando.append("um caractere especial")
    # Depois das cinco: o teto não é uma regra que a pessoa "cumpre", é um
    # limite técnico, e por isso vem por último e com outra redação.
    if len(senha.encode("utf-8")) > TAMANHO_MAXIMO:
        faltando.append(f"no máximo {TAMANHO_MAXIMO} caracteres")
    return faltando


def valida(senha: str) -> bool:
    return not problemas(senha)
