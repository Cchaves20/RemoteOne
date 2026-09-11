#!/bin/sh
# Ajustes obrigatórios do projeto iOS, antes de qualquer `flutter build`.
#
# ## Por que isto existe como arquivo
#
# A pasta `ios/` não é versionada: ela é gerada pelo template do Flutter a cada
# build. Tudo o que o app precisa e que o template não dá — versão mínima do
# iOS, chaves de permissão, nome embaixo do ícone — tem que ser reaplicado
# toda vez, por script.
#
# Esses passos moravam dentro do workflow de sideload, e o de TestFlight nasceu
# sem nenhum deles. Ligado daquele jeito, o build subiria para os testadores um
# app que **trava na biometria** e **não conecta em casa**, sem nada no log
# dizendo isso. Duplicar as linhas nos dois workflows só adiaria o problema
# para o dia em que um dos dois fosse corrigido e o outro não.
#
# Roda a partir de `client/`.
#
# Não é testado no ambiente de desenvolvimento: `PlistBuddy` só existe no
# macOS. Quem exercita este arquivo é o build do Codemagic.
set -e

PLIST=ios/Runner/Info.plist

# Define uma chave do Info.plist, exista ela ou não. O `Add` falha quando a
# chave já está lá, e aí o `Set` resolve — é o idioma do PlistBuddy.
definir() {
  /usr/libexec/PlistBuddy -c "Add :$1 $2 $3" "$PLIST" \
    || /usr/libexec/PlistBuddy -c "Set :$1 $3" "$PLIST"
}

# --- 1. iOS 13 -------------------------------------------------------------
# O flutter_webrtc exige iOS 13 no mínimo, e o ajuste precisa vir antes do
# `flutter build`, que é quem roda o pod install.
#
# O Podfile **não vem do `flutter create`**: quem o escreve é o próprio Flutter
# ao preparar o build de iOS, e `--config-only` faz essa preparação sem
# compilar nada. Antes disto o script mexia num arquivo que ainda não existia;
# sem `set -e` os erros do `grep` e do `cat` iam para o log e o build seguia,
# então é bem provável que a linha de `platform :ios` nunca tenha sido
# aplicada de verdade — ou seja, o requisito do WebRTC vinha sendo ignorado em
# silêncio, e o build passava verde.
if [ ! -f ios/Podfile ]; then
  flutter build ios --config-only --no-codesign
fi

# Se ainda assim não existir, parar aqui. Seguir em frente só empurraria a
# falha para o `pod install`, com uma mensagem pior e cinco minutos depois.
if [ ! -f ios/Podfile ]; then
  echo "FALHOU: ios/Podfile não existe nem depois de --config-only."
  exit 1
fi

if grep -q "^platform :ios" ios/Podfile; then
  perl -pi -e "s/^platform :ios.*/platform :ios, '13.0'/" ios/Podfile
else
  # O template do Flutter traz a linha comentada (`# platform :ios, '12.0'`),
  # que o `grep` acima não casa. Acrescentar no topo é o certo: o CocoaPods
  # usa a primeira declaração e ignora a comentada.
  printf "platform :ios, '13.0'\n" | cat - ios/Podfile > ios/Podfile.novo
  mv ios/Podfile.novo ios/Podfile
fi

# Conferir que pegou. Um Podfile sem esta linha faz o pod install resolver
# para iOS 12, e o flutter_webrtc não compila lá.
grep -q "^platform :ios, '13.0'" ios/Podfile || {
  echo "FALHOU: a linha de plataforma não entrou no Podfile."
  exit 1
}
perl -pi -e "s/IPHONEOS_DEPLOYMENT_TARGET = [0-9.]+;/IPHONEOS_DEPLOYMENT_TARGET = 13.0;/g" \
  ios/Runner.xcodeproj/project.pbxproj

# --- 2. Permissões ---------------------------------------------------------
# O binário do WebRTC referencia câmera e microfone. O Deskside só recebe
# vídeo e não usa nenhum dos dois, mas sem estas chaves o iOS encerra o app
# caso alguma dessas APIs seja tocada.
MOTIVO="Nao utilizado: o Deskside apenas recebe a tela e o som do computador."
definir NSCameraUsageDescription string "$MOTIVO"
definir NSMicrophoneUsageDescription string "$MOTIVO"

# Rede local: desde o iOS 14 o sistema BLOQUEIA falar com IPs da própria rede
# sem esta chave e sem o usuário autorizar. É por ela que passa o caminho
# direto celular <-> PC quando os dois estão no mesmo Wi-Fi — sem ela o WebRTC
# não fecha em casa, que é justamente onde deveria ser mais fácil.
definir NSLocalNetworkUsageDescription string \
  "Conectar direto ao seu computador quando os dois estao na mesma rede."

definir NSFaceIDUsageDescription string "Desbloquear o Deskside"

# --- 3. Nome embaixo do ícone ----------------------------------------------
# Sem isto o iPhone mostra "Deskside Client": o `flutter create` usa o
# `--project-name` (deskside_client) como nome visível. O nome do projeto
# continua com sufixo porque é ele que dá o identificador do pacote; o que a
# pessoa lê é outro campo.
definir CFBundleDisplayName string Deskside

# --- 4. Declaração de criptografia -----------------------------------------
# Sem esta chave, a App Store Connect pergunta sobre exportação de criptografia
# a **cada** envio, e a build fica parada esperando resposta — no meio de um
# teste com outras pessoas, isso vira "o app não chegou" sem explicação.
#
# `false` é a declaração de que o app só usa criptografia padrão da plataforma:
# HTTPS para falar com o servidor, o DTLS-SRTP do próprio WebRTC, e o Keychain
# para guardar o token. Nada disso é implementação nossa.
#
# É uma declaração legal, não um detalhe técnico: se algum dia o app passar a
# cifrar conteúdo por conta própria, esta linha precisa ser revista.
definir ITSAppUsesNonExemptEncryption bool false

echo "--- Podfile ---"
head -3 ios/Podfile
echo "--- Info.plist ---"
/usr/libexec/PlistBuddy -c "Print :CFBundleDisplayName" "$PLIST"
/usr/libexec/PlistBuddy -c "Print :ITSAppUsesNonExemptEncryption" "$PLIST"
