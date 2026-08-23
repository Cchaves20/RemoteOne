# Revisão de segurança

Feita em agosto de 2026, antes de abrir o Deskside para estranhos. Cobre o
backend, o agente Windows e o app — não só as mudanças recentes.

**O que esta revisão não é.** É leitura de código feita por quem escreveu boa
parte dele, o que é o pior ângulo possível para achar o que falta. Não houve
teste de invasão, nem varredura de dependências, nem revisão por terceiro. Os
achados abaixo são reais; a ausência de outros não é evidência de nada.

## O risco central, que não é um defeito

O Deskside é, por desenho, execução remota de código no computador do cliente.
O agente aceita do servidor: teclas e cliques, abrir e fechar programas, ler e
escrever arquivos, desligar a máquina. Isso não é um erro a corrigir — é o
produto.

A consequência é que **o servidor é um ponto único de comprometimento total de
todos os clientes**. Quem controlar o backend digita o que quiser em todos os
computadores pareados, ao mesmo tempo. Nenhuma outra parte do sistema tem essa
propriedade, e nenhum conserto pontual a remove.

O que se pode fazer é reduzir quem alcança esse ponto: poucas pessoas com acesso
à VM, chave SSH em vez de senha, 2FA na conta da Oracle, e o `.env` fora do Git
(já é o caso). Vale escrever isso nos termos de uso: o cliente está confiando o
computador dele à operação do servidor, e ele merece saber.

---

## Corrigido nesta revisão

### S1 — `/api/v1/agents` era público e entregava a chave de qualquer computador

**Gravidade: crítica.** Corrigido.

O endpoint listava, **sem autenticação nenhuma**, o `device_id`, o `hostname`, o
sistema e a versão de **todos** os agentes conectados — de todas as contas.

Parecia inofensivo: uma listagem de diagnóstico, e um `device_id` é só um UUID.
Mas o `device_id` é a **única credencial** que o canal `/ws/agent` exige (ver
S2), e `ConnectionManager.register` sobrepõe o registro anterior sem perguntar.

O encadeamento completo, sem precisar de conta, senha ou token:

1. `GET https://deskside.com.br/api/v1/agents` → ids de quem está online agora
2. abrir `/ws/agent` e mandar um `hello` com o id de outra pessoa
3. a partir daí, **ser** aquele computador aos olhos do servidor

O agente de verdade fica órfão — o dono vê o computador cair — e o impostor
passa a receber o que o dono manda: **cada tecla digitada**, o conteúdo da área
de transferência, os pedidos de arquivo. E pode responder com a tela que
quiser.

**Conserto:** a listagem exige login e mostra apenas os aparelhos do próprio
dono. Dois testes em `backend/tests/test_seguranca.py`, e os dois falham no
código anterior — o primeiro porque a resposta vinha `200`, o segundo porque
uma segunda conta enxergava o computador da primeira.

Exigir só "um token qualquer" não bastaria: qualquer pessoa cria uma conta de
graça. Por isso a segunda verificação, de dono.

### S2 (parcial) — o segredo de assinatura tinha um padrão público

**Gravidade: crítica.** Corrigido.

`config.py` trazia `jwt_secret: str = "dev-insecure-secret-change-me"`. Esquecer
`DESKSIDE_JWT_SECRET` no `.env` de produção **não quebrava nada visível**: o
servidor subia, o `/health` respondia "ok", e os tokens passavam a ser assinados
com uma senha escrita num repositório público. Qualquer pessoa que lesse o
código forjaria um token para qualquer conta.

Falhar aberto é o pior modo de falhar, e este falhava aberto duas vezes: o
próprio comentário no arquivo dizia "PRECISA ser trocado em produção", o que é
um pedido, não uma garantia.

**Conserto:** não há mais padrão. Sem segredo — ou com o valor antigo — o
servidor **sorteia um** e grita no diário. Não se recusa a subir, de propósito:
isso trocaria um defeito silencioso por indisponibilidade total, e um
`docker compose up` que não sobe às duas da manhã é a pior hora de descobrir.
Com o sorteio, o servidor funciona, ninguém forja nada, e o sintoma é
impossível de ignorar — todo mundo cai a cada reinício.

Um defeito que se anuncia vale mais que um que espera.

> **Confira no seu servidor.** O `.env` da VPS tem `DESKSIDE_JWT_SECRET`
> definido, então nada muda para você. Se o aviso aparecer no diário depois de
> subir, é porque a variável não está chegando ao contêiner — e aí ela nunca
> esteve chegando.

---

## Aberto — precisa de decisão e de um lote próprio

### S3 — o canal `/ws/agent` não tinha autenticação

**Gravidade: alta.** Corrigido.

O agente conecta e manda `hello` com o `device_id`. Não há token, assinatura ou
segredo. O `device_id` é um UUID v4 (122 bits, inadivinhável), o que faz dele um
segredo **de fato** — mas ele nunca foi tratado como um:

- Está no caminho da URL de `/ws/viewer/{device_id}`. Hoje o Caddy não grava log
  de acesso; ligar um sem pensar passaria a registrar device_ids em texto puro.
- Está no banco, e portanto em todo backup.
- Aparece no diário do servidor (`logger.info("agente conectado: %s"...)`).
- **Não tem revogação.** Despare um computador e o `device_id` continua valendo
  para sempre — não há o que invalidar, porque não há credencial.

Com o S1 fechado, não há mais como obtê-lo anonimamente. Continua sendo o caso
de "uma linha de log vazada = um computador tomado".

**Conserto:** no pareamento o backend sorteia um segredo por dispositivo
(`Device.agent_secret`); o agente o guarda em `agent_secret`, ao lado do
`device_id`, e o apresenta em todo `hello`. Errar fecha a conexão com 4401.
Desparear apaga a linha inteira, então desparear passou a significar alguma
coisa — antes não havia o que invalidar.

Três detalhes que não são óbvios e que o código explica no lugar:

**A conferência vem antes do registro.** Registrar sobrepõe a conexão anterior
daquele `device_id`. Conferir depois entregaria a arma pela culatra: um `hello`
inválido derrubaria o agente de verdade, mesmo sendo recusado em seguida.

**O campo `secret` tem três estados, e o terceiro evita um desastre.** Ausente
(`None`) é agente antigo; vazio (`""`) é agente novo pedindo adoção;
preenchido é conferido. A distinção existe porque emitir um segredo para um
agente que não sabe guardá-lo o trancaria do lado de fora na reconexão
seguinte — o computador ficaria offline para sempre, sem nada na tela
explicando, e o dono não teria como adivinhar que precisa atualizar.

**O agente relê o segredo do disco a cada `hello`.** O servidor o entrega no
meio de uma conexão; um campo lido na partida do programa ainda estaria vazio na
conexão seguinte, e vazio quer dizer "não tenho" — cuja resposta certa é a
recusa. O agente se trancaria sozinho por não ter relido um arquivo. Tem teste.

**A compatibilidade tem prazo.** `DESKSIDE_EXIGIR_SEGREDO_DO_AGENTE=true` fecha
a porta dos agentes antigos. Ligue quando `/api/v1/agents` não mostrar mais
nenhuma versão velha; antes disso, deixa computadores offline sem explicação.

### S4 — credenciais de TURN para quem não se autenticou

**Gravidade: média.** Corrigido junto com o S3.

O `welcome` de `/ws/agent` inclui credenciais TURN válidas por 12 horas. Como o
canal não autentica (S3), qualquer pessoa abre um WebSocket, manda um `hello`
com um id inventado e recebe credencial de relay.

Na prática: **um relay aberto de graça na sua conta da Oracle.** É a conta de
banda que fizemos no `custos-para-distribuir.md` sendo paga para o tráfego de
outra pessoa.

**Conserto:** a credencial só vai no `welcome` de aparelho **pareado**. Quem
ainda não pareou não transmite nada, então não precisa dela.

Com teste dos dois lados — e o segundo é obrigatório: cortar a credencial de
quem não pareou só é conserto se quem pareou continuar recebendo. Sem essa
metade, a suíte passaria com o TURN desligado para todo mundo, e o sintoma
apareceria como vídeo que não fecha no 4G, no celular de outra pessoa.

### S5 — a sessão de tela não morria quando o token morria

**Gravidade: média.** Corrigido.

`/ws/viewer/{device_id}` valida o token **uma vez**, na conexão. O access token
dura 15 minutos; uma sessão de controle dura horas. Trocar a senha revoga os
tokens (via `token_key`) e fecha as rotas HTTP, mas **não derruba um canal de
tela já aberto** — que é justamente o que mostra a tela e recebe teclado e
mouse.

Cenário: alguém entrou na sua conta, você troca a senha para expulsar, e a
sessão de controle dele continua de pé.

**Conserto:** o laço do viewer acorda a cada 30 segundos e reconfere o
vínculo; quando ele cai, fecha o socket com o código 4401.

Uma decisão embutida aí, que vale explicar: a reconferência **ignora o `exp` do
token**, de propósito. O prazo de 15 minutos do access token existe para limitar
quantas conexões **novas** um token roubado abre; aplicá-lo a uma conexão já
autenticada derrubaria toda sessão de controle a cada quinze minutos, e trocaria
um problema de segurança por um defeito que qualquer pessoa encontra no primeiro
uso longo. O que se reconfere é **revogação**: a conta existe, o aparelho ainda
é dela, e a geração de sessão do token ainda é a atual.

O prazo no `receive()` também não é detalhe: sem ele o laço só acordaria quando
o app mandasse alguma coisa — e os frames vão no sentido contrário. Quem fosse
expulso continuaria vendo a tela até resolver mexer no aparelho.

Testado em `test_sessoes.py`, com a senha trocada no meio de uma sessão aberta.
O teste falha com a revalidação desligada.

### S6 — o segredo do 2FA ficava em texto puro no banco

**Gravidade: média.** Corrigido.

`User.totp_secret` é uma coluna de texto sem cifra. Quem obtiver o banco — ou um
dos backups diários — gera os códigos de 2FA de todo mundo. O 2FA existe
exatamente para o caso de a senha ter vazado; se as duas coisas caem no mesmo
arquivo, ele protege menos do que parece.

**Conserto:** `app/cofre.py` cifra a coluna (Fernet) com uma chave que não
mora no banco. Isso cobre o vazamento realista — a cópia diária sai da VM e vai
parar num computador, numa nuvem, num pendrive, e o `.env` não vai junto.
Contra quem já está dentro da VM não protege, e nada protegeria.

Três decisões que evitam trancar gente do lado de fora:

**A abertura tenta todas as chaves; a gravação usa a primeira.** Cifrar com uma
chave e depois trocá-la transformaria todo segredo guardado em lixo, e quem usa
2FA não entraria mais. Assim, acrescentar `DESKSIDE_TOTP_KEY` depois é seguro.

**Sem chave própria, deriva do `jwt_secret`** — com um prefixo, para que vazar
um não entregue o outro. Não é o ideal, mas funciona sem mexer no `.env` de quem
já está no ar, e a derivada continua na lista de chaves que abrem.

**Cada valor leva a marca `enc1:`.** Sem marca é texto puro de antes, devolvido
como está — é o que permite a migração sem parada. A varredura em `db._migrate`
cifra o que já existia, porque a próxima gravação natural seria a pessoa
reconfigurar o 2FA, o que pode nunca acontecer.

E falha **fechado**: quando nenhuma chave abre, `abrir()` devolve `None`, o
`verify_totp` reprova o código e o log explica. O contrário faria de uma chave
perdida um contorno do segundo fator.

A segunda metade também foi feita: **a cópia de segurança sai cifrada da VM**,
quando `DESKSIDE_BACKUP_KEY` está no `.env`.

Aqui a escolha se inverte, e de propósito: sem chave configurada, **não cifra**.
A assimetria é o argumento — um backup sem cifra corre risco de ser lido; um
backup que não abre está destruído, com certeza. Cifrar por padrão com uma chave
derivada de outra coisa transformaria "perdi o `.env`" em "perdi todos os
backups". Guarde a chave fora da VM: um gerenciador de senhas, um papel.

Dois detalhes que teriam mordido depois: cifrar **apaga o original** (a cópia
cifrada ao lado da legível não protege nada), e a limpeza das catorze mais
antigas passou a enxergar `.db.enc` — com o filtro antigo, nenhuma cifrada seria
apagada nunca, e um backup que enche o disco derruba o servidor que ele existe
para proteger.

### S7 — dependências sem trava de versão

**Gravidade: média.** Corrigido.

O `pyproject.toml` usa `>=` em tudo e não há arquivo de trava. Duas
consequências: dois `docker build` do mesmo commit podem gerar imagens
diferentes, e uma versão comprometida de qualquer dependência entra sozinha no
próximo deploy. O agente tem `Cargo.lock`; o backend não tem equivalente.

**Conserto:** `backend/requirements.txt` travado **com hashes**, gerado por
`pip-compile` no mesmo Python 3.12 da imagem, e o Dockerfile passou a instalar
dele. Versão fixa diz **qual** pacote; o hash diz que é **aquele** pacote — sem
ele, um pacote republicado com o mesmo número passaria.

Conferido instalando o arquivo num ambiente limpo, com a checagem de hash
ligada, e importando tudo.

De quebra, uma descoberta: o `RUN pip install .` do Dockerfile **nunca instalou
o pacote**. Ele rodava antes de a pasta `app` ser copiada, e sem
`[build-system]` o setuptools não achava nada para empacotar — o passo instalava
uma distribuição vazia e servia só para puxar dependências. Saiu, com a
explicação no lugar.

E `backend/scripts/auditar.sh` faz as duas conferências que faltavam: se o
arquivo travado ainda corresponde ao `pyproject.toml` (senão o Docker instala um
conjunto que ninguém escolheu) e se alguma dependência tem falha conhecida.
Na primeira execução: nenhuma.

"De vez em quando" não é uma frequência — um comando com nome é o que vira
hábito, e é o que se põe numa CI no dia em que houver uma.

### S8 — o Android aceitava tráfego em texto puro

**Gravidade: baixa.** Corrigido.

`android:usesCleartextTraffic="true"` libera `http://` para **qualquer** destino.
Existe porque o campo "Servidor" aceita `http://IP:8000` na rede local. O
endereço padrão é `https://`, então só corre risco quem digitar um `http://` à
mão.

**Conserto:** uma *network security config* que recusa texto puro por padrão,
com exceções nomeadas.

E aqui a proposta original não era possível: **o Android não aceita faixas de IP**
nessa configuração — só nomes e endereços literais. Nada de `192.168.0.0/16`. A
lista ficou curta e explícita: `localhost`, `127.0.0.1` e `10.0.2.2` (o host
visto de dentro do emulador), mais um `debug-overrides` que libera tudo em build
de depuração.

**Consequência real:** um APK de *release* apontado para `http://192.168.x.x`
deixa de conectar. Para desenvolver na rede local, `flutter run` (build de
depuração) ou acrescentar o endereço à lista.

Não consigo compilar Android aqui, então o que dava para verificar foi
verificado: o passo do `codemagic.yaml` foi extraído e executado contra uma
pasta `android/` falsa parecida com a que o `flutter create` gera. O manifesto
saiu com `networkSecurityConfig` e sem `usesCleartextTraffic`, o XML é bem
formado, e a guarda derruba o build se o texto puro voltar — conferido fazendo
ele voltar.

### S9 — a redefinição de senha passa por cima do 2FA

**Gravidade: baixa.** Comportamento a documentar, não necessariamente a mudar.

Quem controla o e-mail da conta redefine a senha e entra, sem apresentar o
código do autenticador. É o comportamento da maioria dos serviços, e exigir 2FA
na redefinição tranca fora quem perdeu o telefone. Fica registrado para ser uma
decisão, e não um descuido.

### S10 — nomes reservados do Windows na transferência de arquivos

**Gravidade: baixa.**

**Corrigido.**

`files::safe_name` já derrubava separadores de caminho, caracteres ilegais e
caracteres de controle. Faltavam os nomes de dispositivo do DOS: `CON`, `NUL`,
`PRN`, `AUX`, `COM1`..`COM9`, `LPT1`..`LPT9`. `NUL` não é arquivo — é o buraco
onde os bytes somem —, então a transferência terminava dizendo que deu certo com
nada no disco. Agora ganham um sublinhado na frente, e não uma recusa: o arquivo
chegou, alguém quis mandá-lo, e negar por causa de um nome seria perder o
conteúdo por uma herança do MS-DOS. A reserva vale com qualquer extensão, então
a comparação olha só até o primeiro ponto — e `CONTA.pdf` e `COM10.txt` passam
intactos, porque renomear arquivo legítimo também é estrago.

Junto, o defeito de correção: `Incoming::create` usava `with_extension("parte")`,
então `a.png` e `a.txt` chegando juntos disputavam o mesmo `a.parte`. Agora o
sufixo é **acrescentado**, e o temporário herda a unicidade que o `free_path` já
garantia ao nome final.

---

## O que foi verificado e está certo

Vale registrar, porque uma revisão que só lista problemas não diz o que já se
pode parar de conferir:

- **Autorização por dono.** Toda rota de `/devices/{device_id}` passa por
  `_owned_device_or_404`; as de automações e perfis filtram por `user_id`. Uma
  varredura de todas as rotas não achou nenhuma sem checagem. Não há IDOR.
- **O canal de tela autentica.** `_authenticate_viewer` confere assinatura, tipo
  do token, posse do dispositivo **e** a geração de sessão — inclusive a
  conferência que o comentário no código diz ser a que não pode faltar.
- **Travessia de diretório fechada** nos dois sentidos: leitura via
  `resolve()` com `canonicalize` + `starts_with(home)`, escrita via
  `safe_name()` numa caixa de entrada fixa.
- **Senhas com bcrypt**, limite de 72 bytes validado na entrada em vez de
  truncado em silêncio.
- **Revogação de sessão funciona**: `token_key` na conta, comparada com
  `hmac.compare_digest`, e tokens sem o campo são recusados em vez de aceitos
  "por compatibilidade".
- **Código de verificação**: seis dígitos guardados sob HMAC com chave (e não
  hash simples, que um milhão de combinações quebraria), cinco tentativas,
  prazo, e limite de reenvio.
- **Limite de tentativas** nos três caminhos sem login, cobrando **antes** do
  bcrypt e **antes** da consulta ao banco — o segundo evita transformar
  "esqueci a senha" num oráculo de quem tem conta.
- **Credenciais de TURN** pelo esquema REST temporário padrão (HMAC-SHA1 sobre
  `expiração:usuário`), 12 horas.
- **Tokens no aparelho** em Keychain/Keystore via `flutter_secure_storage`, e
  `allowBackup="false"` no Android.
- **TLS do agente** pelo `native-tls` com verificação padrão; nenhum
  `danger_accept_invalid_certs` no código.
- **Sem CORS liberado** e sem cliente web — nada de origem cruzada.
- **SQL** só por ORM; nenhuma consulta montada com texto.
- **Segredos fora do Git**: `.env` ignorado, chave SSH nunca versionada.

## A ordem em que eu resolveria o que sobrou

1. ~~**S5**~~ **Feito.**
2. ~~**S3 + S4**~~ **Feito.** Falta apenas fechar a trava
   (`DESKSIDE_EXIGIR_SEGREDO_DO_AGENTE=true`) quando todo agente tiver
   atualizado.
3. ~~**S7**~~ **Feito.** Falta rodar `pip-audit` periodicamente.
4. ~~**S6**~~ **Feito** para o banco. Falta **cifrar o backup** antes de ele sair
   da VM.
5. ~~**S8**~~ **Feito**, e sem poder compilar Android aqui — quem confirma é o
   Codemagic e um aparelho de verdade.

**Todos os achados estão fechados.** O que resta não é achado, é operação:

- Ligar `DESKSIDE_EXIGIR_SEGREDO_DO_AGENTE=true` quando todo agente tiver
  atualizado.
- Pôr `DESKSIDE_BACKUP_KEY` no `.env` da VM — e guardar a chave fora dela.
- Rodar `backend/scripts/auditar.sh` de tempos em tempos.
- E o que nenhuma dessas linhas substitui: **uma revisão por alguém que não
  escreveu este código**, antes de cobrar de estranhos.

E, antes de cobrar de estranhos: **uma revisão por alguém que não escreveu este
código**. Tudo acima saiu de leitura minha, e há um limite conhecido para o que
se enxerga no próprio trabalho.
