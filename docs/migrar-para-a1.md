# Migrar o servidor para a Ampere A1 (grátis, até 4 núcleos e 24 GB)

O servidor de hoje é uma **VM.Standard.E2.1.Micro**: 1 GB de RAM e um oitavo
de núcleo garantido. No teste de carga, o processador dela saturou com cerca
de 1.000 computadores ligados, e a estimativa é de 200 a 300 celulares de tela
aberta. A **VM.Standard.A1.Flex** (ARM) também é Always Free, e vai até
4 OCPU e 24 GB (ver `docs/teste-de-carga.md`).

## A ideia: IP novo, e o domínio aponta para ele

O IP de hoje, **147.15.45.45**, é **efêmero**. Isso tem duas consequências:

- **Não mexa nele.** Um IP efêmero não vira reservado mantendo o número. A
  Oracle dá um número novo, e o servidor de hoje sairia do ar.
- Ele também não passa para outra máquina. A A1 ganha um **IP reservado
  novo**, e no corte os nomes passam a apontar para ele:
  - `deskside.com.br`, no painel de onde o domínio está;
  - `caio-remoteone.duckdns.org`, no site do DuckDNS. É o endereço antigo, e
    agentes instalados antes da troca de domínio ainda podem usá-lo.

Os agentes e os apps usam o nome, não o número. Quando o servidor velho para,
eles tentam de novo e, assim que o nome passa a responder com o IP novo,
chegam à A1. O tempo que isso leva depende do **TTL** do registro DNS (quanto
tempo cada aparelho guarda a resposta antiga), e por isso o primeiro passo é
baixar o TTL.

As três fases:

| Fase | O que acontece | Servidor no ar? |
| --- | --- | --- |
| 1. Preparar | cria a A1, copia o projeto e monta tudo com um banco vazio | sim, o velho |
| 2. Corte | para o velho, leva o banco, troca o DNS | **não, ~10 minutos + o TTL** |
| 3. Arrumar | backup diário na nova, `atualizar.ps1` e, uma semana depois, apaga a velha | sim, o novo |

Faça a fase 2 num horário em que ninguém esteja usando.

**O que já foi conferido daqui:** toda dependência do backend tem versão ARM
(aarch64) com o mesmo hash do `requirements.txt`, e as imagens `caddy:2`,
`alpine:3` e `coturn/coturn:4.6` também existem para ARM. O build em si só se
confirma na fase 1, na máquina nova.

Os comandos de PowerShell valem para o **Dell** (pasta
`C:\Users\caiof_lv78yyf\RemoteOne`) e para o **MateBook** (pasta
`C:\Users\OseasyVM\Desktop\projetos\Deskside`). Use um só do começo ao fim:
as variáveis `$chave`, `$ip` e `$novo` vivem na janela onde foram criadas.

---

## Fase 0: baixar o TTL (de preferência um dia antes)

No painel de onde o `deskside.com.br` está registrado, edite o registro
**A** de `deskside.com.br` (e de `www`, se existir). Mantenha o IP e mude o
**TTL para 300** (5 minutos).

O efeito só vale depois que o TTL **antigo** vencer, e por isso convém fazer
isto com antecedência. Se o TTL antigo era de 1 hora, uma hora basta; se era
de 1 dia, espere um dia.

O DuckDNS já usa 60 segundos e não tem o que mudar.

---

## Fase 1: preparar a máquina nova (sem parar nada)

### 1.1 Copiar a chave pública

Assim o mesmo comando de SSH entra nas duas máquinas, e nenhum `.key` novo
aparece em Downloads. Um `.key` novo quebraria o `$chave` dos comandos, que
pega o mais recente.

**PowerShell, na pasta do projeto.** Copia a chave **pública** para a área de
transferência. Ela é pública, não é segredo, e o comando não mostra nada:
```powershell
$chave = (Get-ChildItem "$env:USERPROFILE\Downloads" -Filter *.key | Sort-Object LastWriteTime -Descending | Select-Object -First 1).FullName; ssh-keygen -y -f $chave | Set-Clipboard
```

### 1.2 Criar a A1 (console da Oracle)

Menu ☰ → **Compute → Instances → Create instance:**

1. **Name:** `deskside-a1`.
2. **Image and shape:**
   - **Change image → Canonical Ubuntu → 24.04**, a que **não** termina em
     "Minimal".
   - **Change shape → Virtual machine → Ampere → VM.Standard.A1.Flex**, com
     **2 OCPU e 12 GB**. O programa roda num processo só, então mais núcleos
     quase não ajudam; memória ajuda. Dá para subir até 4 OCPU e 24 GB depois
     (*Edit → Edit shape*, com um reinício), sem sair do grátis. Como a
     resposta costuma ser "sem vaga", `scripts/aumentar-a1.sh` tenta sozinho
     até conseguir; rode **antes** de migrar, enquanto a máquina está vazia.
     Aumentar a mesma máquina, e nunca criar uma segunda: duas somam o
     tamanho e passam do grátis.
   - Depois de escolher o shape, confira que a imagem continua Ubuntu 24.04
     **aarch64**.
3. **Networking:** **a mesma VCN e a mesma subnet** da VM de hoje. Assim a
   *Security List* já vem com as portas 80, 443, 3478 e 49160-49200 abertas.
   Deixe **Automatically assign public IPv4 address** ligado.
4. **Add SSH keys → Paste public keys** → Ctrl+V. O texto começa com
   `ssh-rsa` ou `ssh-ed25519`.
5. **Boot volume:** o padrão (50 GB). O grátis cobre 200 GB somando as VMs.
6. **Create.** Em um ou dois minutos ela fica **Running**.

> **"Out of capacity for shape VM.Standard.A1.Flex"** é comum.
> - Tente outro *Availability Domain* em **Placement** (São Paulo só tem um),
>   ou 1 OCPU / 6 GB.
> - Repita em outro horário; de madrugada costuma ter vaga.
> - Deixe tentando sozinho: `scripts/pedir-a1.sh`, no VPS de hoje, pede a
>   máquina a cada 3 minutos até conseguir (como preparar está no começo do
>   próprio script e em "Pedir a A1 sozinho", abaixo).
> - Último recurso: passar a conta para *Pay As You Go*. As máquinas Always
>   Free continuam grátis, e a fila de ARM costuma andar. Ponha um alerta de
>   orçamento de R$ 1 se fizer isso.

### Pedir a A1 sozinho (quando o console só dá "Out of capacity")

O `scripts/pedir-a1.sh` roda no VPS de hoje e usa a linha de comando da
Oracle. A máquina sai com o nome `deskside-a1`, Ubuntu 24.04 ARM, a mesma
subnet da VM de hoje e a mesma chave SSH dela.

**VPS de hoje, na pasta `~`.** Primeiro, instale a linha de comando e crie uma
chave de API. A chave privada nasce e fica no VPS; só a pública vai ao
console:
```bash
cd ~/Deskside 2>/dev/null || cd ~/RemoteOne; git pull
sudo apt update && sudo apt install -y python3-venv
python3 -m venv ~/oci && ~/oci/bin/pip install -q oci-cli && ~/oci/bin/oci --version
mkdir -p ~/.oci && chmod 700 ~/.oci
openssl genrsa -out ~/.oci/chave-api.pem 2048 && chmod 600 ~/.oci/chave-api.pem
openssl rsa -pubout -in ~/.oci/chave-api.pem
```

**Console da Oracle.** Ícone do perfil (canto superior direito) → **My
profile → Tokens and keys** (ou *API keys*) → **Add API key → Paste a public
key** → cole o bloco inteiro, de `-----BEGIN PUBLIC KEY-----` a
`-----END PUBLIC KEY-----` → **Add**. Copie o *Configuration file preview*.

**VPS de hoje.** `nano ~/.oci/config`, cole, salve (Ctrl+O, Enter, Ctrl+X), e:
```bash
sed -i 's|^key_file=.*|key_file=~/.oci/chave-api.pem|' ~/.oci/config && chmod 600 ~/.oci/config
cd ~/Deskside 2>/dev/null || cd ~/RemoteOne
scripts/pedir-a1.sh --uma
```
O certo é ver `conta ok`, uma linha `sem vaga` por tamanho e `fim da rodada
única`. Então deixe rodando, e confira de vez em quando:
```bash
nohup scripts/pedir-a1.sh > ~/pedir-a1.log 2>&1 &
tail -3 ~/pedir-a1.log
```
Quando aparecer `PRONTO`, siga para o passo 1.3. **Depois**, apague a chave
de API no console (mesma tela, **⋮ → Delete**) e, no VPS,
`rm -rf ~/.oci ~/oci`: ela dá acesso à conta inteira, e não serve para mais
nada.

### 1.3 Tornar o IP da A1 reservado (já agora)

Antes de configurar qualquer coisa, para o número não mudar mais:

**A1 → Attached VNICs →** a VNIC **→ IP administration →** na linha do IP,
**⋮ → Edit → Reserved public IP → Create new reserved IP**, com o nome
`deskside` **→ Update**.

O número muda nesse momento, e **o novo é o definitivo**: é ele que vai no
`.env` e no DNS. Na lista, o tipo passa a ser **Reserved**.

### 1.4 Entrar na A1

**PowerShell, na pasta do projeto.** Troque só o número na primeira linha pelo
IP reservado do passo 1.3:

```powershell
$ip = "IP_RESERVADO_DA_A1"
$chave = (Get-ChildItem "$env:USERPROFILE\Downloads" -Filter *.key | Sort-Object LastWriteTime -Descending | Select-Object -First 1).FullName; $novo = "ubuntu@$ip"; ssh -i $chave $novo
```

Responda `yes` à pergunta de confiança. Deixe essa janela aberta até o fim.

### 1.5 Firewall e Docker

**A1, na pasta `~`:**

```bash
POS=$(sudo iptables -L INPUT --line-numbers -n | awk '$2=="REJECT"{print $1; exit}')
for regra in "tcp --dport 80" "tcp --dport 443" "udp --dport 3478" "tcp --dport 3478" "udp --dport 49160:49200"; do
  sudo iptables -I INPUT ${POS:-1} -m state --state NEW -p $regra -j ACCEPT
done
sudo netfilter-persistent save
sudo iptables -L INPUT -n --line-numbers
```

As cinco regras têm que aparecer **acima** da linha do `REJECT`. O porquê está
em `docs/deploy-vps-oracle.md`, passo 4.

```bash
sudo apt update && sudo apt install -y docker.io git
sudo apt install -y docker-compose-v2 || sudo apt install -y docker-compose-plugin
sudo docker compose version
```

Não precisa de swap: são 12 GB.

### 1.6 Copiar o projeto da máquina velha

O mais simples, e que leva **tudo** o que não está no Git: a pasta inteira do
clone. Ela contém o `.env` (segredos), `certs/` (raiz da Apple),
`site/baixar/` (os instaladores) e `backups/`. O `.env` nunca aparece na tela,
e o arquivo só passa pelo seu computador.

**VPS velho.** Abra **outra** janela do PowerShell e entre:
```powershell
$chave = (Get-ChildItem "$env:USERPROFILE\Downloads" -Filter *.key | Sort-Object LastWriteTime -Descending | Select-Object -First 1).FullName; ssh -i $chave ubuntu@147.15.45.45
```
e, já no VPS velho, na pasta `~`:
```bash
D=$(ls -d Deskside RemoteOne 2>/dev/null | head -1); echo "pasta: $D"
sudo tar czf ~/migracao.tgz -C ~ "$D" && sudo chown ubuntu: ~/migracao.tgz && ls -lh ~/migracao.tgz
```

**Na primeira janela do PowerShell** (a que tem `$novo`): `exit` para sair da
A1, e então:
```powershell
scp -i $chave ubuntu@147.15.45.45:migracao.tgz "$env:TEMP\"
scp -i $chave "$env:TEMP\migracao.tgz" "${novo}:"
Remove-Item "$env:TEMP\migracao.tgz"
ssh -i $chave $novo
```

**A1, na pasta `~`:**
```bash
sudo tar xzf ~/migracao.tgz -C ~ && rm ~/migracao.tgz
cd ~/Deskside/deploy 2>/dev/null || cd ~/RemoteOne/deploy; pwd
```

**VPS velho, na pasta `~`:** `rm ~/migracao.tgz`

### 1.7 Ajustar o `.env` (na A1)

Os dois IPs do TURN mudam: o privado (`TURN_LISTEN_IP`) e o público
(`TURN_EXTERNAL_IP`). Os segredos ficam iguais.

**A1, na pasta `deploy` do clone** (onde o `pwd` acima parou). Só aparecem as
duas linhas do TURN:
```bash
PRIV=$(ip -4 -o route get 1.1.1.1 | sed -n 's/.* src \([0-9.]*\).*/\1/p')
PUB=$(curl -s https://ifconfig.me)
echo "privado: $PRIV  público: $PUB"
sed -i "s/^TURN_LISTEN_IP=.*/TURN_LISTEN_IP=$PRIV/; s/^TURN_EXTERNAL_IP=.*/TURN_EXTERNAL_IP=$PUB/" .env
grep -E '^TURN_(LISTEN|EXTERNAL)_IP=' .env
```
O privado é algo como `10.0.0.x`. O público tem que ser **o mesmo IP
reservado do passo 1.3**. Se não for, pare: o IP da A1 não está como você
pensa.

### 1.8 Montar e testar com um banco vazio (na A1)

Ainda na pasta `deploy` da A1:
```bash
sudo docker compose -f docker-compose.lite.yml build
sudo docker compose -f docker-compose.lite.yml create
sudo docker compose -f docker-compose.lite.yml up -d api
sudo docker compose -f docker-compose.lite.yml ps
sudo docker compose -f docker-compose.lite.yml logs --tail 20 api
```

- O `build` é a parte demorada: alguns minutos.
- O `create` cria os contêineres e os volumes sem ligar nada.
- Só a **API** sobe agora. O Caddy fica parado de propósito: sem o DNS
  apontando para cá, ele tentaria tirar o certificado, falharia, e cada falha
  conta no limite da Let's Encrypt.

O certo é ver `api` como `Up`, `init-permissoes` como `Exited (0)` e, no log,
`Application startup complete`. Depois:
```bash
sudo docker compose -f docker-compose.lite.yml stop api
```

A fase 1 termina aqui. O servidor velho seguiu atendendo o tempo todo.

---

## Fase 2: o corte (~10 minutos + o TTL)

### 2.1 Parar o velho e tirar a cópia do banco

**VPS velho, na pasta `~`:**
```bash
cd ~/Deskside/deploy 2>/dev/null || cd ~/RemoteOne/deploy
sudo docker compose -f docker-compose.lite.yml stop
sudo docker compose -f docker-compose.lite.yml run --rm --no-deps api python -m app.backup /backups
ULTIMO=$(sudo sh -c 'ls -t backups/deskside-*.db* | head -1'); echo "$ULTIMO"
case "$ULTIMO" in *.enc) sudo docker compose -f docker-compose.lite.yml run --rm --no-deps api \
  python -m app.backup --abrir "/backups/$(basename "$ULTIMO")"; ULTIMO=${ULTIMO%.enc} ;; esac
mkdir -p ~/corte
sudo cp "$ULTIMO" /home/ubuntu/corte/deskside.db
sudo docker run --rm -v deploy_caddy_data:/d -v ~/corte:/b alpine tar czf /b/caddy.tgz -C /d .
sudo chown -R ubuntu: ~/corte && ls -lh ~/corte
```

- O `stop` para **tudo** no velho: API, Caddy e TURN. A partir daí ninguém
  escreve no banco, então a cópia tem **tudo**. E quem ainda tiver o IP velho
  guardado recebe recusa e tenta de novo, em vez de cair num servidor
  desatualizado.
- O `run --rm` tira a cópia num contêiner novo, porque o da API está parado.
- Com `DESKSIDE_BACKUP_KEY` no `.env`, a cópia sai cifrada (`.db.enc`). O
  `--abrir` grava ao lado a versão aberta (`.db`), que é a que vai para a A1.
  Essa cópia sem cifra é apagada no passo 3.1.
- O `caddy.tgz` leva o certificado HTTPS. Com ele, a A1 responde com cadeado
  no primeiro segundo, sem pedir certificado de novo.

Confira o tamanho do `deskside.db`: um arquivo de poucos KB é banco vazio. Se
for o caso, **pare aqui** e religue o velho com
`sudo docker compose -f docker-compose.lite.yml start`.

### 2.2 Levar para a A1

**Na primeira janela do PowerShell.** `exit` para sair da A1, se estiver
dentro, e então:
```powershell
scp -r -i $chave ubuntu@147.15.45.45:corte "$env:TEMP\"
scp -r -i $chave "$env:TEMP\corte" "${novo}:"
Remove-Item -Recurse "$env:TEMP\corte"
ssh -i $chave $novo
```

### 2.3 Pôr o banco e o certificado na A1

**A1, na pasta `~`:**
```bash
cd ~/Deskside/deploy 2>/dev/null || cd ~/RemoteOne/deploy
sudo docker run --rm -v deploy_apidata:/data -v ~/corte:/b alpine \
  sh -c 'rm -f /data/deskside.db-wal /data/deskside.db-shm && cp /b/deskside.db /data/deskside.db'
sudo docker run --rm -v deploy_caddy_data:/d -v ~/corte:/b alpine \
  sh -c 'rm -rf /d/* && tar xzf /b/caddy.tgz -C /d'
sudo docker compose -f docker-compose.lite.yml up -d
sudo docker compose -f docker-compose.lite.yml ps
```

O `rm -f` dos arquivos `-wal`/`-shm` não é enfeite. Eles sobraram do banco
vazio da fase 1. Se ficassem ao lado do banco de verdade, o SQLite tentaria
aplicá-los nele.

Agora `api`, `caddy` e `coturn` devem estar `Up`.

### 2.4 Testar antes de mexer no DNS

**PowerShell, mesma janela.** O `--resolve` faz o `curl` falar com a A1
fingindo que o domínio já aponta para ela:
```powershell
curl.exe -s --resolve "deskside.com.br:443:$ip" https://deskside.com.br/health
```
Deve responder `{"status":"ok",...}`, **sem** erro de certificado.

### 2.5 Apontar os nomes para a A1

1. **Painel do domínio:** no registro **A** de `deskside.com.br` (e de `www`,
   se existir), troque `147.15.45.45` pelo IP da A1.
2. **duckdns.org:** entre, e no `caio-remoteone` ponha o IP da A1 em
   *current ip* → **update ip**.

### 2.6 Conferir

**PowerShell, mesma janela.** O primeiro comando pergunta direto ao DNS do
Google, sem cache, e deve responder o IP da A1:
```powershell
nslookup deskside.com.br 8.8.8.8
curl.exe -s https://deskside.com.br/health
```

O segundo só passa a ir para a A1 quando o cache do seu computador vencer, e
isso leva até o TTL. Se ele ainda falhar, espere alguns minutos e tente de
novo.

E o teste que vale:

1. Abra o app no celular **em Wi-Fi**. Veja se a conta e os computadores
   continuam lá, e se a tela abre.
2. Repita **no 4G/5G**: isso confere o TURN. Se a tela não abrir só no 4G,
   quase sempre é o `.env` (passo 1.7) ou o firewall (passo 1.5).
3. Os agentes reconectam sozinhos assim que o DNS deles vencer. Mas há DNS
   de roteador e de operadora que seguem entregando o IP velho por mais tempo
   que o TTL. Por isso, logo depois do corte, ligue a ponte (2.7).

### 2.7 A ponte no VPS velho

No corte de verdade, o app do celular entrou, mas os computadores ficaram
offline. O `agent.log` (`%APPDATA%\deskside\agent.log`) mostrava
`reconectando em 30s` sem parar. E o `Resolve-DnsName deskside.com.br` no
computador ainda dava `147.15.45.45`, com TTL cheio, enquanto o DNS do Google
(`-Server 8.8.8.8`) já dava o IP novo.

A ponte resolve isso sem esperar: o VPS velho repassa as portas 80 e 443 para
a A1. Ela não abre o HTTPS, então o certificado continua sendo o da A1, e não
há API nem banco no velho.

**VPS velho, qualquer pasta:**
```bash
NOVO=137.131.184.239   # o IP reservado da A1
sudo docker run -d --name ponte-443 --restart unless-stopped -p 443:443 alpine/socat TCP-LISTEN:443,fork,reuseaddr TCP:$NOVO:443
sudo docker run -d --name ponte-80 --restart unless-stopped -p 80:80 alpine/socat TCP-LISTEN:80,fork,reuseaddr TCP:$NOVO:80
sudo docker ps --format '{{.Names}}  {{.Status}}'
```
Em até 30 segundos, o `agent.log` mostra
`conectado ao backend em wss://deskside.com.br/ws/agent`.

Para a A1, quem passa pela ponte tem o IP do VPS velho. Isso não muda nada
para os computadores, mas vale para o limite de tentativas de login por IP.
Desligue a ponte quando o DNS dos seus computadores já mostrar o IP novo, um ou
dois dias depois:
```bash
sudo docker rm -f ponte-443 ponte-80
```

### Se algo der errado: voltar

1. Painel do domínio e DuckDNS: volte o registro para `147.15.45.45`.
2. **VPS velho**, na pasta `~`:
   ```bash
   sudo docker rm -f ponte-443 ponte-80 2>/dev/null
   cd ~/Deskside/deploy 2>/dev/null || cd ~/RemoteOne/deploy
   sudo docker compose -f docker-compose.lite.yml start
   ```
   A ponte sai primeiro: ela ocupa as portas 80 e 443 de que o Caddy precisa.

O banco velho ficou intacto: a cópia foi tirada, nada foi apagado. O que tiver
sido gravado na A1 nesse meio-tempo (um pareamento novo, por exemplo) fica só
nela.

---

## Fase 3: arrumar

### 3.1 Backup diário na A1

**A1, na pasta `~`.** É o mesmo da seção de cópias em
`docs/deploy-vps-oracle.md`:
```bash
cd ~/Deskside 2>/dev/null || cd ~/RemoteOne
chmod +x deploy/backup.sh
( crontab -l 2>/dev/null | grep -v 'deploy/backup.sh'; \
  echo "17 3 * * * sh -c 'cd ~/Deskside 2>/dev/null || cd ~/RemoteOne; ./deploy/backup.sh' >> ~/backup.log 2>&1" ) | crontab -
./deploy/backup.sh && ls -lh deploy/backups/ | tail -3
rm -rf ~/corte
```

### 3.2 O endereço do SSH nos scripts

`scripts/atualizar.ps1` (`-Vps`, `-Backup`, `-Publicar`) e
`docs/publicar-instalador.md` já usam o IP da A1 (137.131.184.239). Depois de
um `git pull`, valem sem `-Servidor`. Antes dele, acrescente `-Servidor $novo`.

Os instaladores de Linux e Mac são baixados de novo na A1. O de Windows já
veio no `site/baixar/` copiado.

**A1, na pasta `~`:**
```bash
cd ~/Deskside 2>/dev/null || cd ~/RemoteOne; git pull && sh scripts/publicar-linux.sh && sh scripts/publicar-mac.sh
```

### 3.3 Apagar a VM velha (uma semana depois)

Sem reclamação por uma semana: **VM velha → More actions → Terminate**,
marcando **Permanently delete the attached boot volume**. O IP efêmero dela
some junto, e isso é esperado.

Ela não custa nada enquanto existe: E2.1.Micro e A1 somadas cabem no grátis.

Se quiser, depois disso volte o TTL do domínio para o valor antigo.

## Depois: aproveitar a memória

A API continua com `mem_limit: 512m` em `deploy/docker-compose.lite.yml`.
Esse teto foi escolhido para uma VM de 1 GB, e é o que limita a parte B em
cerca de 2.300 pares (ver `docs/teste-de-carga.md`). Na A1, com 4 GB, a
memória deixaria de limitar, e o teto passaria a ser o processador: cerca de
15.000 pares num núcleo. Para isso, o teto precisa sair do arquivo para o
`.env`. É uma mudança pequena, a fazer depois que a migração estiver estável.
