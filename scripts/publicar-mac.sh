#!/bin/sh
# Põe no site a versão do Mac que o GitHub montou.
#
# Roda no servidor, a partir do clone do repositório:
#
#     cd ~/RemoteOne && git pull && sh scripts/publicar-mac.sh
#
# Busca no pré-lançamento "agente-mac" do GitHub (ver
# .github/workflows/agente-mac.yml) e grava em deploy/site/baixar/, que o
# Caddy serve em https://deskside.com.br/baixar/.
#
# ## A ordem importa
#
# O agente instalado pergunta primeiro pelo resumo do executável
# (Deskside-mac-agente.sha256): se mudou, há versão nova. Então ele baixa o
# .zip e confere com Deskside-mac.zip.sha256. Por isso os arquivos entram no
# site do último para o primeiro dessa conversa — o .zip e o resumo dele
# antes, o resumo do executável por último. Ao contrário, um agente veria a
# "versão nova" antes de o pacote dela estar lá, e baixaria o velho.
#
# Cada arquivo entra com um nome provisório e é renomeado no fim: quem baixa
# no meio da cópia recebe o arquivo velho inteiro, nunca o novo pela metade.
set -eu

cd "$(dirname "$0")/.."

ORIGEM="https://github.com/Cchaves20/RemoteOne/releases/download/agente-mac"
SITE=deploy/site/baixar
TEMP=$(mktemp -d)
trap 'rm -rf "$TEMP"' EXIT

mkdir -p "$SITE"
for nome in Deskside.dmg Deskside-mac.zip Deskside-mac.zip.sha256 Deskside-mac-agente.sha256; do
    echo "--- baixando $nome"
    curl -fL --retry 3 -o "$TEMP/$nome" "$ORIGEM/$nome"
done

echo "--- conferindo"
esperado=$(tr -d ' \r\n' < "$TEMP/Deskside-mac.zip.sha256")
obtido=$(sha256sum "$TEMP/Deskside-mac.zip" | cut -d' ' -f1)
if [ "$esperado" != "$obtido" ]; then
    echo "FALHOU: o Deskside-mac.zip baixado não confere com o resumo publicado."
    echo "Nada mudou no site. Tente de novo em instantes."
    exit 1
fi
for resumo in Deskside-mac.zip.sha256 Deskside-mac-agente.sha256; do
    if ! tr -d ' \r\n' < "$TEMP/$resumo" | grep -Eq '^[0-9a-f]{64}$'; then
        echo "FALHOU: $resumo não é um resumo SHA-256. Nada mudou no site."
        exit 1
    fi
done

echo "--- publicando"
for nome in Deskside.dmg Deskside-mac.zip Deskside-mac.zip.sha256 Deskside-mac-agente.sha256; do
    cp "$TEMP/$nome" "$SITE/.$nome.novo"
    mv -f "$SITE/.$nome.novo" "$SITE/$nome"
    echo "  $SITE/$nome"
done
echo "pronto: https://deskside.com.br/baixar/Deskside.dmg"
