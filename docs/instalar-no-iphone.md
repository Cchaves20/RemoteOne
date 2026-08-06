# Instalar o app no iPhone/iPad sem Mac (sideload grátis)

Como levar o app ao iPhone físico usando um Apple ID grátis, sem possuir um
Mac e sem a conta paga da Apple. O fluxo:

**Codemagic compila o `.ipa` → você baixa → Sideloadly instala no iPhone →
o app aponta para o IP do computador → você controla o PC.**

> ⚠️ **Limitação do Apple ID grátis:** o app assinado assim **expira em 7
> dias** e precisa ser reinstalado pelo Sideloadly. Máximo de 3 apps por
> Apple ID. A primeira instalação é por cabo USB.

## O que você precisa

- Conta grátis no **Codemagic** (codemagic.io).
- **Sideloadly** (sideloadly.io) — programa no Windows.
- **Apple Devices** ou **iTunes** (Microsoft Store) — drivers USB do iPhone.
- Um **Apple ID** (o do seu iPhone serve; considere um secundário por
  segurança).
- Um **cabo USB** e o iPhone e o PC na **mesma rede Wi-Fi**.

## Etapa 1 — Gerar o .ipa no Codemagic

1. Acesse <https://codemagic.io> e entre com sua conta do GitHub.
2. Autorize o acesso ao repositório `Deskside`.
3. O Codemagic detecta o `codemagic.yaml`. Clique em **Start new build**.
4. Selecione:
   - **Branch:** `claude/testing-strategy-multiplatform-0nztwm`
   - **Workflow:** `iOS (.ipa não assinado para sideload)`
5. Aguarde (~15 min). Ao terminar, baixe o artefato
   **`Deskside-unsigned.ipa`** para o Dell.

## Etapa 2 — Preparar o Windows

1. Instale o **Apple Devices** (ou iTunes) pela Microsoft Store e abra uma vez.
2. Instale o **Sideloadly** de <https://sideloadly.io>.
3. Conecte o iPhone ao Dell por USB e, no iPhone, toque em **Confiar** neste
   computador.

## Etapa 3 — Instalar com o Sideloadly

1. Abra o Sideloadly. Ele deve mostrar o iPhone conectado.
2. Arraste o `Deskside-unsigned.ipa` para a janela.
3. Em **Apple ID**, informe seu Apple ID (com verificação em duas etapas, gere
   uma *senha de app* em appleid.apple.com e use-a aqui).
4. Clique em **Start**. O Sideloadly reassina e instala (alguns minutos).
5. No iPhone: **Ajustes → Geral → VPN e Gerenciamento de Dispositivo** →
   toque no seu Apple ID e em **Confiar**.
6. Abra o app **Deskside** na tela inicial.

## Etapa 4 — Apontar o app ao computador

1. No Dell, suba o backend (`docker compose up` em `backend/`) e o agente
   (`cargo run` em `agent/`).
2. Descubra o IP do Dell na rede: `ipconfig` (procure o "Endereço IPv4",
   algo como `192.168.0.10`).
3. No app, na tela de login, ponha em **Servidor**:
   `http://SEU_IP_DO_DELL:8000`.
4. Cadastre-se/entre, pareie com o código do agente e use o touchpad.

### Se o app não conectar (mas funciona no navegador do Dell)

O **Firewall do Windows** costuma bloquear conexões de fora na porta 8000.
Libere a porta (uma vez):

```powershell
New-NetFirewallRule -DisplayName "Deskside 8000" -Direction Inbound `
  -Protocol TCP -LocalPort 8000 -Action Allow
```

Confirme também que iPhone e Dell estão na **mesma** rede Wi-Fi.

## Renovar após 7 dias

Quando o app parar de abrir, reconecte o iPhone por USB e repita a Etapa 3
com o mesmo `.ipa` (não precisa recompilar, a menos que o app tenha mudado).
