# Deploy do backend no Oracle Cloud Free + DuckDNS (HTTPS)

Coloca o backend do RemoteOne num servidor **sempre ligado e independente** dos
computadores controlados — controlável de qualquer lugar (não só no Wi‑Fi de
casa) e com **HTTPS** (senha nunca trafega em texto puro).

Visão geral: um VPS grátis da Oracle roda o backend em Docker, atrás do **Caddy**
(que cuida do certificado HTTPS sozinho). Um domínio grátis do **DuckDNS** aponta
para o IP do VPS. Depois, app e agentes apontam para esse domínio.

---

## 1. Criar a conta na Oracle Cloud

1. Acesse <https://www.oracle.com/cloud/free/> e clique em **Start for free**.
2. Cadastre-se (e‑mail, país). Exige **cartão de crédito** só para verificação —
   os recursos "Always Free" **não são cobrados**. Um cartão internacional
   funciona; a Oracle faz uma cobrança simbólica de verificação e estorna.
3. Escolha uma **Home Region** próxima (ex.: `Brazil East (São Paulo)`).
   Atenção: a região não muda depois.

## 2. Criar a máquina (VM Always Free)

1. No menu → **Compute → Instances → Create Instance**.
2. **Image and shape**:
   - Imagem: **Canonical Ubuntu 22.04**.
   - Shape: **Ampere (ARM) VM.Standard.A1.Flex** — marque como *Always Free*
     (ex.: 1 OCPU / 6 GB é de sobra). Se faltar capacidade ARM, use a
     **VM.Standard.E2.1.Micro** (AMD, também Always Free).
3. **Add SSH keys**: deixe **Generate a key pair for me** e **baixe a chave
   privada** (guarde bem — é como você entra no servidor).
4. **Create**. Anote o **Public IP address** que aparece.

> **Deu "Out of capacity for shape VM.Standard.A1.Flex"?** É comum: a cota ARM
> grátis vive esgotada. Opções:
> - **Mais garantido:** troque o shape para **VM.Standard.E2.1.Micro** (AMD,
>   também Always Free — quase sempre tem vaga). Ela tem **1 GB de RAM**, então
>   no passo 9 use o compose **leve** (`docker-compose.lite.yml`, com SQLite e
>   sem Postgres/Redis) em vez do de produção.
>   > Ao trocar para a AMD, **reescolha a imagem** (Change image → Ubuntu 22.04):
>   > a build precisa ser **x86_64/amd64**, não a ARM (aarch64). Se der
>   > *"Shape ... is not valid for image ..."*, é a imagem ARM ainda
>   > selecionada — arquitetura da imagem tem que casar com o shape.
> - **Insistir no ARM:** tente outro *Availability Domain* (AD-1/2/3) e/ou repita
>   depois de um tempo — a capacidade libera. Fora de horário de pico ajuda.

## 3. IP público fixo (reservado)

Para o IP não mudar em reinícios:

1. **Instance → Attached VNICs → (a VNIC) → IP addresses**.
2. No IP público, **Edit** → troque de *Ephemeral* para **Reserved** (Reserve a
   new public IP). Confirme.

## 4. Abrir as portas 80 e 443

São **dois** lugares (a pegadinha clássica da Oracle):

**a) Security List (firewall da nuvem):**
1. **Networking → Virtual Cloud Networks →** sua VCN **→ Security Lists →**
   Default Security List.
2. **Add Ingress Rules**, duas regras:
   - Source `0.0.0.0/0`, IP Protocol **TCP**, Destination Port **80**.
   - Source `0.0.0.0/0`, IP Protocol **TCP**, Destination Port **443**.

**b) Firewall do Ubuntu (dentro da VM):** conecte por SSH (passo 6) e rode:
```bash
sudo iptables -I INPUT 6 -m state --state NEW -p tcp --dport 80 -j ACCEPT
sudo iptables -I INPUT 6 -m state --state NEW -p tcp --dport 443 -j ACCEPT
sudo netfilter-persistent save
```

## 5. Domínio grátis no DuckDNS

1. Acesse <https://www.duckdns.org>, entre (Google/GitHub) e crie um subdomínio,
   ex.: `caio-remoteone` → vira `caio-remoteone.duckdns.org`.
2. No campo **current ip**, coloque o **IP público do VPS** (passo 2/3) e clique
   **update ip**.

## 6. Entrar no servidor por SSH

No seu PC (PowerShell), com a chave baixada no passo 2:
```powershell
ssh -i C:\caminho\sua-chave.key ubuntu@IP_DO_VPS
```
(No Ubuntu da Oracle o usuário é `ubuntu`.)

## 7. Instalar Docker

Na VM:
```bash
sudo apt update && sudo apt install -y docker.io docker-compose-plugin git
sudo usermod -aG docker $USER
# saia e entre de novo no SSH para o grupo valer:
exit
```
Reentre por SSH.

## 8. Baixar o projeto e configurar

```bash
git clone https://github.com/Cchaves20/RemoteOne.git
cd RemoteOne/deploy
cp .env.example .env
nano .env
```
No `.env`, preencha:
- `DOMAIN=caio-remoteone.duckdns.org` (o seu subdomínio),
- `REMOTEONE_JWT_SECRET=` um segredo longo (gere com `openssl rand -base64 48`),
- `POSTGRES_PASSWORD=` uma senha forte.

Salve (Ctrl+O, Enter, Ctrl+X).

## 9. Subir tudo

```bash
docker compose -f docker-compose.prod.yml up -d --build
```

> **Na VM AMD Micro (1 GB de RAM)** use o compose **leve** (SQLite, sem
> Postgres/Redis) — no `.env` basta `DOMAIN` e `REMOTEONE_JWT_SECRET`:
> ```bash
> docker compose -f docker-compose.lite.yml up -d --build
> ```
> (Nos comandos de manutenção mais abaixo, troque `docker-compose.prod.yml` por
> `docker-compose.lite.yml`.)

O Caddy pega o certificado HTTPS em alguns segundos. Teste **do seu celular/PC**:

```
https://caio-remoteone.duckdns.org/health
```
Deve responder `{"status":"ok"}` com o cadeado de HTTPS. 🎉

## 10. Apontar app e agentes para o VPS

- **App (celular):** no campo **Servidor**, use
  `https://caio-remoteone.duckdns.org` (sem porta — 443 é implícito).
- **Agente (cada PC):** instale apontando o WebSocket seguro:
  ```powershell
  powershell -ExecutionPolicy Bypass -File agent\scripts\install-agent-windows.ps1 -BackendUrl wss://caio-remoteone.duckdns.org/ws/agent
  ```

Como agora o backend é central e sempre ligado, **cadastre a conta uma vez** (é
um banco novo) e refaça o pareamento de cada computador. A partir daí você
controla qualquer um deles de qualquer lugar.

---

## Manutenção

- **Atualizar o backend** (após um `git pull`):
  ```bash
  cd ~/RemoteOne && git pull && cd deploy
  docker compose -f docker-compose.prod.yml up -d --build
  ```
- **Ver logs:** `docker compose -f docker-compose.prod.yml logs -f api`
- **Parar:** `docker compose -f docker-compose.prod.yml down` (os dados do
  Postgres ficam no volume).

## Segurança (bom saber)

- Só 80/443 ficam abertos; API/Postgres/Redis não têm porta pública.
- HTTPS/WSS criptografa tudo (login, tela, comandos).
- Troque `REMOTEONE_JWT_SECRET` e `POSTGRES_PASSWORD` por valores fortes e
  **nunca** versione o `.env`.
- Mantenha o SSH só com chave (a Oracle já faz isso por padrão).
