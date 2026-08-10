# Deploy do backend no Oracle Cloud Free + DuckDNS (HTTPS)

Coloca o backend do Deskside num servidor **sempre ligado e independente** dos
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
POS=$(sudo iptables -L INPUT --line-numbers -n | awk '$2=="REJECT"{print $1; exit}')
sudo iptables -I INPUT ${POS:-1} -m state --state NEW -p tcp --dport 80 -j ACCEPT
sudo iptables -I INPUT ${POS:-1} -m state --state NEW -p tcp --dport 443 -j ACCEPT
sudo netfilter-persistent save
```

> **Por que descobrir a posição em vez de fixar um número.** A imagem da Oracle
> traz um `REJECT all` no fim da cadeia, e o `iptables` decide na **primeira**
> regra que casa. Uma regra inserida depois do REJECT é aceita pelo comando,
> salva pelo `netfilter-persistent` e **nunca aplicada** - o pacote já foi
> rejeitado. Este guia dizia `-I INPUT 6` porque era onde o REJECT estava numa
> instalação; noutra ele estava na 5, e todas as regras nasceram mortas.
>
> Confira sempre depois: `sudo iptables -L INPUT -n --line-numbers`. As suas
> regras têm que aparecer **acima** da linha do REJECT.

### Portas do TURN (vídeo direto no 4G/5G)

O TURN precisa de mais três coisas abertas, **nos mesmos dois lugares**. Sem
elas o vídeo direto não fecha quando o celular está na rede da operadora - que
é o caso mais comum fora de casa.

Na **Security List**, mais três regras com Source `0.0.0.0/0`:

| Protocolo | Porta | Para quê |
| --- | --- | --- |
| UDP | 3478 | onde o celular e o PC pedem o relay |
| TCP | 3478 | o mesmo, para redes que bloqueiam UDP |
| UDP | 49160-49200 | por onde o vídeo relayado passa |

E no firewall do Ubuntu, de novo **antes** do REJECT:
```bash
POS=$(sudo iptables -L INPUT --line-numbers -n | awk '$2=="REJECT"{print $1; exit}')
sudo iptables -I INPUT ${POS:-1} -m state --state NEW -p udp --dport 3478 -j ACCEPT
sudo iptables -I INPUT ${POS:-1} -m state --state NEW -p tcp --dport 3478 -j ACCEPT
sudo iptables -I INPUT ${POS:-1} -m state --state NEW -p udp --dport 49160:49200 -j ACCEPT
sudo netfilter-persistent save
```

> **O TURN é o único que sente isso.** As portas 80 e 443 continuam
> funcionando mesmo com as regras na posição errada, porque **contêiner Docker
> com porta publicada não passa pela cadeia INPUT** - o tráfego é redirecionado
> e atravessa a FORWARD. O coturn roda com `network_mode: host`, então ele é o
> único serviço daqui que depende da INPUT de verdade.
>
> É por isso que o sintoma é tão enganoso: o site responde, o `/health`
> responde, o app conecta, e só o vídeo direto falha - com uma mensagem sobre
> ICE que não sugere firewall nenhum.

### Swap: obrigatório numa VM de 1 GB

A imagem da Oracle vem **sem swap**. Com 1 GB de RAM e nenhuma paginação, um
pico de memória não deixa o sistema lento — ele **mata processos**. E como o
Docker e o `sshd` dividem a mesma memória, o que morre junto costuma ser a sua
conexão.

```bash
sudo fallocate -l 2G /swapfile
sudo chmod 600 /swapfile
sudo mkswap /swapfile
sudo swapon /swapfile
echo '/swapfile none swap sw 0 0' | sudo tee -a /etc/fstab
free -h
```

A linha no `/etc/fstab` é o que faz o swap voltar depois de reiniciar. Sem ela
a proteção some no primeiro reboot, e o problema volta meses depois sem
ninguém ligar uma coisa à outra.

**Como isso aparece quando falta.** Aconteceu aqui: um `docker compose build`
travou a máquina inteira no meio do `pip install`, o SSH caiu com
`Connection reset`, e depois nem conectava mais - respondendo
`Connection closed by ... port 22`, que é o `sshd` vivo sem memória para criar
a sessão. A única saída foi reiniciar a instância pelo console da Oracle.

O detalhe cruel: os deploys anteriores passavam porque o `pip install` vinha
do **cache de camadas** do Docker. O dia em que o cache foi invalidado - por
uma renomeação de pacote, no caso - o build rodou inteiro e derrubou tudo. A
falta de swap estava lá o tempo todo, esperando.

## 5. Domínio grátis no DuckDNS

1. Acesse <https://www.duckdns.org>, entre (Google/GitHub) e crie um subdomínio,
   ex.: `caio-remoteone` → vira `caio-remoteone.duckdns.org`.

   > O subdomínio ainda diz `remoteone` porque o projeto mudou de nome depois
   > dele existir. Trocá-lo exigiria certificado novo e reconfigurar cada
   > agente instalado - com o serviço fora do ar no intervalo. É mudança de
   > infraestrutura, e não de código: fica para quando houver motivo.
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
git clone https://github.com/Cchaves20/Deskside.git
cd Deskside/deploy
cp .env.example .env
nano .env
```
No `.env`, preencha:
- `DOMAIN=caio-remoteone.duckdns.org` (o seu subdomínio),
- `DESKSIDE_JWT_SECRET=` um segredo longo (gere com `openssl rand -base64 48`),
- `DESKSIDE_TURN_SECRET=` outro segredo longo (mesmo comando). É o que o
  backend usa para gerar as credenciais temporárias e o coturn para conferir -
  se os dois discordarem, o TURN recusa todo mundo e a falha aparece só como
  "não conectou",
- `TURN_LISTEN_IP=` o IP **privado** da VM (`ip -4 addr show | grep inet`, algo
  como `10.0.0.182`) - é a placa por onde os pacotes chegam,
- `TURN_EXTERNAL_IP=` o IP público reservado (passo 3). A VM só enxerga o IP
  privado, e o TURN precisa **anunciar** o público - anunciar o privado faz o
  relay virar um endereço que ninguém alcança,
- `POSTGRES_PASSWORD=` uma senha forte.

Salve (Ctrl+O, Enter, Ctrl+X).

## 9. Subir tudo

```bash
docker compose -f docker-compose.prod.yml up -d --build
```

> **Na VM AMD Micro (1 GB de RAM)** use o compose **leve** (SQLite, sem
> Postgres/Redis) — no `.env` basta `DOMAIN` e `DESKSIDE_JWT_SECRET`:
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
- **Agente (cada PC):** enquanto o projeto está em teste, este endereço já é o
  padrão de fábrica (`DEFAULT_BACKEND_URL`, em `agent/src/lib.rs`), então basta:
  ```
  deskside-agent.exe install
  ```
  (ou dois cliques em `agent\scripts\instalar.cmd`)

  A URL continua aceita, e é ela que manda quando aparece:
  ```
  deskside-agent.exe install wss://caio-remoteone.duckdns.org/ws/agent
  ```
  Use a forma explícita para **mudar** o servidor de um agente já instalado: sem
  argumento, o `install` preserva o que estiver gravado no `agent.conf`.

  Confira com `deskside-agent.exe status`.

Como agora o backend é central e sempre ligado, **cadastre a conta uma vez** (é
um banco novo) e refaça o pareamento de cada computador. A partir daí você
controla qualquer um deles de qualquer lugar.

---

## Conferir se o TURN está de pé

> **`permission denied ... docker.sock`?** O usuário `ubuntu` só entra no grupo
> `docker` depois de sair e entrar de novo no SSH - e nem sempre isso pegou. O
> caminho curto é `sudo` na frente de todo `docker compose` (é o que o
> `scripts/atualizar.ps1` faz). Para resolver de vez:
> `sudo usermod -aG docker $USER` e reconecte o SSH.

```bash
sudo docker compose -f docker-compose.lite.yml logs coturn | tail -20
```

Se o `ps` mostrar `Restarting`, o erro está na primeira linha do log. E se o
log vier **vazio**, o contêiner morreu antes de escrever: rode o servidor à mão
para ver a reclamação dele na tela.

```bash
sudo docker compose -f docker-compose.lite.yml run --rm --entrypoint turnserver \
  coturn --listening-port=3478 --external-ip=147.15.45.45 --log-file=stdout --simple-log
```
Procure `Relay ... initialized` e o IP público em `external-ip`. Se aparecer
só o IP privado (10.x), o coturn vai anunciar um endereço que ninguém alcança.

Do celular, na tela de controle: quando a barra de cima disser **vídeo** ou
**direto** em vez de "N fps", fechou. Se disser "vídeo direto falhou", toque
para ver o resumo do ICE - `relay` na lista de candidatos significa que o TURN
respondeu.

## Cópia de segurança do banco

O banco guarda a única coisa que **não** dá para refazer: as contas e os
pareamentos. O código está no Git, a configuração está no `.env`, os
computadores reinstalam o agente em dois minutos — mas se o banco sumir, cada
pessoa perde a conta e cada computador precisa ser pareado de novo.

A VM é gratuita e não tem garantia nenhuma. Isto leva meia hora e é o item de
qualquer lista que pode custar tudo de uma vez.

### 1. Instalar a tarefa diária (uma vez, na VM)

```bash
cd ~/Deskside 2>/dev/null || cd ~/RemoteOne
git pull
chmod +x deploy/backup.sh
( crontab -l 2>/dev/null | grep -v 'deploy/backup.sh'; \
  echo "17 3 * * * sh -c 'cd ~/Deskside 2>/dev/null || cd ~/RemoteOne; ./deploy/backup.sh' >> ~/backup.log 2>&1" ) | crontab -
crontab -l
```

**O `cd` com os dois nomes não é preciosismo.** O clone na VM pode se chamar
`~/RemoteOne` ou `~/Deskside`, dependendo de quando foi feito — o projeto mudou
de nome depois de o servidor existir, e a pasta não foi renomeada. Uma linha de
cron com o caminho errado **falha todos os dias em silêncio**, num log que
ninguém lê até precisar restaurar. Já aconteceu aqui.

O `grep -v` tira uma linha anterior antes de pôr a nova; sem ele, cada
instalação acrescentaria mais uma.

3h17 e não 3h00 de propósito: a madrugada em ponto é quando todo mundo agenda
tarefa, e numa VM de 1 GB duas coisas pesadas ao mesmo tempo bastam para
derrubar o servidor.

Faça uma agora, para não esperar até amanhã para saber se funciona:

```bash
./deploy/backup.sh
ls -lh deploy/backups/
```

Confira o **tamanho**. Um arquivo de poucos bytes significa banco vazio — o
contêiner está olhando outro lugar, e o backup não está protegendo nada.

### 2. Trazer as cópias para fora da VM

Uma cópia que mora na mesma máquina que o banco **não protege contra a máquina
morrer**. Ela protege contra o que é mais comum — uma migração de esquema que dá
errado, um contêiner recriado com o volume errado —, mas não contra o disco.

A outra metade sai do computador de casa, pela mesma chave SSH do deploy:

```powershell
.\scripts\atualizar.cmd -Backup
```

Baixa a mais recente para `%USERPROFILE%\Deskside-backups`, **confere que o
arquivo é mesmo um banco SQLite** e diz o tamanho. A conferência não é zelo
excessivo: um arquivo de zero byte ou uma mensagem de erro gravada no lugar do
banco sairiam de um `scp` como sucesso, e só se descobririam no dia da
restauração.

Vale rodar depois de qualquer mudança grande, e de vez em quando sem motivo.

### Como restaurar

O que ninguém testa até precisar. **Este procedimento foi ensaiado em produção**
(agosto de 2026) restaurando a cópia recém-tirada, que é a forma segura de fazer
o teste: os dados são idênticos, então não há o que perder.

```bash
cd ~/Deskside/deploy 2>/dev/null || cd ~/RemoteOne/deploy
sudo docker compose -f docker-compose.lite.yml stop api
# O banco fica num volume do Docker; o `cp` entra por um contêiner de uma vez só.
sudo docker run --rm -v deploy_apidata:/data -v ~/Deskside/deploy/backups:/b \
  alpine cp /b/deskside-AAAAMMDD-HHMMSS.db /data/deskside.db
sudo docker compose -f docker-compose.lite.yml start api
```

Troque o nome do arquivo pelo da cópia que você quer.

Confira **do seu computador**, e não da VM:

```powershell
Invoke-WebRequest https://caio-remoteone.duckdns.org/health | Select-Object -ExpandProperty Content
```

Daqui e não de lá por dois motivos que se somam: o contêiner da API **não
publica porta nenhuma** (só o Caddy fala com ele), e a VM da Oracle **não
alcança o próprio IP público** — não há NAT de retorno. Um `curl` lá dentro
falharia sem haver problema nenhum, e mandaria a investigação para o lado
errado.

E o teste que vale de verdade: abra o app, entre na conta e veja se os
computadores continuam pareados.

### O que o backup faz por dentro, e por que não é `cp`

Copiar o arquivo do banco com o servidor rodando pode produzir um arquivo
**corrompido**: o SQLite escreve em páginas, e uma cópia feita no meio de uma
transação pega metade do antes e metade do depois. O pior é que ela parece boa —
o defeito só aparece na restauração.

O agendador chama `python -m app.backup`, que usa a API de backup do próprio
SQLite: ela copia página a página, percebe quando uma página muda no caminho e
refaz essa parte. O resultado é um banco consistente **sem parar o servidor**.

Ficam catorze cópias na VM. Catorze porque o erro que isto mais protege — um
esquema quebrado, um apagamento acidental — costuma ser notado em dias, não em
horas: guardar só a de ontem deixaria de fora quem percebe na segunda-feira algo
que aconteceu na sexta. E o banco tem kilobytes.

As cópias saem numa pasta montada do disco (`deploy/backups`), e não num volume
do Docker, justamente para o `scp` alcançá-las de fora. A pasta está no
`.gitignore`: são dados de usuário, e o repositório é público.

## Manutenção

- **Atualizar o backend** (após um `git pull`):
  ```bash
  cd ~/Deskside && git pull && cd deploy
  docker compose -f docker-compose.prod.yml up -d --build
  ```
- **Ver logs:** `docker compose -f docker-compose.prod.yml logs -f api`
- **Parar:** `docker compose -f docker-compose.prod.yml down` (os dados do
  Postgres ficam no volume).

## Segurança (bom saber)

- Só 80/443 ficam abertos; API/Postgres/Redis não têm porta pública.
- HTTPS/WSS criptografa tudo (login, tela, comandos).
- Troque `DESKSIDE_JWT_SECRET` e `POSTGRES_PASSWORD` por valores fortes e
  **nunca** versione o `.env`.
- Mantenha o SSH só com chave (a Oracle já faz isso por padrão).

## Mudou o Caddyfile? Recarregue o Caddy

O `Caddyfile` entra no contêiner por **volume**. Mudá-lo no disco não muda nada
no Caddy que já está rodando, e o `docker compose up -d` **não** recria o
contêiner — do ponto de vista dele o serviço não mudou.

> **Monte a pasta, nunca o arquivo.** Um bind mount de arquivo solto
> (`./Caddyfile:/etc/caddy/Caddyfile`) prende o contêiner ao **inode**. O
> `git reset --hard` substitui o arquivo, criando um inode novo, e o contêiner
> continua vendo o antigo — para sempre, até ser recriado. Isso custou quatro
> rodadas: a correção de roteamento estava no disco do VPS, o proxy quebrado
> seguia no ar, e o `caddy reload` (que lê de dentro do contêiner) recarregava
> a versão velha **com sucesso**. Por isso o volume hoje é `./caddy:/etc/caddy`.

Isso já causou um susto: uma correção de roteamento ficou parada no disco
enquanto o proxy quebrado seguia no ar, e a conferência do `atualizar` acusou
"servidor desatualizado" — quando o servidor estava certo e o proxy é que não o
alcançava.

O `atualizar` agora recarrega sozinho. À mão:

```bash
cd ~/Deskside/deploy
sudo docker compose -f docker-compose.lite.yml exec -T caddy \
  caddy reload --config /etc/caddy/Caddyfile
```

`reload` troca a configuração **sem derrubar conexão nenhuma**. E se a
configuração nova estiver errada, o Caddy recusa e mantém a antiga de pé — ou
seja, também serve de validação.
