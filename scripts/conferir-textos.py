#!/usr/bin/env python3
"""Confere que toda chamada de `_t(...)` tem exatamente cinco textos.

## Por que isto existe

`_t(pt, en, zh, fr, es)` é a única fonte de textos do app. Um argumento a mais
ou a menos é sempre o mesmo defeito por baixo: **uma string que não fechou.**

E ela quase sempre não fecha pelo mesmo motivo — um apóstrofo dentro de uma
string delimitada por aspas simples, em francês. `'notifications n'apparaissent
pas'` termina a string no `n'`, e o resto da frase vira código: o compilador
passa a procurar um getter chamado `apparaissent`.

Aconteceu duas vezes neste projeto, as duas por edição automatizada. A segunda
foi eu corrigindo a gramática de uma frase em francês com um `sed` que não
escapou o apóstrofo que estava acrescentando.

## Por que não bastam o `flutter analyze` e os testes

Bastam — e pegam. O problema é **onde**: eles rodam no Codemagic, num Mac na
nuvem, seis minutos depois do push, e quem descobre é a pessoa que estava
esperando o build. Este arquivo roda em meio segundo, em qualquer máquina, sem
Flutter instalado. Ele não substitui o `analyze`; ele evita gastar um build para
descobrir o que uma varredura de texto já sabia.

## Uso

    python3 scripts/conferir-textos.py client/lib/l10n/strings.dart

Sai com código 1 quando acha problema, para poder entrar numa corrente de
comandos.
"""

import re
import sys

#: Quantos idiomas o `_t` recebe: pt, en, zh, fr, es.
IDIOMAS = 5


def contar_argumentos(texto: str, i: int) -> tuple[int, int]:
    """Conta os argumentos de um `_t(` cujo parêntese abriu logo antes de `i`.

    Percorre caractere a caractere porque não dá para fazer isto com expressão
    regular: os argumentos são strings que contêm vírgulas, parênteses e
    apóstrofos, e é justamente o caso torto que interessa.

    O detalhe que faz o verificador funcionar: uma string aberta com aspas
    simples **termina na quebra de linha** se ninguém a fechou. É assim que o
    Dart a lê, e imitá-lo é o que transforma "string não fechada" em "argumentos
    demais" — que é um número, e número dá para conferir.
    """
    profundidade = 0
    virgulas = 0
    aspa: str | None = None
    escapando = False
    # `${...}` dentro de string pode ter vírgula e aspas; enquanto estiver
    # aberto, o conteúdo é código e não texto.
    chaves = 0

    while i < len(texto):
        c = texto[i]
        if aspa:
            if escapando:
                escapando = False
            elif c == "\\":
                escapando = True
            elif c == "$" and i + 1 < len(texto) and texto[i + 1] == "{":
                chaves += 1
                i += 1
            elif c == "}" and chaves:
                chaves -= 1
            elif c == aspa and not chaves:
                aspa = None
            elif c == "\n":
                # Não fechou até o fim da linha. O Dart também desiste aqui.
                aspa = None
        else:
            if c in "'\"":
                aspa = c
            elif c in "([{":
                profundidade += 1
            elif c in ")]}":
                if profundidade == 0:
                    return virgulas + 1, i
                profundidade -= 1
            elif c == "," and profundidade == 0:
                virgulas += 1
        i += 1
    return virgulas + 1, i


def conferir(caminho: str) -> int:
    texto = open(caminho, encoding="utf-8").read()
    problemas = 0
    for m in re.finditer(r"\b_t\(", texto):
        quantos, _ = contar_argumentos(texto, m.end())
        if quantos != IDIOMAS:
            linha = texto.count("\n", 0, m.start()) + 1
            print(
                f"{caminho}:{linha}: _t com {quantos} argumentos "
                f"(esperado {IDIOMAS}) — provavelmente uma string que não fechou, "
                f"quase sempre um apóstrofo sem escape em francês."
            )
            problemas += 1
    if problemas:
        print(f"FALHOU: {problemas} chamada(s) de _t com aridade errada.")
    else:
        print(f"ok: todas as chamadas de _t em {caminho} têm {IDIOMAS} textos.")
    return problemas


if __name__ == "__main__":
    alvos = sys.argv[1:] or ["client/lib/l10n/strings.dart"]
    sys.exit(1 if sum(conferir(a) for a in alvos) else 0)
