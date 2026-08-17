# Instalar o agente (rodar sem terminal)

Para usar o Deskside no dia a dia — inclusive **desligar o PC pelo app** e
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
.\deskside-agent.exe install wss://seu-servidor/ws/agent
```

O `.\` não é enfeite: o PowerShell **não** procura executável na pasta atual,
ao contrário do `cmd`. Sem ele a resposta é "não é reconhecido como nome de
cmdlet", que parece arquivo ausente e não é.

A URL é opcional, e enquanto o projeto está em teste **instalar sem ela já
funciona**: o padrão de fábrica é o servidor do Deskside. A ordem é esta —
o que já estiver gravado no `agent.conf` primeiro, e o padrão só quando não há
nada.

Duas consequências que economizam uma investigação:

- **Instalar sem URL não troca o servidor.** Num agente já configurado, o
  `install` sem argumento preserva o endereço que estava lá. Para mudar, passe
  a URL nova.
- **Um agente antigo instalado sem URL ficou apontando para a própria
  máquina** (`ws://127.0.0.1:8000/ws/agent`, o padrão de antes). O sintoma é a
  janela dizendo "Sem conexão" sem mais nada. Conserta-se com um
  `install wss://.../ws/agent`.

Para conferir para onde ele aponta, `deskside-agent.exe status`.

Para desenvolver contra o backend local, compile com o padrão trocado — assim
não é preciso editar o código:

```powershell
$env:DESKSIDE_DEFAULT_BACKEND = "ws://127.0.0.1:8000/ws/agent"
cargo build --release
```

O que o comando faz:

1. Encerra qualquer agente que já esteja rodando.
2. Copia o executável para `%LOCALAPPDATA%\Programs\Deskside`.
3. Grava a URL do backend em `%APPDATA%\deskside\agent.conf`.
4. Cria uma **tarefa agendada** que sobe o agente oculto ao fazer logon. Se ela
   não puder ser criada, cai para um atalho oculto na pasta Inicializar — ver
   "Por que uma tarefa agendada" abaixo.
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
.\deskside-agent.exe status
```

```
Instalado em: C:\Users\voce\AppData\Local\Programs\Deskside\deskside-agent.exe
Inicia com o Windows: sim
Backend: wss://seu-servidor/ws/agent
device_id: 6f3a…
```

"Inicia com o Windows: **não**" com o programa instalado é um estado real e
comum — alguém limpou a pasta Inicializar, ou um otimizador desativou a entrada.
É por isso que as duas linhas são separadas: juntas, elas esconderiam
exatamente o caso em que o computador some do app sem explicação.

A linha também diz **por qual mecanismo** ele sobe, e isso importa porque um dos
dois é muito mais rápido. Numa queixa de "o agente demora a ficar disponível
depois que eu ligo o notebook", esta é a primeira linha a olhar.

### Por que uma tarefa agendada, e não a pasta Inicializar

A pasta Inicializar é a forma mais lenta que existe de subir no logon. Quem a
processa é o Explorer, **depois** de terminar de carregar, e o Windows 10/11
ainda aplica um retardo próprio ao que está nela. Num notebook isso são dezenas
de segundos entre entrar na conta e o computador ficar alcançável — e nesse
intervalo o app mostra o computador offline, que é indistinguível de defeito.

Uma tarefa com disparo "ao fazer logon" não espera o Explorer.

Quatro ajustes da tarefa não são enfeite. Os padrões do Agendador foram pensados
para tarefas de manutenção, e três deles quebrariam este agente em silêncio:

- **não iniciar na bateria** é o padrão. Num notebook fora da tomada — o caso
  mais comum — o agente simplesmente não subiria, e nada diria por quê;
- **encerrar ao sair da tomada** também é o padrão, e mataria o agente no meio
  do uso;
- **limite de execução de três dias**: ao fim dele a tarefa é morta, e um
  computador que fica ligado a semana toda perderia o agente;
- **prioridade 7** (o padrão) o Windows traduz em prioridade *abaixo do normal*
  para o processo — justamente no logon, quando há disputa por disco e CPU.

**Uma das duas, nunca as duas.** Com os dois mecanismos ativos, dois agentes
subiriam a cada logon. A guarda de instância única faria o segundo sair, mas ela
também pede que o primeiro **mostre a janela** — e uma janela abrindo sozinha a
cada vez que se liga o computador seria uma troca terrível por alguns segundos
de partida. Por isso, quando a tarefa é criada, o `install` apaga o atalho da
pasta Inicializar.

### Desinstalar

Por **Aplicativos instalados** do Windows, por `desinstalar.cmd`, ou:

```powershell
.\deskside-agent.exe uninstall
```

A configuração e o `device_id` **ficam** em `%APPDATA%\deskside`. É de
propósito: reinstalar não deve obrigar a parear o computador de novo.

## Configuração

O arquivo é `%APPDATA%\deskside\agent.conf`, no formato `CHAVE=valor`:

```
DESKSIDE_BACKEND_URL=wss://seu-servidor/ws/agent
DESKSIDE_VIDEO_MAX_WIDTH=1280
DESKSIDE_VIDEO_FPS=30
```

**Variável de ambiente vence o arquivo.** A ordem não é arbitrária: quem exporta
uma variável está fazendo um teste pontual — "roda esta vez apontando para outro
backend" — e essa intenção precisa vencer o que está gravado, senão o teste não
acontece e ninguém entende por quê.

Uma linha com erro de digitação é ignorada, e as outras continuam valendo: um
engano numa chave não pode impedir o agente de subir.

| Chave | O que faz |
|---|---|
| `DESKSIDE_BACKEND_URL` | Servidor a que o agente se conecta |
| `DESKSIDE_VIDEO_MAX_WIDTH` | Teto de largura do vídeo (custo de CPU por pixel) |
| `DESKSIDE_VIDEO_FPS` | Teto de quadros por segundo do vídeo |
| `DESKSIDE_VIDEO_BITRATE` | Taxa alvo do H.264, em bits por segundo |
| `DESKSIDE_STREAM_FPS` · `_MAX_WIDTH` · `_QUALITY` | O mesmo para o JPEG de reserva |
| `DESKSIDE_ICE_SERVERS` | STUN, separados por vírgula. Vazio = só rede local |
| `DESKSIDE_KEEP_AWAKE` | `1` (padrão) mantém o PC acordado na tomada; `0` desliga |
| `DESKSIDE_CONFIG_DIR` | Onde ficam o `device_id` e este arquivo |

Os tetos daqui são tetos mesmo: a qualidade adaptativa só **abaixa** a partir
deles (ver [`webrtc-plano.md`](webrtc-plano.md), Fase 4b).

`DESKSIDE_KEEP_AWAKE` também é mudado pelo app (menu do computador → **Manter
pronto**), e o agente grava a escolha aqui — ela precisa valer no próximo
login. O detalhe de por que este recurso existe está em
[`pc-sempre-pronto.md`](pc-sempre-pronto.md).

## Vindo da versão RemoteOne

O projeto mudou de nome. Ao subir pela primeira vez, o agente **traz sozinho** a
configuração antiga de `%APPDATA%\remoteone` para `%APPDATA%\deskside`,
incluindo o `device_id` e trocando o prefixo das chaves de `REMOTEONE_` para
`DESKSIDE_`.

Isso importa por um motivo só: o `device_id` é o que identifica a máquina no
aplicativo. Sem a migração, cada computador apareceria como novo, pedindo
pareamento, e o antigo ficaria na lista como um fantasma que nunca mais fica
online.

**A pasta antiga não é apagada.** Copiar custa alguns quilobytes e mantém a
volta atrás possível. Se algo sair errado, ela está lá inteira.

A migração só acontece quando a pasta nova **ainda não existe** — rodar duas
vezes não sobrescreve configuração nova com a velha.

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
[Environment]::SetEnvironmentVariable("DESKSIDE_BACKEND_URL", $null, "User")
```

ou, em qualquer terminal:

```
reg delete "HKCU\Environment" /v DESKSIDE_BACKEND_URL /f
```

Depois feche e abra o terminal: a variável só some para processos novos.

`setx DESKSIDE_BACKEND_URL ""` **não** serve — o `setx` recusa valor vazio com
"sintaxe inválida". Ele grava variáveis; quem apaga é o registro.

O `DesksideAgent.vbs` agora mora **ao lado do executável**, em
`AppData\Local\Programs\Deskside`: é ele que a tarefa agendada chama. Uma cópia
na pasta Inicializar só existe quando a tarefa não pôde ser criada. Para conferir, abra-o no
Bloco de Notas: o caminho lá dentro tem que apontar para
`AppData\Local\Programs\Deskside`, e não para `target\release`.

## A janela e o ícone ao lado do relógio

O agente tem um **ícone na bandeja**, ao lado do relógio. É a prova de que ele
está de pé sem ninguém abrir terminal. Duplo clique abre a janela; o clique
direito traz **Abrir o Deskside** e **Sair**.

A janela mostra o computador, o servidor, o identificador, se a conexão está de
pé (e o motivo, quando não está) e o estado do "manter pronto".

**Fechar no X esconde, não encerra.** Sair de verdade é só pelo menu da
bandeja. Um X que encerrasse o agente faria o computador sumir do aplicativo, e
fechar uma janela é o gesto mais inocente que existe — ninguém associaria uma
coisa à outra.

Os atalhos do Menu Iniciar e da área de trabalho abrem **esta** janela, do
agente que já está rodando.

### Máquinas sem placa de vídeo

Acontece em **máquina virtual**, em **sessão de Área de Trabalho Remota** e em
Windows enxuto de nuvem. Numa VM real este projeto encontrou o caso extremo:
**zero adaptadores** — sem Vulkan, sem DX12, sem OpenGL 2.0, e nem o
renderizador por software do Windows aparecendo.

Nessas máquinas o Deskside cai num modo mais simples, e **avisa disso na
própria tela de estado**:

- o **ícone ao lado do relógio continua lá**, com o menu de sempre;
- o estado e o código de pareamento aparecem em **caixas do próprio Windows**,
  que desenham sem placa de vídeo;
- o controle remoto funciona **normalmente** — captura de tela, teclado, mouse,
  som, arquivos. Nada disso depende da janela.

O que se perde é só a janela bonita. O `agent.log` diz qual caminho foi usado:
`janela: usando <adaptador>` quando há placa, `bandeja simples` quando não há.

A ordem de tentativa é: placa dedicada, integrada, virtual, software e, por
fim, o modo sem placa nenhuma.

## Onde vejo o código de pareamento?

Quando o agente precisa parear, a **janela abre sozinha** com o código em letra
grande e um botão de copiar. O código também fica em
**`%APPDATA%\deskside\pairing-code.txt`** (cole `%APPDATA%\deskside` na
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
agent\target\release\deskside-agent.exe
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
2. `.\deskside-agent.exe status` (ou o app) deve mostrar o agente de pé.
3. No app, o computador aparece **Online**.
4. Desligar pelo app e depois acordar com Wake-on-LAN passa a funcionar sem
   ninguém tocar na máquina.

Para o ciclo completo sem tocar no PC (IP fixo, backend no boot, login
automático), veja [`pc-sempre-pronto.md`](pc-sempre-pronto.md).
