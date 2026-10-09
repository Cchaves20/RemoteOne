#!/bin/sh
# Monta o Deskside.app do agente para Mac, universal (Apple Silicon e Intel).
#
# Roda num Mac, a partir da raiz do repositório:
#
#     sh scripts/montar-app-mac.sh
#
# Sai em agent/target/mac/Deskside.app e agent/target/mac/Deskside-mac.zip.
#
# A assinatura aqui é **ad hoc** (`codesign -s -`): basta para rodar no Mac de
# quem montou e no de teste, mas o Mac de outra pessoa mostra "desenvolvedor não
# identificado". A assinatura com Developer ID e a notarização entram depois;
# ver docs/agente-mac.md.
set -eu

cd "$(dirname "$0")/../agent"

VERSAO=$(sed -n 's/^version = "\(.*\)"/\1/p' Cargo.toml | head -1)
SAIDA=target/mac
APP="$SAIDA/Deskside.app"

echo "--- compilando $VERSAO para arm64 e x86_64"
rustup target add aarch64-apple-darwin x86_64-apple-darwin >/dev/null
# 11.0 é o mínimo do Info.plist; o compilador precisa saber o mesmo, senão o
# binário pede um macOS mais novo do que o que o pacote anuncia.
export MACOSX_DEPLOYMENT_TARGET=11.0
cargo build --release --bin deskside-agent --target aarch64-apple-darwin
cargo build --release --bin deskside-agent --target x86_64-apple-darwin

echo "--- montando $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
lipo -create \
    target/aarch64-apple-darwin/release/deskside-agent \
    target/x86_64-apple-darwin/release/deskside-agent \
    -output "$APP/Contents/MacOS/deskside-agent"
sed "s/VERSAO/$VERSAO/g" mac/Info.plist > "$APP/Contents/Info.plist"

# O ícone sai do mesmo desenho do app do celular, nos tamanhos que o Mac pede.
ICONES="$SAIDA/Deskside.iconset"
rm -rf "$ICONES"
mkdir -p "$ICONES"
for t in 16 32 128 256 512; do
    sips -z $t $t ../client/assets/icon/deskside.png --out "$ICONES/icon_${t}x${t}.png" >/dev/null
    d=$((t * 2))
    sips -z $d $d ../client/assets/icon/deskside.png --out "$ICONES/icon_${t}x${t}@2x.png" >/dev/null
done
iconutil -c icns "$ICONES" -o "$APP/Contents/Resources/Deskside.icns"
rm -rf "$ICONES"

codesign --force --sign - --timestamp=none "$APP"

echo "--- conferindo"
lipo -archs "$APP/Contents/MacOS/deskside-agent"
plutil -lint "$APP/Contents/Info.plist"
codesign --verify --verbose "$APP"

# `ditto` e não `zip`: é o que preserva a assinatura e os atributos do pacote.
rm -f "$SAIDA/Deskside-mac.zip"
ditto -c -k --keepParent "$APP" "$SAIDA/Deskside-mac.zip"
echo "pronto: agent/$SAIDA/Deskside-mac.zip"
