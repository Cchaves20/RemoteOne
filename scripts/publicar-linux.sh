#!/bin/sh
# Põe no site a versão do Linux que o GitHub montou.
#
# Roda no servidor, a partir do clone do repositório:
#
#     cd ~/RemoteOne && git pull && sh scripts/publicar-linux.sh
#
# Busca no pré-lançamento "agente-linux" do GitHub (ver
# .github/workflows/agente-linux.yml) e grava em deploy/site/baixar/, que o
# Caddy serve em https://deskside.com.br/baixar/. Os agentes instalados só
# se atualizam com o que passa por aqui: cada push no GitHub não vira
# atualização de ninguém.
#
# Por processador (x86_64 e aarch64), dois pares:
#
# - Deskside-linux-<arq>.tar.gz e o resumo dele: a instalação, para pessoas.
# - Deskside-linux-<arq>-agente e o resumo dele: o executável solto, que é o
#   que a atualização automática compara e baixa.
#
# ## A ordem importa
#
# O agente instalado pergunta pelo resumo do executável: se mudou, baixa o
# executável e confere com esse mesmo resumo. Por isso o executável entra no
# site antes do resumo. Ao contrário, um agente veria a "versão nova" antes de
# ela estar lá, baixaria o velho e a conferência recusaria.
#
# Cada arquivo entra com um nome provisório e é renomeado no fim: quem baixa
# no meio da cópia recebe o arquivo velho inteiro, nunca o novo pela metade.
set -eu

cd "$(dirname "$0")/.."

ORIGEM="https://github.com/Cchaves20/RemoteOne/releases/download/agente-linux"
SITE=deploy/site/baixar
TEMP=$(mktemp -d)
trap 'rm -rf "$TEMP"' EXIT

ARQUIVOS=""
for arq in x86_64 aarch64; do
    ARQUIVOS="$ARQUIVOS Deskside-linux-$arq.tar.gz Deskside-linux-$arq.tar.gz.sha256"
    ARQUIVOS="$ARQUIVOS Deskside-linux-$arq-agente Deskside-linux-$arq-agente.sha256"
done

mkdir -p "$SITE"
for nome in $ARQUIVOS; do
    echo "--- baixando $nome"
    curl -fL --retry 3 -o "$TEMP/$nome" "$ORIGEM/$nome"
done

echo "--- conferindo"
for nome in $ARQUIVOS; do
    case "$nome" in *.sha256) continue ;; esac
    esperado=$(cut -d' ' -f1 < "$TEMP/$nome.sha256" | tr -d ' \r\n')
    if ! echo "$esperado" | grep -Eq '^[0-9a-f]{64}$'; then
        echo "FALHOU: $nome.sha256 não é um resumo SHA-256. Nada mudou no site."
        exit 1
    fi
    obtido=$(sha256sum "$TEMP/$nome" | cut -d' ' -f1)
    if [ "$esperado" != "$obtido" ]; then
        echo "FALHOU: o $nome baixado não confere com o resumo publicado."
        echo "Nada mudou no site. Tente de novo em instantes."
        exit 1
    fi
done
chmod 644 "$TEMP"/*

echo "--- publicando"
# Na ordem da lista: cada arquivo antes do seu resumo.
for nome in $ARQUIVOS; do
    cp "$TEMP/$nome" "$SITE/.$nome.novo"
    mv -f "$SITE/.$nome.novo" "$SITE/$nome"
    echo "  $SITE/$nome"
done
echo "pronto: https://deskside.com.br/baixar/Deskside-linux-x86_64.tar.gz"
