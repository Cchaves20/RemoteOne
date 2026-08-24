#!/usr/bin/env python3
"""Confere a ordem das diretivas de cada arquivo Dart.

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

É o mesmo motivo do `conferir-textos.py`: o `flutter analyze` pega isto, mas
pega num Mac na nuvem, seis minutos depois do push. Este roda em meio segundo,
em qualquer máquina, sem Flutter instalado.

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

    for problema in problemas:
        print(problema)
    if problemas:
        print(f"FALHOU: {len(problemas)} diretiva(s) fora de ordem.")
        return 1
    print(f"ok: as diretivas de {len(arquivos)} arquivo(s) Dart estão em ordem.")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:] or ["client/lib", "client/test"]))
