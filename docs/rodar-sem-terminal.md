# Rodar sem terminal (agente e backend em segundo plano)

Para usar o RemoteOne no dia a dia — inclusive **desligar o PC pelo app** e
depois **acordá-lo com Wake-on-LAN** — o computador não pode depender de um
terminal aberto. O agente e o backend precisam:

- iniciar sozinhos quando o Windows liga/faz login;
- rodar ocultos (sem janela);
- voltar sozinhos depois de um reinício, suspensão ou Wake-on-LAN.

Este guia deixa os dois assim. Faça no computador que você quer controlar
(ex.: Dell G5 ou Surface).

> Por que isso importa para o desligar/WoL: se o agente só roda no terminal,
> ao desligar o PC pelo app não há como ele voltar — e mesmo acordando com
> Wake-on-LAN, nada reconecta. Com o agente como tarefa do Windows, ele sobe
> junto com o sistema e o controle volta sozinho.

## 1. Agente em segundo plano (tarefa do Windows)

Na pasta do projeto, abra o **PowerShell** e rode:

```powershell
powershell -ExecutionPolicy Bypass -File agent\scripts\install-agent-windows.ps1
```

O script compila o agente em modo release, cria uma **Tarefa Agendada**
(`RemoteOneAgent`) que o inicia **oculto a cada login** e o inicia na hora. A
tarefa reinicia o agente automaticamente se ele cair.

Se o backend **não** estiver no mesmo PC do agente, informe a URL:

```powershell
powershell -ExecutionPolicy Bypass -File agent\scripts\install-agent-windows.ps1 -BackendUrl ws://IP_DO_BACKEND:8000/ws/agent
```

(O padrão é `ws://127.0.0.1:8000/ws/agent`, que já serve quando o backend roda
na mesma máquina do agente.)

Para remover do início automático:

```powershell
powershell -ExecutionPolicy Bypass -File agent\scripts\uninstall-agent-windows.ps1
```

### Onde vejo o código de pareamento sem terminal?

Como o agente roda oculto, ao precisar parear ele:

- mostra o código numa **janelinha** (MessageBox) no seu desktop; e
- grava o código em **`%APPDATA%\remoteone\pairing-code.txt`**
  (cole `%APPDATA%\remoteone` na barra do Explorer para abrir a pasta).

O código também reaparece sozinho se você **remover o computador no app** — não
precisa reiniciar o agente.

## 2. Backend em segundo plano (Docker destacado)

Suba a stack **destacada** (o `-d` libera o terminal) uma vez:

```bash
cd backend
docker compose up -d --build
```

O `docker-compose.yml` já usa `restart: unless-stopped`, então a API volta
sozinha ao ligar o PC — desde que o Docker Desktop também suba no login:

1. Abra o **Docker Desktop** → engrenagem (**Settings**) → **General**.
2. Marque **Start Docker Desktop when you sign in**.
3. **Apply & restart**.

Pronto: ao ligar o computador, o Docker sobe, a API sobe com ele e você pode
fechar todas as janelas.

> Alternativa sem Docker: rodar o `uvicorn` como tarefa agendada. O Docker é o
> caminho recomendado porque já está configurado e mantém Postgres/Redis juntos.

## 3. Verificar

1. Reinicie o PC e **não abra nenhum terminal**.
2. No navegador do próprio PC, abra <http://localhost:8000/health> → deve
   responder `{"status":"ok"}` (backend no ar).
3. Abra <http://localhost:8000/api/v1/agents> → o agente deve aparecer na lista
   (online).
4. No app do celular (mesma rede Wi‑Fi, apontando para `http://IP_DO_PC:8000`),
   o computador aparece **Online**. Desligar/suspender pelo app e depois acordar
   com Wake-on-LAN passam a funcionar de ponta a ponta.

## Observações

- O agente roda na **sessão interativa** (necessário para capturar a tela e
  mover o mouse/teclado); por isso ele inicia no **login**, não antes dele. Se a
  conta do Windows exige senha, faça login uma vez após ligar (ou configure
  logon automático se o PC for de uso pessoal).
- Para **acordar** o PC com Wake-on-LAN, o computador precisa estar apenas
  desligado/suspenso (não sem energia) e com o recurso ativado na BIOS e na
  placa de rede. O passo a passo de WoL entra num próximo lote (recurso 9).
