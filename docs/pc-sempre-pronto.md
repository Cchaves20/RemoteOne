# Deixar o PC pronto para controle remoto sem tocar nele

Objetivo: controlar o computador pelo app **sem precisar encostar nele nem
abrir terminal**.

## O caminho curto: não deixar dormir

O agente já faz isto sozinho, e vem **ligado de fábrica**. Enquanto o
computador estiver na tomada, ele pede ao Windows que não suspenda; ao cair
para a bateria, solta o pedido para não descarregar o aparelho com a tampa
fechada.

Não precisa de administrador, de BIOS, de placa de rede nem de roteador. A
tela continua apagando normalmente — é dela que vem quase toda a economia de
energia.

**Por que isto e não Wake-on-LAN.** Acordar uma máquina adormecida exige a
placa de rede armada no firmware e no driver, e isso varia de computador para
computador. Não é uma limitação do Deskside: nenhum programa consegue
configurar aquilo por conta própria, porque uma máquina desligada não roda
programa nenhum. Já *não adormecer* é uma chamada de sistema que existe em
qualquer Windows desde o XP.

No app: menu do computador → **Manter pronto**. A tela mostra três coisas
diferentes, e a distinção importa:

| O que aparece | O que significa |
|---|---|
| Ativo agora | O computador não vai dormir |
| Ligado, mas sem efeito | Está na bateria; volta sozinho na tomada |
| Desligado | Dorme normalmente, e voltar depende de Wake-on-LAN |

"Ligado" e "segurando" são estados diferentes de propósito. Um notebook na
bateria com a chave ligada vai dormir do mesmo jeito, e juntar as duas
informações numa só prometeria um computador alcançável que some justamente
quando a pessoa está longe.

Para desligar de vez numa máquina (um servidor com energia cara, por exemplo),
a chave do app basta. À mão, `DESKSIDE_KEEP_AWAKE=0` no `agent.conf`.

### O que isto não cobre

Fechar a tampa do notebook, desligar pelo menu Iniciar e queda de energia. Nos
três casos o computador vai dormir ou desligar de verdade, e aí o **Wake-on-LAN
continua sendo o caminho** — ele não foi substituído, virou a rede de
segurança.

## O caminho completo (Wake-on-LAN e ligar sem ninguém em casa)

Se você quer poder **desligar o PC pelo app** e acordá-lo depois, ou se prefere
suspender para economizar energia, aí sim entram os três ajustes abaixo. Eles
também são o que faz o computador voltar sozinho depois de uma queda de luz.

Três coisas precisam estar de pé sozinhas quando o Windows liga:

1. **IP fixo** — pra você nunca mais reeditar o campo *Servidor* no app.
2. **Backend no boot** — a API que o app acessa.
3. **Login automático do Windows** — porque backend e agente só sobem *depois*
   do login.

> Por que dá "Operation timed out" no app quando o backend está fora: sem o
> backend rodando, ninguém escuta a porta 8000 e o Firewall do Windows
> **descarta** a conexão calada — por isso o app espera e estoura o tempo, em
> vez de dizer "conexão recusada".

Faça no computador que você quer controlar (ex.: Dell G5).

---

## 1. IP fixo (reserva no roteador)

Assim o PC recebe sempre o mesmo IP (ex.: `192.168.0.58`).

1. No PC, descubra o **endereço físico (MAC)** do Wi‑Fi:
   ```powershell
   ipconfig /all
   ```
   Anote o **Endereço Físico** do adaptador de **Wi‑Fi** (ex.: `AA-BB-CC-11-22-33`)
   e o **IPv4** atual.
2. Entre no painel do **roteador** (normalmente `http://192.168.0.1` no
   navegador; usuário/senha ficam numa etiqueta embaixo do aparelho).
3. Procure **DHCP** → **Reserva de endereço / Address Reservation / DHCP
   estático**.
4. Adicione uma reserva ligando o **MAC** do Wi‑Fi ao IP desejado
   (`192.168.0.58`). Salve e reinicie o roteador se ele pedir.

Pronto: esse PC sempre pega `192.168.0.58`. (Alternativa sem mexer no roteador
é IP estático no Windows, mas a reserva no roteador é mais segura e evita
conflitos.)

---

## 2. Backend sobe sozinho no boot

Há dois caminhos. **O recomendado é o serviço**, porque sobe **antes do login**
(um servidor de rede não precisa de desktop) — assim o backend nunca mais
depende de alguém logar.

### Opção A (recomendada): backend como serviço do Windows (sem login, sem Docker)

Abra o **PowerShell como Administrador** e rode:

```powershell
cd C:\Users\SEU_USUARIO\Deskside\backend
powershell -ExecutionPolicy Bypass -File scripts\install-backend-service-windows.ps1
```

Isso cria um ambiente Python, roda o backend com **SQLite** (dispensa
Postgres/Redis/Docker), libera a porta 8000 no Firewall e registra um serviço
(conta SYSTEM) que **inicia no boot, antes do login**. Teste em
`http://localhost:8000/health`.

> Atenção: o serviço usa um **banco SQLite novo** (não o do Docker). Cadastre a
> conta uma vez no app e refaça o pareamento — é só uma vez.

Para remover: `scripts\uninstall-backend-service-windows.ps1` (como admin).

### Opção B: Docker destacado (precisa de login)

1. Suba a stack **destacada** uma vez (o `-d` libera o terminal):
   ```powershell
   cd C:\Users\SEU_USUARIO\Deskside\backend
   docker compose up -d --build
   ```
   O `docker-compose.yml` já usa `restart: unless-stopped`, então os containers
   voltam sozinhos quando o Docker inicia.
2. Faça o **Docker Desktop** iniciar no login:
   **Docker Desktop → engrenagem (Settings) → General →** marque
   **“Start Docker Desktop when you sign in”** → **Apply & restart**.

Teste no próprio PC: abra `http://localhost:8000/health` no navegador → deve
responder `{"status":"ok"}`.

---

## 3. Login automático do Windows (para o agente)

Com o backend como **serviço** (Opção A), ele já sobe sem login. Mas o
**agente** ainda precisa da sessão logada — ele tem que **ver a tela** e
**mexer no mouse/teclado**, e isso só existe depois do login (regra do Windows:
serviços rodam na Sessão 0, sem desktop). Por isso o auto-login continua sendo o
jeito mais simples de deixar o agente pronto sozinho.

Com o autologon, o PC liga → loga sozinho → o agente sobe (e, se você usar a
Opção B do backend, o Docker também).

1. Tecla **Windows + R**, digite `netplwiz` e Enter.
2. Selecione sua conta e **desmarque** *“Os usuários devem digitar um nome de
   usuário e uma senha para usar este computador”*. Clique **Aplicar**.
3. Digite sua senha duas vezes para confirmar. **OK**.

> Se a opção (o checkbox) não aparecer: vá em **Configurações → Contas → Opções
> de entrada** e desative *“Exigir entrada do Windows Hello para contas da
> Microsoft”*; depois volte ao `netplwiz`.

4. Ainda em **Opções de entrada**, ajuste *“Se você esteve ausente, quando o
   Windows deve exigir uma nova entrada?”* para **Nunca** — senão, ao acordar da
   suspensão (ex.: por Wake-on-LAN) o PC para na tela de bloqueio e o agente não
   consegue ver a tela nem controlar.

Cuidado: com autologon, qualquer pessoa que ligar o PC entra direto na sua
conta. Use só se o computador fica em local de confiança.

---

## 4. Conferir o ciclo completo

1. **Reinicie o PC** e não toque em nada.
2. Ele deve logar sozinho; em ~1 min o Docker sobe e o agente também.
3. No PC: `http://localhost:8000/health` responde, e
   `http://localhost:8000/api/v1/agents` mostra o agente **online**.
4. No celular (mesma rede, *Servidor* = `http://192.168.0.58:8000`): o
   computador aparece **Online**. Desligar pelo app e depois acordar com
   Wake‑on‑LAN passam a funcionar de ponta a ponta.

---

## Recuperar o acesso agora (sem esperar os ajustes)

Se você acabou de religar o PC e o app dá timeout, é só subir o backend uma vez.
Com o **serviço** (Opção A) instalado, ele já sobe sozinho no boot — não precisa
fazer nada. Se ainda estiver no Docker (Opção B):

```powershell
cd C:\Users\SEU_USUARIO\Deskside\backend
docker compose up -d
```

Depois disso o app entra normalmente. Os passos acima fazem isso acontecer
sozinho nas próximas vezes.

> Observação sobre Wake‑on‑LAN: ele acorda o PC que está **suspenso/desligado
> mas com energia**, e funciona **na mesma rede local** — o app usa outro
> computador seu já ligado ali para soltar o pacote. Acordar pela internet
> exige liberar/rotear o pacote mágico no roteador, o que a tela "Ligar o PC à
> distância" explica.
>
> Se os ajustes de BIOS/placa forem trabalhosos demais na sua máquina, a saída
> é a do começo desta página: não deixar dormir. Foi para isso que ela existe.
