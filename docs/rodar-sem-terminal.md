# Instalar o agente (rodar sem terminal)

Para usar o RemoteOne no dia a dia — inclusive **desligar o PC pelo app** e
depois **acordá-lo com Wake-on-LAN** — o computador não pode depender de um
terminal aberto. O agente precisa:

- iniciar sozinho quando você faz login;
- rodar oculto, sem janela;
- voltar sozinho depois de reiniciar, suspender ou acordar por Wake-on-LAN.

> Por que isso importa para o desligar/WoL: se o agente só roda no terminal, ao
> desligar o PC pelo app não há como ele voltar — e mesmo acordando com
> Wake-on-LAN, nada reconecta.

## Instalar

Dois cliques em **`instalar.cmd`**, que fica ao lado do executável. É o caminho
mais curto e o que não erra caminho.

Pelo terminal, entre na pasta onde o executável está e chame-o com `.\` na
frente:

```powershell
cd C:\onde\voce\copiou
.\remoteone-agent.exe install wss://seu-servidor/ws/agent
```

O `.\` não é enfeite: o PowerShell **não** procura executável na pasta atual,
ao contrário do `cmd`. Sem ele a resposta é "não é reconhecido como nome de
cmdlet", que parece arquivo ausente e não é.

A URL é opcional: sem ela, vale a que já estiver configurada — e, se não houver
nenhuma, o backend da própria máquina (`ws://127.0.0.1:8000/ws/agent`).

O que o comando faz:

1. Encerra qualquer agente que já esteja rodando.
2. Copia o executável para `%LOCALAPPDATA%\Programs\RemoteOne`.
3. Grava a URL do backend em `%APPDATA%\remoteone\agent.conf`.
4. Põe um atalho oculto na pasta Inicializar do seu usuário.
5. Cria atalhos no **Menu Iniciar** e na **área de trabalho**.
6. Registra o programa em **Aplicativos instalados**, com botão de desinstalar.
7. Inicia o agente agora, sem esperar o próximo login.

Os atalhos abrem o programa que **já está rodando**, e não um segundo. O agente
reserva um nome no Windows ao subir; um segundo processo percebe que o nome já
é de alguém, pede a janela ao primeiro e sai. Sem essa guarda, o atalho seria
uma armadilha: dois agentes com o mesmo `device_id`, os dois conectados, e o
servidor entregando os comandos a um deles por sorteio - controle remoto pela
metade, sem erro nenhum explicando.

**Não precisa de administrador.** A instalação é da sua conta de usuário.

### Conferir

```powershell
.\remoteone-agent.exe status
```

```
Instalado em: C:\Users\voce\AppData\Local\Programs\RemoteOne\remoteone-agent.exe
Inicia com o Windows: sim
Backend: wss://seu-servidor/ws/agent
device_id: 6f3a…
```

"Inicia com o Windows: **não**" com o programa instalado é um estado real e
comum — alguém limpou a pasta Inicializar, ou um otimizador desativou a entrada.
É por isso que as duas linhas são separadas: juntas, elas esconderiam
exatamente o caso em que o computador some do app sem explicação.

### Desinstalar

Por **Aplicativos instalados** do Windows, por `desinstalar.cmd`, ou:

```powershell
.\remoteone-agent.exe uninstall
```

A configuração e o `device_id` **ficam** em `%APPDATA%\remoteone`. É de
propósito: reinstalar não deve obrigar a parear o computador de novo.

## Configuração

O arquivo é `%APPDATA%\remoteone\agent.conf`, no formato `CHAVE=valor`:

```
REMOTEONE_BACKEND_URL=wss://seu-servidor/ws/agent
REMOTEONE_VIDEO_MAX_WIDTH=1280
REMOTEONE_VIDEO_FPS=30
```

**Variável de ambiente vence o arquivo.** A ordem não é arbitrária: quem exporta
uma variável está fazendo um teste pontual — "roda esta vez apontando para outro
backend" — e essa intenção precisa vencer o que está gravado, senão o teste não
acontece e ninguém entende por quê.

Uma linha com erro de digitação é ignorada, e as outras continuam valendo: um
engano numa chave não pode impedir o agente de subir.

| Chave | O que faz |
|---|---|
| `REMOTEONE_BACKEND_URL` | Servidor a que o agente se conecta |
| `REMOTEONE_VIDEO_MAX_WIDTH` | Teto de largura do vídeo (custo de CPU por pixel) |
| `REMOTEONE_VIDEO_FPS` | Teto de quadros por segundo do vídeo |
| `REMOTEONE_VIDEO_BITRATE` | Taxa alvo do H.264, em bits por segundo |
| `REMOTEONE_STREAM_FPS` · `_MAX_WIDTH` · `_QUALITY` | O mesmo para o JPEG de reserva |
| `REMOTEONE_ICE_SERVERS` | STUN, separados por vírgula. Vazio = só rede local |
| `REMOTEONE_KEEP_AWAKE` | `1` (padrão) mantém o PC acordado na tomada; `0` desliga |
| `REMOTEONE_CONFIG_DIR` | Onde ficam o `device_id` e este arquivo |

Os tetos daqui são tetos mesmo: a qualidade adaptativa só **abaixa** a partir
deles (ver [`webrtc-plano.md`](webrtc-plano.md), Fase 4b).

`REMOTEONE_KEEP_AWAKE` também é mudado pelo app (menu do computador → **Manter
pronto**), e o agente grava a escolha aqui — ela precisa valer no próximo
login. O detalhe de por que este recurso existe está em
[`pc-sempre-pronto.md`](pc-sempre-pronto.md).

## Vindo do instalador antigo

O instalador de PowerShell guardava a URL do backend numa **variável de
ambiente do usuário**, e variável vence arquivo. Se ela sobrou, o `status`
avisa:

```
Backend: wss://antigo/ws/agent (da variável de ambiente, que vence o arquivo)
```

Enquanto ela existir, trocar o servidor no `agent.conf` não terá efeito. Para
apagá-la, no PowerShell:

```powershell
[Environment]::SetEnvironmentVariable("REMOTEONE_BACKEND_URL", $null, "User")
```

ou, em qualquer terminal:

```
reg delete "HKCU\Environment" /v REMOTEONE_BACKEND_URL /f
```

Depois feche e abra o terminal: a variável só some para processos novos.

`setx REMOTEONE_BACKEND_URL ""` **não** serve — o `setx` recusa valor vazio com
"sintaxe inválida". Ele grava variáveis; quem apaga é o registro.

O atalho antigo na pasta Inicializar tem o mesmo nome do atual
(`RemoteOneAgent.vbs`) e é substituído pelo `install`. Para conferir, abra-o no
Bloco de Notas: o caminho lá dentro tem que apontar para
`AppData\Local\Programs\RemoteOne`, e não para `target\release`.

## A janela e o ícone ao lado do relógio

O agente tem um **ícone na bandeja**, ao lado do relógio. É a prova de que ele
está de pé sem ninguém abrir terminal. Duplo clique abre a janela; o clique
direito traz **Abrir o RemoteOne** e **Sair**.

A janela mostra o computador, o servidor, o identificador, se a conexão está de
pé (e o motivo, quando não está) e o estado do "manter pronto".

**Fechar no X esconde, não encerra.** Sair de verdade é só pelo menu da
bandeja. Um X que encerrasse o agente faria o computador sumir do aplicativo, e
fechar uma janela é o gesto mais inocente que existe — ninguém associaria uma
coisa à outra.

Os atalhos do Menu Iniciar e da área de trabalho abrem **esta** janela, do
agente que já está rodando.

### Se a janela não abrir

Acontece em **máquina virtual** e em **sessão de Área de Trabalho Remota**, que
não oferecem placa de vídeo de verdade. O agente continua inteiro: conecta,
pareia e é controlado normalmente — só a janela e o ícone da bandeja não
aparecem. O `agent.log` diz o motivo.

Nesse caso o código de pareamento vem numa **caixa de mensagem do Windows**,
que não depende de placa de vídeo nenhuma.

A primeira versão desta janela usava OpenGL e morria com *"requires opengl
2.0+"* nessas máquinas. Hoje usa DX12 e, quando não há placa de vídeo alguma
disponível, o **renderizador por software** do próprio Windows. Uma janela com
cinco linhas de texto não perde nada rodando por software.

O `agent.log` diz qual foi usado, na linha `janela: usando ...`.

## Onde vejo o código de pareamento?

Quando o agente precisa parear, a **janela abre sozinha** com o código em letra
grande e um botão de copiar. O código também fica em
**`%APPDATA%\remoteone\pairing-code.txt`** (cole `%APPDATA%\remoteone` na
barra do Explorer).

O código reaparece sozinho se você **remover o computador no app** — não precisa
reiniciar nada. E some da tela assim que o pareamento acontece: um código já
usado continuar em letra garrafal seria convidar alguém a digitá-lo de novo e
concluir que o pareamento está quebrado.

> Antes disto havia uma caixa de mensagem disparada por um `powershell.exe`.
> Custava cerca de um segundo, piscava, perdia os acentos (só aceitava ASCII) e
> é o padrão que antivírus marcam: um processo em segundo plano invocando
> PowerShell. Um balão de notificação seria pior que a janela — some em
> segundos, e um código de pareamento é justamente o que a pessoa perde e
> precisa reencontrar.

## Duas escolhas que valem explicação

**Pasta Inicializar, e não um serviço do Windows.** Um serviço roda antes do
login, na sessão 0, **sem área de trabalho**: não conseguiria capturar a tela
nem mover o mouse, que é tudo o que este agente faz. Ele precisa da sessão
interativa, e por isso inicia no login. É também o que dispensa administrador.

**A instalação vive dentro do executável**, e não num script à parte. O script
de PowerShell que existia aqui antes exigia o código-fonte e o Rust instalados,
apontava para dentro do repositório (mover a pasta quebrava o início automático,
sem aviso) e não aparecia em "Aplicativos instalados". Além disso, um `.ps1` não
entra na verificação cruzada de tipos para Windows nem tem teste — e este
projeto já perdeu tempo com código que ninguém verifica.

## O aviso azul do Windows

Na primeira execução o SmartScreen mostra "O Windows protegeu o computador".
É esperado: o executável não é assinado, e assinatura de código custa dinheiro
(uns US$ 200/ano). Clique em **Mais informações → Executar assim mesmo**.

Isso muda quando o produto for vendido; até lá, é o preço de distribuir um
binário próprio.

## O backend

Se o backend roda no VPS, não há o que fazer aqui — a URL do `install` já
aponta para lá.

Se roda **nesta máquina** (desenvolvimento), suba a stack destacada uma vez:

```bash
cd backend
docker compose up -d --build
```

O compose usa `restart: unless-stopped`, então a API volta sozinha ao ligar o
PC — desde que o Docker Desktop também suba no login: **Settings → General →
Start Docker Desktop when you sign in**.

## Instalar em outro computador

Não é preciso o código-fonte nem o Rust do outro lado. Copie dois arquivos:

```
agent\target\release\remoteone-agent.exe
agent\scripts\instalar.cmd
```

Ponha os dois na mesma pasta da outra máquina (pendrive, OneDrive, pasta de
rede) e dê dois cliques no `instalar.cmd`.

Cada computador gera o **próprio** `device_id` na primeira execução, então ele
mostra um código de pareamento novo. Digite-o no app, na mesma conta, e a
máquina entra na sua lista ao lado das outras.

**Se aparecer "VCRUNTIME140.dll não foi encontrado"**: o executável depende do
runtime do Visual C++, que a maioria das máquinas já tem mas uma instalação
limpa pode não ter. Instale o *Microsoft Visual C++ Redistributable (x64)*, que
é gratuito.

## Verificar de ponta a ponta

1. Reinicie o PC e **não abra terminal nenhum**.
2. `.\remoteone-agent.exe status` (ou o app) deve mostrar o agente de pé.
3. No app, o computador aparece **Online**.
4. Desligar pelo app e depois acordar com Wake-on-LAN passa a funcionar sem
   ninguém tocar na máquina.

Para o ciclo completo sem tocar no PC (IP fixo, backend no boot, login
automático), veja [`pc-sempre-pronto.md`](pc-sempre-pronto.md).
