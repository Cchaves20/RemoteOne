#!/bin/sh
# Monta o Deskside do Mac: o .app universal (Apple Silicon e Intel), o .zip que
# a atualização automática baixa e o .dmg que as pessoas baixam do site.
#
# Roda num Mac, a partir da raiz do repositório:
#
#     sh scripts/montar-app-mac.sh
#
# Sai em agent/target/mac/:
#
#     Deskside.app
#     Deskside.dmg                  o instalador (arrastar para Aplicativos)
#     Deskside-mac.zip              o pacote da atualização automática
#     Deskside-mac.zip.sha256       o resumo dele (o agente confere)
#     Deskside-mac-agente.sha256    o resumo do executável de dentro do .app,
#                                   que é como o agente sabe se está em dia
#
# ## Assinatura
#
# Com MAC_IDENTIDADE definida (o nome do certificado no chaveiro, ex.:
# "Developer ID Application: Fulano (ABCDE12345)"), assina com ela e com o
# "hardened runtime" que a notarização exige. Sem ela, assina ad hoc: roda no
# Mac de teste, mas outro Mac mostra "desenvolvedor não identificado", e cada
# versão nova pede as permissões de novo.
#
# ## Notarização
#
# Com MAC_IDENTIDADE e as três variáveis da chave da API da App Store Connect
# (APP_STORE_CONNECT_KEY_ID, APP_STORE_CONNECT_ISSUER_ID e
# APP_STORE_CONNECT_KEY_FILE, o caminho do .p8), manda à Apple para conferir e
# grampeia o recibo no .app e no .dmg. É o que faz o Mac abrir o Deskside sem
# aviso nenhum. Ver docs/agente-mac.md.
set -eu

cd "$(dirname "$0")/../agent"

VERSAO=$(sed -n 's/^version = "\(.*\)"/\1/p' Cargo.toml | head -1)
SAIDA=target/mac
APP="$SAIDA/Deskside.app"
IDENTIDADE="${MAC_IDENTIDADE:-}"

notarizar() {
    # Só com tudo o que a Apple pede; faltando algo, avisa e segue sem.
    [ -n "$IDENTIDADE" ] || return 1
    [ -n "${APP_STORE_CONNECT_KEY_ID:-}" ] || return 1
    [ -n "${APP_STORE_CONNECT_ISSUER_ID:-}" ] || return 1
    [ -f "${APP_STORE_CONNECT_KEY_FILE:-}" ] || return 1
    echo "--- notarizando $1"
    xcrun notarytool submit "$1" \
        --key "$APP_STORE_CONNECT_KEY_FILE" \
        --key-id "$APP_STORE_CONNECT_KEY_ID" \
        --issuer "$APP_STORE_CONNECT_ISSUER_ID" \
        --wait --timeout 30m
}

assinar() {
    if [ -n "$IDENTIDADE" ]; then
        codesign --force --options runtime --timestamp --sign "$IDENTIDADE" "$1"
    else
        codesign --force --sign - --timestamp=none "$1"
    fi
}

echo "--- compilando $VERSAO para arm64 e x86_64"
rustup target add aarch64-apple-darwin x86_64-apple-darwin >/dev/null
# 11.0 é o mínimo do Info.plist; o compilador precisa saber o mesmo, senão o
# binário pede um macOS mais novo do que o que o pacote anuncia.
export MACOSX_DEPLOYMENT_TARGET=11.0
cargo build --release --bin deskside-agent --target aarch64-apple-darwin
cargo build --release --bin deskside-agent --target x86_64-apple-darwin

echo "--- montando $APP"
rm -rf "$SAIDA"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
lipo -create \
    target/aarch64-apple-darwin/release/deskside-agent \
    target/x86_64-apple-darwin/release/deskside-agent \
    -output "$APP/Contents/MacOS/deskside-agent"
sed "s/VERSAO/$VERSAO/g" mac/Info.plist > "$APP/Contents/Info.plist"

# O ícone sai do mesmo desenho do app do celular, nos tamanhos que o Mac pede.
ICONES="$SAIDA/Deskside.iconset"
mkdir -p "$ICONES"
for t in 16 32 128 256 512; do
    sips -z $t $t ../client/assets/icon/deskside.png --out "$ICONES/icon_${t}x${t}.png" >/dev/null
    d=$((t * 2))
    sips -z $d $d ../client/assets/icon/deskside.png --out "$ICONES/icon_${t}x${t}@2x.png" >/dev/null
done
iconutil -c icns "$ICONES" -o "$APP/Contents/Resources/Deskside.icns"
rm -rf "$ICONES"

if [ -n "$IDENTIDADE" ]; then
    echo "--- assinando com o Developer ID"
else
    echo "--- assinando ad hoc (sem MAC_IDENTIDADE): bom para testar, não para distribuir"
fi
assinar "$APP"
codesign --verify --strict --verbose "$APP"

# `ditto` e não `zip`: é o que preserva a assinatura e os atributos do pacote.
ZIP="$SAIDA/Deskside-mac.zip"
ditto -c -k --keepParent "$APP" "$ZIP"
if notarizar "$ZIP"; then
    # O recibo vai grampeado no .app, e o .zip é refeito com ele dentro: assim
    # o Mac confere a notarização mesmo sem internet.
    xcrun stapler staple "$APP"
    rm -f "$ZIP"
    ditto -c -k --keepParent "$APP" "$ZIP"
    NOTARIZADO=sim
else
    NOTARIZADO=não
fi

echo "--- o instalador"
PALCO="$SAIDA/palco"
mkdir -p "$PALCO"
cp -R "$APP" "$PALCO/"
# O atalho para Aplicativos ao lado do ícone: é o "arraste para cá" que todo
# instalador de Mac tem.
ln -s /Applications "$PALCO/Aplicativos"
hdiutil create -volname "Deskside" -srcfolder "$PALCO" -ov -format UDZO "$SAIDA/Deskside.dmg" >/dev/null
rm -rf "$PALCO"
if [ -n "$IDENTIDADE" ]; then
    codesign --force --timestamp --sign "$IDENTIDADE" "$SAIDA/Deskside.dmg"
fi
if [ "$NOTARIZADO" = sim ] && notarizar "$SAIDA/Deskside.dmg"; then
    xcrun stapler staple "$SAIDA/Deskside.dmg"
fi

echo "--- resumos"
# Do executável **depois** de assinado: a assinatura mora dentro dele.
shasum -a 256 "$APP/Contents/MacOS/deskside-agent" | cut -d' ' -f1 > "$SAIDA/Deskside-mac-agente.sha256"
shasum -a 256 "$ZIP" | cut -d' ' -f1 > "$ZIP.sha256"

echo "--- conferindo"
lipo -archs "$APP/Contents/MacOS/deskside-agent"
plutil -lint "$APP/Contents/Info.plist"
codesign --verify --deep --strict --verbose "$APP"
if [ "$NOTARIZADO" = sim ]; then
    spctl --assess --type execute --verbose "$APP"
fi
ls -la "$SAIDA"
if [ -n "$IDENTIDADE" ]; then ASSINATURA="Developer ID"; else ASSINATURA="ad hoc"; fi
echo "pronto (assinatura: $ASSINATURA; notarizado: $NOTARIZADO)"
