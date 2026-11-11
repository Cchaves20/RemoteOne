#!/usr/bin/env python3
"""Confere os limites de tamanho dos textos das lojas.

Cada título de `docs/textos-das-lojas.md` que diz "(até N)" é seguido por um
bloco de código com o texto; este script mede o texto e falha se passar do
limite. As lojas cortam ou recusam sem aviso claro, e contar à mão erra.

Uso:
    python3 scripts/conferir-textos-das-lojas.py docs/textos-das-lojas.md
"""
import re
import sys

caminho = sys.argv[1] if len(sys.argv) > 1 else "docs/textos-das-lojas.md"
texto = open(caminho, encoding="utf-8").read()

problemas = 0
for m in re.finditer(r"(?m)^#+ ([^\n]+?)\(até ([\d.]+)[^)\n]*\)[ \t]*\n```\n(.*?)\n```", texto, re.S):
    titulo, limite, corpo = m.group(1).strip(), int(m.group(2).replace(".", "")), m.group(3)
    n = len(corpo)
    ok = n <= limite
    problemas += not ok
    print(f"{'ok ' if ok else 'PASSOU'} {n:5d}/{limite:<5d} {titulo}")

# Os benefícios da assinatura da Play: até 40 cada.
bloco = re.search(r"\*\*Benefícios\*\*.*?```\n(.*?)\n\s*```", texto, re.S)
if bloco:
    for linha in bloco.group(1).splitlines():
        linha = linha.strip()
        ok = len(linha) <= 40
        problemas += not ok
        print(f"{'ok ' if ok else 'PASSOU'} {len(linha):5d}/40    benefício: {linha}")

sys.exit(1 if problemas else 0)
