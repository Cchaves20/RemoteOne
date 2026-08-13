# Instalar o Deskside no Android

O caminho do Android é **muito** mais simples que o do iPhone: o APK instala
direto e **não expira**. Nada de cabo, nada de Sideloadly, nada de reinstalar a
cada sete dias.

## 1. Gerar o APK

1. Acesse <https://codemagic.io> e entre com sua conta do GitHub.
2. No projeto Deskside, clique em **Start new build**.
3. Selecione:
   - **Branch:** `claude/testing-strategy-multiplatform-0nztwm`
   - **Workflow:** `Android (APK para instalar direto, sem expirar)`
4. Ao terminar, baixe o `app-release.apk` dos artefatos.

O build roda numa instância **Linux**, que é mais rápida e não consome os
minutos de Mac da conta gratuita — dá para gerar Android e iOS no mesmo dia sem
estourar a cota.

## 2. Instalar no aparelho

1. Mande o APK para o celular (e-mail, Google Drive, cabo — tanto faz).
2. Abra o arquivo. O Android vai pedir para autorizar **"instalar apps
   desconhecidos"** para o aplicativo de onde veio o arquivo (o gerenciador de
   arquivos, o navegador). Autorize.
3. Instale e abra.

Não expira. Só troca quando você instalar um APK novo por cima.

## 3. Apontar ao servidor

Na tela de login, em **Servidor**: `https://caio-remoteone.duckdns.org`.

## O que este APK não é

- **Não está assinado para a Play Store.** O Flutter assina com a chave de
  depuração, o que basta para instalar mas não para publicar. A chave de
  publicação é um passo separado, e ela **não pode ser perdida**: sem ela não há
  como atualizar o app na loja, nunca mais.
- **Está sem o R8** (`--no-shrink`). O otimizador removeria classes que o WebRTC
  alcança por reflexão, e o resultado seria um APK que instala, abre e quebra na
  hora de mostrar a tela. As regras de ProGuard entram quando a pasta `android/`
  for versionada. Consequência prática: o APK é maior que o necessário.

## Diferenças conhecidas em relação ao iPhone

| | iPhone | Android |
|---|---|---|
| validade | 7 dias | não expira |
| instalação | cabo + Sideloadly | abrir o arquivo |
| distribuir para outra pessoa | praticamente impossível | mandar o arquivo |

## O gesto de voltar e o touchpad

A navegação por gestos do Android põe o "voltar" nas bordas esquerda e direita,
e o "início" numa arrastada de baixo para cima. A tela de controle espera o dedo
exatamente aí — o touchpad ocupa a área toda. Sem tratamento, arrastar o cursor
até a beirada da tela **fecha a sessão**, e ninguém associa "movi o mouse para o
canto" a "o app fechou".

Por isso a tela de controle entra em `immersiveSticky` no Android: as barras
somem, e uma arrastada da borda as **revela** em vez de disparar o gesto. Quem
quer mesmo sair arrasta duas vezes; quem só estava movendo o cursor, não sai. Ao
sair da tela as barras voltam — senão o app inteiro ficaria sem navegação depois
da primeira sessão de controle.

O iOS ficou de fora de propósito: lá o comportamento já foi testado em uso, e
mudá-lo por causa de um problema que a plataforma não tem seria trocar o certo
pelo duvidoso.

## O que ainda depende de um aparelho de verdade

Duas coisas não dá para decidir sem ver:

- **O teclado virtual.** No Android ele redimensiona a tela por padrão. Se a
  imagem do computador ficar deformada ao digitar, o ajuste é
  `resizeToAvoidBottomInset`. Não foi mexido porque o comportamento atual está
  testado no iPhone, e mudar no escuro trocaria um problema conhecido por um
  desconhecido.
- **Confirmar antes de sair.** Talvez o "voltar" deva perguntar quando há sessão
  ativa. Talvez isso só irrite. É decisão de quem usou.

## Decisões que estão no `codemagic.yaml`

Três ajustes são obrigatórios e o build **falha de propósito** se algum deixar
de ser aplicado — a pasta `android/` é gerada pelo template do Flutter a cada
execução, e template muda de forma entre versões.

1. **`FlutterFragmentActivity`.** O `local_auth` (biometria) exige essa classe;
   com a padrão, a biometria não falha — derruba o app.
2. **Permissão de INTERNET.** O template só a declara nos manifestos de debug e
   profile. Sem acrescentá-la, o APK de release **não conecta** — e o build
   passa. É o defeito que só aparece na versão que se distribui.
3. **Remover CAMERA e RECORD_AUDIO.** Elas vêm do manifesto do `flutter_webrtc`
   e são mescladas no nosso. O Deskside só **recebe** vídeo, nunca liga a
   câmera. Uma ficha de loja dizendo que um app de controle remoto pede câmera e
   microfone destrói a confiança de que a venda depende.

E um que fica em aberto: `usesCleartextTraffic="true"`, para o campo "Servidor"
aceitar `http://IP:8000` na rede local. Antes da Play Store isso deve virar uma
*network security config* restrita às faixas locais, em vez de liberar texto
puro para qualquer endereço.
