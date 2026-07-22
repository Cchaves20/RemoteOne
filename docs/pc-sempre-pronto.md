# Deixar o PC pronto para controle remoto sem tocar nele

Objetivo: ligar/desligar e controlar o computador pelo app **sem precisar
encostar nele nem abrir terminal** — inclusive depois de desligar pelo app e
acordar com Wake-on-LAN.

Para isso, três coisas precisam estar de pé sozinhas quando o Windows liga:

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

## 2. Backend sobe sozinho no boot (Docker)

1. Suba a stack **destacada** uma vez (o `-d` libera o terminal):
   ```powershell
   cd C:\Users\SEU_USUARIO\RemoteOne\backend
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

## 3. Login automático do Windows

Backend (Docker) e agente (pasta Inicializar) só sobem **depois** que você
loga. Com o autologon, o PC liga → loga sozinho → tudo sobe.

1. Tecla **Windows + R**, digite `netplwiz` e Enter.
2. Selecione sua conta e **desmarque** *“Os usuários devem digitar um nome de
   usuário e uma senha para usar este computador”*. Clique **Aplicar**.
3. Digite sua senha duas vezes para confirmar. **OK**.

> Se a opção (o checkbox) não aparecer: vá em **Configurações → Contas → Opções
> de entrada** e desative *“Exigir entrada do Windows Hello para contas da
> Microsoft”*; depois volte ao `netplwiz`.

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

Se você acabou de religar o PC e o app dá timeout, é só subir o backend uma vez:

```powershell
cd C:\Users\SEU_USUARIO\RemoteOne\backend
docker compose up -d
```

Depois disso o app entra normalmente. Os passos 1–3 acima fazem isso acontecer
sozinho nas próximas vezes.

> Observação sobre Wake‑on‑LAN: ele acorda o PC que está **suspenso/desligado
> mas com energia**, e funciona **na mesma rede local**. Acordar pela internet
> (fora de casa) exige liberar/rotear o pacote mágico no roteador — tratado no
> recurso 9 (próximo lote).
