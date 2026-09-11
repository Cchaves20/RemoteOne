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

# --- 1. Versão mínima do iOS -----------------------------------------------
# O flutter_webrtc exige iOS 13 no mínimo.
#
# Isto aqui já procurou esse ajuste no lugar errado duas vezes, então vale
# escrever o que mudou: **a partir do Flutter 3.44 o Swift Package Manager é o
# padrão no iOS, e o Podfile deixou de ser gerado.** Ele só aparece como
# reserva, para plugins que ainda não têm pacote Swift. Quem manda na versão
# mínima, nos dois caminhos, é o projeto do Xcode.
#
# Antes disto o script editava um Podfile inexistente, e sem `set -e` os erros
# iam para o log enquanto o build seguia verde. Quer dizer: a linha de
# plataforma provavelmente nunca foi aplicada, e ninguém notou porque o
# projeto do Xcode já carregava o valor certo.

# Sobe o alvo para 13.0 onde estiver abaixo — e **só onde estiver abaixo**.
#
# A versão anterior usava um `perl` que carimbava 13.0 em toda ocorrência.
# Enquanto o template do Flutter vinha com 12.0 isso parecia igual, mas é
# outra coisa: no dia em que o template subir para 15.0 (e ele vai; o Flutter
# vem subindo o piso), aquele comando **rebaixaria** o projeto, e um pacote
# Swift que exige 15 quebraria o build com uma mensagem sobre deployment
# target que não aponta para cá.
python3 - <<'PY'
import pathlib
import re

MINIMO = 13.0
caminho = pathlib.Path("ios/Runner.xcodeproj/project.pbxproj")
texto = caminho.read_text(encoding="utf-8")

def subir(m):
    atual = float(m.group(1))
    if atual >= MINIMO:
        return m.group(0)
    return f"IPHONEOS_DEPLOYMENT_TARGET = {MINIMO};"

novo, trocas = re.subn(
    r"IPHONEOS_DEPLOYMENT_TARGET = ([0-9.]+);", subir, texto
)
if novo != texto:
    caminho.write_text(novo, encoding="utf-8")

valores = re.findall(r"IPHONEOS_DEPLOYMENT_TARGET = ([0-9.]+);", novo)
if not valores:
    raise SystemExit(
        "FALHOU: nenhum IPHONEOS_DEPLOYMENT_TARGET no projeto — "
        "o template do Flutter mudou de forma."
    )
baixos = [v for v in valores if float(v) < MINIMO]
if baixos:
    raise SystemExit(f"FALHOU: alvo ainda abaixo de {MINIMO}: {baixos}")
print(f"alvo mínimo do iOS: {sorted(set(valores))} em {len(valores)} configuração(ões)")
PY

# O Podfile é opcional. Quando existe, é o caminho de reserva do CocoaPods e
# precisa concordar com o projeto; quando não existe, é o Swift Package
# Manager cuidando de tudo, e não há o que ajustar.
if [ -f ios/Podfile ]; then
  if grep -q "^platform :ios" ios/Podfile; then
    perl -pi -e "s/^platform :ios.*/platform :ios, '13.0'/" ios/Podfile
  else
    # O template traz a linha comentada (`# platform :ios, '12.0'`), que o
    # `grep` acima não casa. Acrescentar no topo é o certo: o CocoaPods usa a
    # primeira declaração e ignora a comentada.
    printf "platform :ios, '13.0'\n" | cat - ios/Podfile > ios/Podfile.novo
    mv ios/Podfile.novo ios/Podfile
  fi
  grep -q "^platform :ios, '13.0'" ios/Podfile || {
    echo "FALHOU: a linha de plataforma não entrou no Podfile."
    exit 1
  }
  echo "Podfile presente (reserva do CocoaPods), plataforma em 13.0"
else
  echo "sem Podfile: o projeto usa Swift Package Manager, que é o padrão"
fi

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

echo "--- Info.plist ---"
/usr/libexec/PlistBuddy -c "Print :CFBundleDisplayName" "$PLIST"
/usr/libexec/PlistBuddy -c "Print :ITSAppUsesNonExemptEncryption" "$PLIST"
