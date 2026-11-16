"""Assina o build de release do Android com a chave de envio da Play Store.

Chamado pelo workflow `android-play` do codemagic.yaml, a partir de `client/`,
depois do `flutter create` e dos outros ajustes. A pasta `android/` não é
versionada, então a assinatura entra aqui a cada build.

O modelo do Flutter assina o release com a chave de **depuração** ("para o
`flutter run --release` funcionar"). A Play Store recusa um .aab assim, mas só
depois do envio, com uma mensagem genérica. Aqui a troca é feita e conferida
antes de o Gradle rodar.

A chave vem do Codemagic: com `android_signing` no workflow, ele grava o
keystore no disco e exporta `CM_KEYSTORE_PATH`, `CM_KEYSTORE_PASSWORD`,
`CM_KEY_ALIAS` e `CM_KEY_PASSWORD`. Nenhuma senha passa por este arquivo nem
pelo log: o Gradle as lê do ambiente na hora de assinar.

O nome do pacote (`applicationId`) **não** muda aqui. O `home_widget` acha o
widget como `<applicationId>.DesksideWidgetProvider`, e a classe mora no pacote
do MainActivity: trocar só o `applicationId` quebraria o widget em silêncio.

Pode rodar duas vezes sem duplicar nada.
"""

import os
import pathlib
import sys

APP = pathlib.Path("android/app")

VARIAVEIS = ("CM_KEYSTORE_PATH", "CM_KEYSTORE_PASSWORD", "CM_KEY_ALIAS", "CM_KEY_PASSWORD")

KTS_BLOCO = """    signingConfigs {
        create("loja") {
            storeFile = file(System.getenv("CM_KEYSTORE_PATH"))
            storePassword = System.getenv("CM_KEYSTORE_PASSWORD")
            keyAlias = System.getenv("CM_KEY_ALIAS")
            keyPassword = System.getenv("CM_KEY_PASSWORD")
        }
    }

"""
KTS_DEBUG = 'signingConfig = signingConfigs.getByName("debug")'
KTS_LOJA = 'signingConfig = signingConfigs.getByName("loja")'

GROOVY_BLOCO = """    signingConfigs {
        loja {
            storeFile file(System.getenv("CM_KEYSTORE_PATH"))
            storePassword System.getenv("CM_KEYSTORE_PASSWORD")
            keyAlias System.getenv("CM_KEY_ALIAS")
            keyPassword System.getenv("CM_KEY_PASSWORD")
        }
    }

"""
GROOVY_DEBUG = "signingConfig signingConfigs.debug"
GROOVY_LOJA = "signingConfig signingConfigs.loja"


def falhar(motivo: str) -> None:
    print(f"FALHOU: {motivo}")
    sys.exit(1)


def assinar(caminho: pathlib.Path, bloco: str, debug: str, loja: str) -> None:
    texto = caminho.read_text(encoding="utf-8")
    if loja not in texto:
        if texto.count(debug) != 1:
            falhar(
                f"esperava uma linha '{debug}' em {caminho} - o modelo do Flutter mudou."
            )
        texto = texto.replace(debug, loja)
    if "signingConfigs {" not in texto:
        # Antes do `buildTypes`: o Gradle precisa conhecer a configuração antes
        # de o release apontar para ela.
        if texto.count("    buildTypes {") != 1:
            falhar(f"não achei o bloco 'buildTypes' em {caminho}.")
        texto = texto.replace("    buildTypes {", bloco + "    buildTypes {")
    caminho.write_text(texto, encoding="utf-8")

    final = caminho.read_text(encoding="utf-8")
    if debug in final or loja not in final or final.count("signingConfigs {") != 1:
        falhar(f"a assinatura de loja não ficou em {caminho}.")


def main() -> None:
    faltando = [v for v in VARIAVEIS if not os.environ.get(v)]
    if faltando:
        falhar(
            "a chave de envio não chegou ao build ("
            + ", ".join(faltando)
            + "). Confira no Codemagic: Team settings > Code signing identities >"
            " Android keystores, com o nome de referência 'deskside_envio'."
        )
    if not pathlib.Path(os.environ["CM_KEYSTORE_PATH"]).is_file():
        falhar("o caminho do keystore não existe no disco.")

    kts = APP / "build.gradle.kts"
    groovy = APP / "build.gradle"
    if kts.exists():
        assinar(kts, KTS_BLOCO, KTS_DEBUG, KTS_LOJA)
        print(f"assinatura de loja em {kts}")
    elif groovy.exists():
        assinar(groovy, GROOVY_BLOCO, GROOVY_DEBUG, GROOVY_LOJA)
        print(f"assinatura de loja em {groovy}")
    else:
        falhar("não achei android/app/build.gradle(.kts).")


if __name__ == "__main__":
    main()
