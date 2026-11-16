"""Põe o widget do Deskside no projeto Android gerado pelo `flutter create`.

Chamado pelo codemagic.yaml a partir de `client/`, depois dos outros ajustes
do manifesto. A pasta `android/` não é versionada: o código nativo mora em
`client/nativo/android/` e entra aqui a cada build.

O que ele faz, e pode rodar duas vezes sem duplicar nada:

1. Copia `DesksideWidgetProvider.kt` para a pasta do `MainActivity.kt`, com a
   linha `package` do MainActivity. O `home_widget` acha o widget pelo pacote
   do app mais o nome da classe; um pacote diferente daria "widget não
   encontrado" só na hora do redesenho, sem quebrar o build.
2. Copia `nativo/android/res/` para `android/app/src/main/res/`.
3. Registra no manifesto o widget e o receptor dos toques do `home_widget`.
   Sem o receptor, o botão do widget não faz nada — e nada avisa.

Cada passo confere o resultado e derruba o build se não pegou.
"""

import pathlib
import re
import shutil
import sys

NATIVO = pathlib.Path("nativo/android")
PRINCIPAL = pathlib.Path("android/app/src/main")
MANIFESTO = PRINCIPAL / "AndroidManifest.xml"

PROVEDOR = "DesksideWidgetProvider"

RECEPTORES = f"""
        <!-- Widget do Deskside (scripts/preparar-android.py). -->
        <receiver
            android:name=".{PROVEDOR}"
            android:exported="false">
            <intent-filter>
                <action android:name="android.appwidget.action.APPWIDGET_UPDATE" />
            </intent-filter>
            <meta-data
                android:name="android.appwidget.provider"
                android:resource="@xml/deskside_widget_info" />
        </receiver>
        <!-- Os toques nos botões do widget, que rodam o Dart em segundo plano. -->
        <receiver
            android:name="es.antonborri.home_widget.HomeWidgetBackgroundReceiver"
            android:exported="false">
            <intent-filter>
                <action android:name="es.antonborri.home_widget.action.BACKGROUND" />
            </intent-filter>
        </receiver>
"""


def falhar(motivo: str) -> None:
    sys.exit(f"FALHOU: {motivo}")


def copiar_provedor() -> pathlib.Path:
    principais = sorted(PRINCIPAL.rglob("MainActivity.kt"))
    if not principais:
        falhar(f"sem MainActivity.kt em {PRINCIPAL}")
    main = principais[0]
    pacote = re.search(r"^package\s+([\w.]+)", main.read_text(encoding="utf-8"), re.M)
    if not pacote:
        falhar(f"sem linha package em {main}")
    codigo = (NATIVO / f"{PROVEDOR}.kt").read_text(encoding="utf-8")
    codigo, trocas = re.subn(
        r"^package\s+[\w.]+", f"package {pacote.group(1)}", codigo, count=1, flags=re.M
    )
    if trocas != 1:
        falhar(f"sem linha package em {NATIVO / PROVEDOR}.kt")
    destino = main.parent / f"{PROVEDOR}.kt"
    destino.write_text(codigo, encoding="utf-8")
    print(f"{destino} (pacote {pacote.group(1)})")
    return destino


def copiar_recursos() -> None:
    origem = NATIVO / "res"
    for arquivo in sorted(origem.rglob("*.xml")):
        destino = PRINCIPAL / "res" / arquivo.relative_to(origem)
        destino.parent.mkdir(parents=True, exist_ok=True)
        shutil.copyfile(arquivo, destino)
        print(destino)


def registrar_no_manifesto() -> None:
    texto = MANIFESTO.read_text(encoding="utf-8")
    if f'android:name=".{PROVEDOR}"' not in texto:
        if texto.count("</application>") != 1:
            falhar(f"esperava um </application> em {MANIFESTO}")
        texto = texto.replace("</application>", RECEPTORES + "    </application>")
        MANIFESTO.write_text(texto, encoding="utf-8")
    for exigido in (
        f'android:name=".{PROVEDOR}"',
        "android.appwidget.action.APPWIDGET_UPDATE",
        "@xml/deskside_widget_info",
        "es.antonborri.home_widget.HomeWidgetBackgroundReceiver",
        "es.antonborri.home_widget.action.BACKGROUND",
    ):
        if texto.count(exigido) != 1:
            falhar(f"'{exigido}' deveria aparecer uma vez em {MANIFESTO}")


def main() -> None:
    if not MANIFESTO.exists():
        falhar(f"sem {MANIFESTO} - rode a partir de client/, depois do flutter create")
    copiar_provedor()
    copiar_recursos()
    registrar_no_manifesto()
    print("widget do Android pronto")


if __name__ == "__main__":
    main()
