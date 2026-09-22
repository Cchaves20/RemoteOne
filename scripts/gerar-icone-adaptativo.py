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

    if not so_conferir:
        imagem.save(SAIDA)
        print(f"ok: {SAIDA} gerado.")
    else:
        print("ok: a camada que está no repositório passa nas máscaras.")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
