# Migrar o servidor para a Ampere A1 (grátis, até 4 núcleos e 24 GB)

O servidor de hoje é uma **VM.Standard.E2.1.Micro**: 1 GB de RAM e um oitavo
de núcleo garantido. Pelo teste de carga, isso dá de 200 a 300 celulares de
tela aberta. A **VM.Standard.A1.Flex** (ARM) também é Always Free e vai até
4 OCPU e 24 GB. Com ela o limite deixa de ser a máquina e passa a ser o próprio
programa (ver `docs/teste-de-carga.md`).

## A ideia: levar o IP junto

O IP **147.15.45.45** é reservado, e um IP reservado pode ser **desligado de
uma VM e ligado em outra**. Se ele vai junto:

- o domínio `deskside.com.br` (e o antigo `caio-remoteone.duckdns.org`) não
  muda: **não há DNS para trocar nem propagação para esperar**;
- os agentes e os apps não percebem nada, só reconectam;
- `scripts/atualizar.ps1` e o `TURN_EXTERNAL_IP` continuam certos;
- voltar atrás é devolver o IP para a VM velha.

O plano tem três fases:

| Fase | O que acontece | Servidor no ar? |
| --- | --- | --- |
| 1. Preparar | cria a A1, copia o projeto e monta tudo com um banco vazio | sim, o velho |
| 2. Corte | para o velho, leva o banco, troca o IP | **não, ~10 minutos** |
| 3. Arrumar | backup diário na nova e, uma semana depois, apaga a velha | sim, o novo |

Faça a fase 2 num horário em que ninguém esteja usando.

**O que já foi conferido daqui:** toda dependência do backend tem versão ARM
(aarch64) com o mesmo hash do `requirements.txt`, e as imagens `caddy:2`,
`alpine:3` e `coturn/coturn:4.6` também existem para ARM. O build em si só se
confirma na fase 1, na máquina nova.

### Antes de começar: confira que o IP é mesmo reservado

No console da Oracle: **Compute → Instances →** a VM de hoje **→ Attached
VNICs →** a VNIC **→ IP administration** (ou *IP addresses*). Ao lado de
`147.15.45.45` tem que estar **Reserved**.

Se estiver **Ephemeral**, ele **não** pode ser levado. Faça o passo 3 de
`docs/deploy-vps-oracle.md` (trocar para *Reserved*) **antes** de tudo. Essa
troca mantém o mesmo número.

---

## Fase 1: preparar a máquina nova (sem parar nada)

### 1.1 Criar a A1 (console da Oracle)

**Compute → Instances → Create Instance:**

1. **Placement:** o mesmo *Availability Domain* da VM de hoje, se tiver vaga.
2. **Image:** *Change image →* **Canonical Ubuntu 24.04** (a imagem
   **aarch64**; a do shape AMD não serve).
3. **Shape:** *Change shape → Ampere →* **VM.Standard.A1.Flex**, com
   **2 OCPU e 12 GB**.
   - O programa roda num processo só, então mais núcleos quase não ajudam;
     memória ajuda.
   - Dá para subir até 4 OCPU e 24 GB depois (*Edit → Edit shape*, com um
     reinício), sem sair do grátis.
4. **Networking:** escolha a **mesma VCN e a mesma subnet** da VM de hoje.
   Assim a *Security List* já vem com as portas 80, 443, 3478 e 49160-49200
   abertas.
   - Em *Public IPv4 address*, deixe **Assign a public IPv4 address**. Esse IP
     temporário só serve para a preparação.
5. **Add SSH keys:** escolha **Paste public keys** e cole a chave **pública**
   da chave que você já usa. Assim o mesmo comando de SSH entra nas duas
   máquinas, e nenhum `.key` novo aparece em Downloads. Um `.key` novo
   quebraria o `$chave` dos comandos, que pega o mais recente.

   **Dell, PowerShell, em qualquer pasta.** Copia a chave pública para a área
   de transferência. Ela é pública e não é segredo:
   ```powershell
   $chave = (Get-ChildItem "$env:USERPROFILE\Downloads" -Filter *.key | Sort-Object LastWriteTime -Descending | Select-Object -First 1).FullName; ssh-keygen -y -f $chave | Set-Clipboard
   ```
   Depois é só colar (Ctrl+V) na caixa da Oracle.
6. **Boot volume:** pode deixar o padrão (50 GB). O grátis cobre 200 GB
   somando todas as VMs.
7. **Create.** Anote o **Public IP** que aparecer: é o temporário.

> **"Out of capacity for shape VM.Standard.A1.Flex"** é comum.
> - Tente outro *Availability Domain*, ou 1 OCPU / 6 GB.
> - Repita em outro horário; de madrugada costuma ter vaga.
> - Último recurso: passar a conta para *Pay As You Go*. As máquinas Always
>   Free continuam grátis, e a fila de ARM costuma andar. Ponha um alerta de
>   orçamento de R$ 1 se fizer isso.

### 1.2 Entrar na máquina nova

**Dell, PowerShell, pasta `C:\Users\caiof_lv78yyf\RemoteOne`.** Troque só o
número na primeira linha pelo IP temporário que a Oracle mostrou:

```powershell
$ip = "IP_TEMPORARIO_DA_A1"
$chave = (Get-ChildItem "$env:USERPROFILE\Downloads" -Filter *.key | Sort-Object LastWriteTime -Descending | Select-Object -First 1).FullName; $novo = "ubuntu@$ip"; ssh -i $chave $novo
```

Deixe essa janela do PowerShell aberta até o fim: `$ip`, `$chave` e `$novo`
são usados de novo mais adiante.

### 1.3 Firewall, Docker (na A1)

**A1, pela janela SSH aberta acima, na pasta `~`:**

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

### 1.4 Copiar o projeto da máquina velha

O mais simples, e que leva **tudo** o que não está no Git: a pasta inteira do
clone. Ela contém o `.env` (segredos), `certs/` (raiz da Apple),
`site/baixar/` (os instaladores) e `backups/`. O `.env` nunca aparece na tela,
e o arquivo só passa pelo Dell.

**VPS velho.** Abra **outra** janela do PowerShell no **Dell** e entre:
```powershell
$chave = (Get-ChildItem "$env:USERPROFILE\Downloads" -Filter *.key | Sort-Object LastWriteTime -Descending | Select-Object -First 1).FullName; ssh -i $chave ubuntu@147.15.45.45
```
e, já no VPS velho, na pasta `~`:
```bash
D=$(ls -d Deskside RemoteOne 2>/dev/null | head -1); echo "pasta: $D"
sudo tar czf ~/migracao.tgz -C ~ "$D" && sudo chown ubuntu: ~/migracao.tgz && ls -lh ~/migracao.tgz
```

**Dell, na primeira janela do PowerShell** (a que tem `$novo`). Digite `exit`
para sair do SSH da A1, e então:
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

**VPS velho, na pasta `~`:**
```bash
rm ~/migracao.tgz
```

### 1.5 Ajustar o `.env` (na A1)

Só o `TURN_LISTEN_IP` muda: é o IP **privado**, e a máquina nova tem outro. O
`TURN_EXTERNAL_IP` continua `147.15.45.45`, porque o IP vai junto.

**A1, na pasta `deploy` do clone** (onde o `pwd` acima parou). O comando só
mostra as duas linhas do TURN, sem os segredos:
```bash
PRIV=$(ip -4 -o route get 1.1.1.1 | sed -n 's/.* src \([0-9.]*\).*/\1/p'); echo "privado: $PRIV"
sed -i "s/^TURN_LISTEN_IP=.*/TURN_LISTEN_IP=$PRIV/" .env
grep -E '^TURN_(LISTEN|EXTERNAL)_IP=' .env
```
Confira que `TURN_LISTEN_IP` mostra o privado (algo como `10.0.0.x`) e que
`TURN_EXTERNAL_IP` mostra `147.15.45.45`.

### 1.6 Montar e testar com um banco vazio (na A1)

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
- Só a **API** sobe agora. O Caddy fica parado de propósito: sem o IP, ele
  tentaria tirar o certificado do domínio, falharia, e cada falha conta no
  limite da Let's Encrypt.

O certo é ver `api` como `Up`, `init-permissoes` como `Exited (0)` e, no log,
`Application startup complete`. Depois:
```bash
sudo docker compose -f docker-compose.lite.yml stop api
```

A fase 1 termina aqui. O servidor velho seguiu atendendo o tempo todo.

---

## Fase 2: o corte (~10 minutos fora do ar)

### 2.1 Parar o velho e tirar a cópia do banco

**VPS velho, na pasta `~`:**
```bash
cd ~/Deskside/deploy 2>/dev/null || cd ~/RemoteOne/deploy
sudo docker compose -f docker-compose.lite.yml stop api caddy
sudo docker compose -f docker-compose.lite.yml run --rm --no-deps api python -m app.backup /backups
mkdir -p ~/corte
sudo sh -c 'cp "$(ls -t backups/deskside-*.db | head -1)" /home/ubuntu/corte/deskside.db'
sudo docker run --rm -v deploy_caddy_data:/d -v ~/corte:/b alpine tar czf /b/caddy.tgz -C /d .
sudo chown -R ubuntu: ~/corte && ls -lh ~/corte
```

- A partir do `stop`, ninguém consegue escrever no banco, então a cópia tem
  **tudo**.
- O `run --rm` tira a cópia num contêiner novo, porque o da API está parado.
- O `caddy.tgz` leva o certificado HTTPS. Com ele, a máquina nova responde com
  cadeado no primeiro segundo, sem pedir certificado de novo.

Confira o tamanho do `deskside.db`: um arquivo de poucos KB é banco vazio. Se
for o caso, **pare aqui** e religue o velho com
`sudo docker compose -f docker-compose.lite.yml start`.

### 2.2 Levar para a A1

**Dell, na primeira janela do PowerShell.** Saia do SSH da A1 com `exit`, se
estiver dentro, e então:
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

### 2.4 Testar antes de mexer no IP

**Dell, PowerShell, qualquer pasta.** O `--resolve` faz o `curl` falar com a A1
fingindo que o domínio já aponta para ela:
```powershell
curl.exe -s --resolve "deskside.com.br:443:$ip" https://deskside.com.br/health
```
Deve responder `{"status":"ok",...}`, **sem** erro de certificado.

### 2.5 Mudar o IP de máquina (console da Oracle)

1. **VM velha → Attached VNICs →** a VNIC **→ IP administration →** no IP
   `147.15.45.45`, **⋮ → Edit → No public IP → Update**.

   O IP **reservado não é apagado**: ele só fica solto, esperando.
2. **A1 → Attached VNICs →** a VNIC **→ IP administration →** no IP
   temporário, **⋮ → Edit → Reserved public IP → Select existing reserved IP**
   → `147.15.45.45` **→ Update**.

   O temporário some sozinho.

### 2.6 Conferir

**Dell, PowerShell, qualquer pasta.** A primeira linha esquece a "impressão
digital" da máquina velha. Sem ela, o SSH recusaria a nova com *REMOTE HOST
IDENTIFICATION HAS CHANGED*, o que, aqui, é esperado:
```powershell
ssh-keygen -R 147.15.45.45
curl.exe -s https://deskside.com.br/health
```

E o teste que vale:

1. Abra o app no celular **em Wi-Fi**. Veja se a conta e os computadores
   continuam lá, e se a tela abre.
2. Repita **no 4G/5G**: isso confere o TURN. Se a tela não abrir só no 4G,
   quase sempre é o `TURN_LISTEN_IP` ou o firewall.
3. Os agentes reconectam sozinhos em até um minuto. Se algum demorar, use
   **Procurar atualização** na bandeja.

No **MateBook** (`C:\Users\OseasyVM\Desktop\projetos\Deskside`), rode também
`ssh-keygen -R 147.15.45.45` antes do primeiro SSH.

### Se algo der errado: voltar

1. Console: tire o `147.15.45.45` da A1 (**No public IP**) e devolva para a VM
   velha (**Reserved public IP → 147.15.45.45**).
2. **Dell:** `ssh-keygen -R 147.15.45.45`, entre no VPS velho e rode:
   ```bash
   cd ~/Deskside/deploy 2>/dev/null || cd ~/RemoteOne/deploy
   sudo docker compose -f docker-compose.lite.yml start
   ```

O banco velho ficou intacto: a cópia foi tirada, nada foi apagado.

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

E do Dell, para ter uma cópia fora: `.\scripts\atualizar.cmd -Backup`, na pasta
`C:\Users\caiof_lv78yyf\RemoteOne`.

### 3.2 Conferir que o resto continua igual

**Dell, pasta `C:\Users\caiof_lv78yyf\RemoteOne`:**
```powershell
.\scripts\atualizar.cmd -Vps
```
Ele usa `ubuntu@147.15.45.45`, que agora é a A1.

**A1 (antes era o VPS):**
```bash
cd ~/Deskside 2>/dev/null || cd ~/RemoteOne; git pull && sh scripts/publicar-linux.sh && sh scripts/publicar-mac.sh
```
Os instaladores de Linux e Mac são baixados de novo, e o Windows já veio no
`site/baixar/` copiado.

### 3.3 Apagar a VM velha (uma semana depois)

Sem reclamação por uma semana:

1. **VM velha → More actions → Terminate**, marcando **Permanently delete the
   attached boot volume**.
2. **Não** apague o IP reservado (*Networking → Reserved public IPs*). Ele
   agora é da A1.

A VM velha, enquanto existe, fica sem IP público, então não dá para entrar
nela por SSH. Para isso seria preciso dar a ela um IP temporário
(*Edit → Ephemeral public IP*). Ela não custa nada: E2.1.Micro e A1 somadas
cabem no grátis.

## Depois: aproveitar a memória

A API continua com `mem_limit: 512m` em `deploy/docker-compose.lite.yml`.
Esse teto foi escolhido para uma VM de 1 GB, e é o que limita a parte B em
cerca de 2.300 pares (ver `docs/teste-de-carga.md`). Na A1, com 4 GB, a memória
deixaria de limitar, e o teto passaria a ser o processador: cerca de 15.000
pares num núcleo. Para isso, o teto precisa sair do arquivo
para o `.env`. É uma mudança pequena, a fazer depois que a migração estiver
estável.
