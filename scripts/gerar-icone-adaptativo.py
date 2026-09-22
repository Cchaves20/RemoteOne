#!/usr/bin/env python3
"""Gera a camada de frente do ícone adaptativo do Android, e confere a conta.

## Por que existe um script, e não só o PNG

`client/assets/icon/deskside_adaptativo.png` é um arquivo derivado: ele sai do
`deskside_glyph.png` encolhido e centrado. Um binário versionado sem a receita
ao lado é um arquivo que ninguém sabe refazer — e no dia em que a marca mudar,
alguém vai abrir um editor de imagem e chutar a folga de novo.

## O que o Android faz com a camada, e por que a folga não é opinião

Um ícone adaptativo tem duas camadas de **108dp**, e o sistema recorta as duas
juntas com uma máscara escolhida pelo fabricante do telefone — redonda,
quadrada arredondada, "squircle", gota. Todas essas máscaras cabem num quadrado
de **72dp** no centro; o que passar disso é cortado em todo aparelho.

A recomendação que circula é "deixe o conteúdo em 66% do quadro". Para um
desenho quadrado ela serve. O glifo do Deskside é largo (674 × 568), e para ele
não serve: medindo, a máscara redonda come **12%** dele a 66% — justamente os
cantos do monitor, que é a parte que faz o desenho ser reconhecível.

A tabela que este script imprime é a medição. A 54% nenhuma das máscaras corta
nada, e é por isso que `FRACAO` é 0.54 e não um número redondo.

## Uso

    python3 scripts/gerar-icone-adaptativo.py            # gera e confere
    python3 scripts/gerar-icone-adaptativo.py --conferir  # só confere

Precisa do Pillow (`pip install pillow`). Não roda no Codemagic: o PNG vai
versionado, e o `flutter_launcher_icons` o consome de lá.
"""

import pathlib
import re
import sys

from PIL import Image, ImageDraw

LADO = 1024

#: Quanto do quadro o glifo ocupa, medido no maior lado dele.
#:
#: Ver o cabeçalho: 0.66 perde 12% na máscara redonda, 0.54 não perde nada.
FRACAO = 0.54

GLIFO = pathlib.Path("client/assets/icon/deskside_glyph.png")
SAIDA = pathlib.Path("client/assets/icon/deskside_adaptativo.png")

#: As máscaras, como fração do quadro de 108dp.
#:
#: 72/108 é o que os aparelhos recortam de verdade. 66/108 é o círculo que a
#: documentação garante — um piso conservador, e não o recorte de nenhum
#: telefone conhecido. Os dois entram na conferência para a diferença ficar à
#: vista de quem for mexer na `FRACAO`.
MASCARAS = {"72dp (o que os aparelhos usam)": 72 / 108, "66dp (piso garantido)": 66 / 108}


def montar() -> Image.Image:
    origem = Image.open(GLIFO).convert("RGBA")
    recorte = origem.crop(origem.getbbox())

    # Escala pelo lado **maior** do conteúdo. Pelo menor, o outro estouraria a
    # folga — que é exatamente o defeito que este arquivo existe para evitar.
    fator = (LADO * FRACAO) / max(recorte.size)
    novo = (round(recorte.width * fator), round(recorte.height * fator))
    redimensionado = recorte.resize(novo, Image.LANCZOS)

    tela = Image.new("RGBA", (LADO, LADO), (0, 0, 0, 0))
    tela.paste(
        redimensionado,
        ((LADO - novo[0]) // 2, (LADO - novo[1]) // 2),
        redimensionado,
    )
    return tela


def perda(imagem: Image.Image, diametro: float) -> float:
    """Quanto do glifo uma máscara circular deste diâmetro comeria, em %."""
    alpha = imagem.getchannel("A")
    visivel = [p > 8 for p in alpha.get_flattened_data()]
    total = sum(visivel)
    if not total:
        return 0.0

    mascara = Image.new("L", (LADO, LADO), 0)
    d = int(LADO * diametro)
    canto = (LADO - d) // 2
    ImageDraw.Draw(mascara).ellipse([canto, canto, canto + d, canto + d], fill=255)

    dentro = Image.new("L", (LADO, LADO), 0)
    dentro.paste(alpha, (0, 0), mascara)
    sobrou = sum(1 for p in dentro.get_flattened_data() if p > 8)
    return 100 * (total - sobrou) / total


#: As duas configurações, uma por plataforma, e o que cada uma tem de dizer.
#:
#: São dois arquivos porque cada workflow do Codemagic cria a pasta de uma
#: plataforma só (ver o cabeçalho de `client/icone-android.yaml`).
#: O preço de separar é o `image_path` repetido — e é este bloco que impede o
#: preço de virar defeito, conferindo que ninguém trocou o desenho pela metade.
CONFIGURACOES = {
    "client/icone-android.yaml": {
        "android": True,
        "ios": False,
        "image_path": "assets/icon/deskside.png",
        "adaptive_icon_foreground": "assets/icon/deskside_adaptativo.png",
    },
    "client/icone-ios.yaml": {
        "android": False,
        "ios": True,
        "image_path": "assets/icon/deskside.png",
    },
}


#: O nome que **não** pode existir em `client/`.
#:
#: `flutter_launcher_icons` trata todo arquivo que case com isto como um
#: *flavor*, e havendo qualquer flavor ele ignora o `-f` e faz um laço por
#: todos — cada workflow voltaria a tentar as duas plataformas.
#:
#: Não é hipótese: os arquivos nasceram com esses nomes, viraram os flavors
#: "android" e "ios", e o build de Android foi tentar escrever em
#: `ios/Runner.xcodeproj`. O padrão abaixo é copiado do próprio pacote
#: (`flavorConfigFilePattern`, em `lib/main.dart`).
PADRAO_DE_FLAVOR = re.compile(r"^flutter_launcher_icons-(.*)\.yaml$")

PASTA_DO_APP = pathlib.Path("client")


def conferir_configuracoes() -> list[str]:
    """As duas configurações continuam dizendo o que se espera delas?

    Sem `pyyaml` instalado, sai calado quanto ao conteúdo — mas a checagem de
    nome acontece de qualquer jeito, porque ela não depende de ler YAML.
    """
    problemas = []

    for item in sorted(PASTA_DO_APP.glob("*.yaml")):
        if PADRAO_DE_FLAVOR.match(item.name):
            problemas.append(
                f"{item}: este nome vira um *flavor* para o "
                "flutter_launcher_icons, e havendo flavor ele ignora o `-f` e "
                "tenta as duas plataformas. Renomeie (ex.: icone-<plataforma>.yaml)."
            )

    try:
        import yaml
    except ImportError:
        print("(sem pyyaml: não conferi o conteúdo dos arquivos de configuração)")
        return problemas

    for arquivo, esperado in CONFIGURACOES.items():
        caminho = pathlib.Path(arquivo)
        if not caminho.is_file():
            problemas.append(f"{arquivo}: não existe.")
            continue
        conteudo = yaml.safe_load(caminho.read_text(encoding="utf-8"))
        achado = (conteudo or {}).get("flutter_launcher_icons")
        if achado is None:
            problemas.append(
                f"{arquivo}: sem a chave `flutter_launcher_icons`. A ferramenta "
                "ignora o arquivo e cai no pubspec.yaml, sem avisar."
            )
            continue
        for chave, valor in esperado.items():
            if achado.get(chave) != valor:
                problemas.append(
                    f"{arquivo}: `{chave}` é {achado.get(chave)!r}, "
                    f"esperado {valor!r}."
                )
    return problemas


def main(args: list[str]) -> int:
    so_conferir = "--conferir" in args
    imagem = Image.open(SAIDA).convert("RGBA") if so_conferir else montar()

    caixa = imagem.getbbox()
    largura, altura = caixa[2] - caixa[0], caixa[3] - caixa[1]
    print(f"conteúdo: {largura} × {altura} num quadro de {LADO}")
    print(f"ocupa {100 * largura / LADO:.0f}% × {100 * altura / LADO:.0f}%")

    if abs(caixa[0] - (LADO - caixa[2])) > 1 or abs(caixa[1] - (LADO - caixa[3])) > 1:
        print("FALHOU: o conteúdo não está centrado.")
        return 1

    ruim = False
    for nome, diametro in MASCARAS.items():
        quanto = perda(imagem, diametro)
        print(f"  máscara {nome}: perde {quanto:.1f}%")
        # A de 72dp é a que existe nos aparelhos; qualquer perda nela é corte
        # visível na gaveta de aplicativos.
        if diametro > 0.66 and quanto > 0.5:
            ruim = True

    if ruim:
        print("FALHOU: a máscara que os aparelhos usam corta o glifo. Baixe a FRACAO.")
        return 1

    problemas = conferir_configuracoes()
    for problema in problemas:
        print(problema)
    if problemas:
        print(f"FALHOU: {len(problemas)} problema(s) nos arquivos de configuração.")
        return 1

    if not so_conferir:
        imagem.save(SAIDA)
        print(f"ok: {SAIDA} gerado.")
    else:
        print("ok: a camada que está no repositório passa nas máscaras.")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
