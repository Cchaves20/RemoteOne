#!/usr/bin/env python3
"""Confere as diretivas de cada arquivo Dart: a ordem, e o import que sobra.

## Por que isto existe

O Dart exige uma ordem: `library` primeiro, depois `import` e `export`, depois
`part`. Quebrar isso é erro de compilação — e é um erro que **passa
despercebido ao escrever**, porque o comentário de documentação da biblioteca
fica visualmente no topo mesmo quando o `library;` que o ancora ficou lá
embaixo, depois dos imports.

Foi exatamente o que aconteceu: um `library;` sobrou abaixo dos imports e de uma
constante, e o Codemagic devolveu

    Failing tests:
      .../client/test/widget_test.dart: loading .../widget_test.dart

que não menciona o arquivo com o defeito, nem a diretiva, nem a palavra
"library". O teste que "falhou" só importava, de longe, quem estava quebrado.

Depois veio o defeito irmão, o do import que **sobra**: o
`flutter analyze` falha com código 1 em qualquer apontamento, inclusive nos de
severidade `info` — e `unused_import` é um deles. Um import esquecido depois de
uma refatoração derruba o build inteiro, seis minutos depois do push, por uma
linha que nenhum teste roda.

É o mesmo motivo do `conferir-textos.py`: o `flutter analyze` pega isto, mas
pega num Mac na nuvem, seis minutos depois do push. Este roda em meio segundo,
em qualquer máquina, sem Flutter instalado.

## O que a checagem de import consegue e o que não consegue

Ela só enxerga o que consegue ler do disco: imports relativos e
`package:deskside_client/...`. `package:flutter/...` e `dart:...` ficam de fora
— para saber o que eles declaram seria preciso resolver o pub cache e o SDK.

E ela erra **para o lado seguro**. Diante de qualquer dúvida — o arquivo
importado tem `export`, tem `part`, declara `extension` (cujos membros são
usados sem nunca nomear a extensão), ou não deu para achar nenhuma declaração
nele — ela cala a boca em vez de acusar. O preço é deixar passar alguns; o
preço do contrário seria um alarme falso, e um alarme falso ensina a ignorar a
ferramenta.

## Uso

    python3 scripts/conferir-dart.py client/lib client/test

Sai com código 1 quando acha problema.
"""

import pathlib
import re
import sys

#: A ordem que o Dart exige. O número é a posição na fila.
ORDEM = {"library": 0, "import": 1, "export": 1, "part": 2}

#: Uma diretiva no começo da linha. `part of` conta como `part`.
DIRETIVA = re.compile(r"^(library|import|export|part)\b")

#: Um import, com os pedaços opcionais: `as`, `show`, `hide`.
IMPORT = re.compile(
    r"""^import\s+r?['"](?P<alvo>[^'"]+)['"]"""
    r"""(?P<resto>[^;]*);"""
)

#: Declaração de tipo: o nome vem logo depois da palavra-chave.
TIPO = re.compile(
    r"^(?:(?:abstract|base|final|sealed|interface|mixin|external)\s+)*"
    r"(?:class|mixin|enum|extension\s+type|extension|typedef)\s+(\w+)"
)

#: Um identificador seguido do que fecha uma declaração de função ou variável.
#: O `<...>` no meio é a lista de parâmetros de tipo de uma função genérica.
NOME_ANTES = re.compile(r"(\w+)\s*(?:<[^<>()=;{]*>\s*)?(?:\(|=[^=]|;|$)")

#: Palavras do Dart que `NOME_ANTES` colhe sem querer, e que **não** podem
#: entrar na lista de nomes declarados.
#:
#: Isto não é zelo: `=> switch (causa) {` faz `switch` ser colhido como se fosse
#: o nome de uma função, e `switch` aparece em quase todo arquivo do projeto.
#: Um único intruso desses faz todo import daquele módulo parecer usado — a
#: checagem continua "passando" e deixou de checar. Foi o que aconteceu no
#: primeiro teste deste arquivo, e só apareceu porque o teste era de quebrar.
RESERVADAS = frozenset(
    """assert async await break case catch class const continue covariant default
    deferred do else enum export extends extension external factory false final
    finally for get if implements import in interface is late library mixin new
    null on operator part required rethrow return sealed set show static super
    switch sync this throw true try typedef var void when while with yield""".split()
)


def conferir(caminho: pathlib.Path) -> list[str]:
    problemas = []
    maior_vista = -1
    nome_da_maior = ""
    dentro_de_bloco = False

    for numero, linha in enumerate(caminho.read_text(encoding="utf-8").splitlines(), 1):
        crua = linha.strip()

        # Comentários de bloco podem conter a palavra `import` num exemplo.
        if dentro_de_bloco:
            if "*/" in crua:
                dentro_de_bloco = False
            continue
        if crua.startswith("/*"):
            dentro_de_bloco = "*/" not in crua
            continue
        if crua.startswith("//"):
            continue

        achado = DIRETIVA.match(crua)
        if not achado:
            continue
        # `library` sem `;` na mesma linha não é diretiva (pode ser um nome de
        # variável começando com a palavra); exigir o fecho evita falso alarme.
        if not crua.endswith(";"):
            continue

        nome = achado.group(1)
        posicao = ORDEM[nome]
        if posicao < maior_vista:
            problemas.append(
                f"{caminho}:{numero}: `{nome}` depois de `{nome_da_maior}`. "
                "O Dart exige library, depois import/export, depois part — e o "
                "erro que isso gera não menciona nem o arquivo nem a diretiva."
            )
        if posicao > maior_vista:
            maior_vista = posicao
            nome_da_maior = nome

    return problemas


def sem_comentarios(texto: str) -> str:
    """O mesmo código, sem comentário nenhum — e com as strings intactas.

    As strings ficam porque o Dart interpola: `'${t.titulo}'` é uso de verdade
    de `t`, e apagar a string apagaria o uso. O efeito colateral é que um nome
    citado dentro de um texto qualquer conta como uso — o que erra para o lado
    seguro, o de deixar passar.

    Os comentários, ao contrário, precisam sair: documentação cita nomes de
    classe o tempo todo, e um import usado só por um comentário é um import que
    sobra.
    """
    saida: list[str] = []
    i, n, profundidade = 0, len(texto), 0
    while i < n:
        if profundidade:
            # Comentário de bloco em Dart aninha — `/* /* */ */` só fecha no fim.
            if texto.startswith("/*", i):
                profundidade += 1
                i += 2
            elif texto.startswith("*/", i):
                profundidade -= 1
                i += 2
            else:
                if texto[i] == "\n":
                    saida.append("\n")
                i += 1
            continue
        if texto.startswith("//", i):
            while i < n and texto[i] != "\n":
                i += 1
            continue
        if texto.startswith("/*", i):
            profundidade = 1
            i += 2
            continue
        if texto[i] in "'\"":
            # Copiar a string inteira, sem procurar comentário lá dentro: uma
            # URL como 'https://x' tem `//` e cortar ali comeria código real.
            aspas = texto[i : i + 3] if texto[i : i + 3] in ("'''", '"""') else texto[i]
            crua = i > 0 and texto[i - 1] == "r"
            saida.append(aspas)
            i += len(aspas)
            while i < n:
                if not crua and texto[i] == "\\":
                    saida.append(texto[i : i + 2])
                    i += 2
                    continue
                if texto.startswith(aspas, i):
                    saida.append(aspas)
                    i += len(aspas)
                    break
                saida.append(texto[i])
                i += 1
            continue
        saida.append(texto[i])
        i += 1
    return "".join(saida)


def declaracoes(codigo: str) -> set[str]:
    """Os nomes que este arquivo declara no topo.

    Só olha linhas que começam na coluna zero, porque é ali que o Dart põe uma
    declaração de topo — dentro de classe e de função tudo é indentado.

    Colhe **demais** de propósito: pega todo identificador seguido de `(`, `=`
    ou `;`, e não só o primeiro. Um nome a mais na lista faz esta ferramenta
    achar que um import é usado quando não é (e calar); um nome a menos a faria
    acusar um import que é usado de verdade. Entre as duas, a primeira.
    """
    nomes: set[str] = set()
    for linha in codigo.splitlines():
        if not linha or linha[0].isspace() or linha[0] == "@":
            continue
        crua = linha.rstrip()
        if DIRETIVA.match(crua):
            continue
        achado = TIPO.match(crua)
        if achado:
            nomes.add(achado.group(1))
            continue
        nomes.update(m.group(1) for m in NOME_ANTES.finditer(crua))

    # Nome que começa com `_` é privado à biblioteca: quem importa não consegue
    # usá-lo nem querendo, então ele nunca justifica um import.
    return {n for n in nomes if not n.startswith("_") and n not in RESERVADAS}


def pacote_de(caminho: pathlib.Path) -> tuple[str, pathlib.Path] | None:
    """O nome e a pasta `lib` do pacote a que este arquivo pertence.

    Sobe até achar o `pubspec.yaml` em vez de supor onde o projeto está. Isto
    não é firula: o Codemagic chama este script **de dentro de `client/`**
    (`python3 ../scripts/conferir-dart.py lib test`), e uma raiz escrita à mão
    como `client/lib` resolve para `client/client/lib` ali — o que transformaria
    todo import de `package:` num alarme falso, nos três workflows de uma vez.
    """
    for pasta in caminho.resolve().parents:
        pubspec = pasta / "pubspec.yaml"
        if not pubspec.is_file():
            continue
        nome = re.search(r"^name:\s*(\S+)", pubspec.read_text(encoding="utf-8"), re.M)
        if nome:
            return nome.group(1), pasta / "lib"
    return None


def resolver(caminho: pathlib.Path, alvo: str) -> pathlib.Path | None:
    """O arquivo que este import endereça, ou None se não der para saber."""
    if alvo.startswith("package:"):
        pacote = pacote_de(caminho)
        if pacote and alvo.startswith(f"package:{pacote[0]}/"):
            return pacote[1] / alvo.split("/", 1)[1]
        # `package:flutter/...` e afins: resolver exigiria o pub cache.
        return None
    if ":" in alvo:
        # `dart:async`: exigiria o SDK. Fora do alcance, e fora da checagem.
        return None
    return (caminho.parent / alvo).resolve()


def conferir_imports(caminho: pathlib.Path) -> list[str]:
    codigo = sem_comentarios(caminho.read_text(encoding="utf-8"))
    linhas = codigo.splitlines()

    # O corpo é tudo que não é diretiva: o URI do import é uma string, e os
    # pedaços dele contariam como uso do próprio arquivo importado.
    corpo = "\n".join(l for l in linhas if not DIRETIVA.match(l.strip()))
    usados = set(re.findall(r"\w+", corpo))

    problemas = []
    for linha in linhas:
        achado = IMPORT.match(linha.strip())
        if not achado:
            continue
        alvo = achado.group("alvo")
        resto = achado.group("resto")

        apelido = re.search(r"\bas\s+(\w+)", resto)
        if apelido:
            # Com apelido, o uso é o apelido — o que o arquivo declara não
            # aparece sozinho em lugar nenhum.
            if apelido.group(1) not in usados:
                problemas.append(
                    f"{caminho}: `{alvo} as {apelido.group(1)}` não é usado."
                )
            continue

        mostrados = re.search(r"\bshow\s+([\w\s,]+)", resto)
        if mostrados:
            nomes = {n for n in re.split(r"[\s,]+", mostrados.group(1)) if n}
        else:
            destino = resolver(caminho, alvo)
            if destino is None:
                continue
            if not destino.is_file():
                # Caminho relativo que não existe. O Flutter reclama disto alto
                # e claro, mas só lá no build; aqui custa meio segundo.
                problemas.append(
                    f"{caminho}: o import de `{alvo}` aponta para um arquivo "
                    f"que não existe ({destino})."
                )
                continue
            fonte = sem_comentarios(destino.read_text(encoding="utf-8"))
            # Na dúvida, calar. `export` traz nome de terceiro; `part` deixa
            # declaração noutro arquivo; `extension` é usada sem nunca ser
            # nomeada. Em qualquer um dos três a lista abaixo seria incompleta,
            # e uma lista incompleta vira alarme falso.
            if re.search(r"^(export|part)\b", fonte, re.M):
                continue
            if re.search(r"^extension\b", fonte, re.M):
                continue
            nomes = declaracoes(fonte)
            escondidos = re.search(r"\bhide\s+([\w\s,]+)", resto)
            if escondidos:
                nomes -= {n for n in re.split(r"[\s,]+", escondidos.group(1)) if n}
            if not nomes:
                continue

        if not nomes & usados:
            problemas.append(
                f"{caminho}: o import de `{alvo}` não é usado. "
                "O `flutter analyze` falha com código 1 nisto (`unused_import`), "
                "e a falha só aparece no build, seis minutos depois do push."
            )

    return problemas


def main(alvos: list[str]) -> int:
    arquivos = []
    for alvo in alvos:
        caminho = pathlib.Path(alvo)
        if caminho.is_dir():
            arquivos.extend(sorted(caminho.rglob("*.dart")))
        elif caminho.suffix == ".dart":
            arquivos.append(caminho)

    problemas = []
    for arquivo in arquivos:
        problemas.extend(conferir(arquivo))
        problemas.extend(conferir_imports(arquivo))

    for problema in problemas:
        print(problema)
    if problemas:
        print(f"FALHOU: {len(problemas)} problema(s) nas diretivas.")
        return 1
    print(f"ok: as diretivas de {len(arquivos)} arquivo(s) Dart estão em ordem.")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:] or ["client/lib", "client/test"]))
