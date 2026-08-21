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

### S3 — o canal `/ws/agent` não tem autenticação

**Gravidade: alta.** Não corrigido.

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

**Conserto proposto:** no pareamento, o backend emite um segredo por
dispositivo; o agente guarda ao lado do `device_id` e o apresenta no `hello`. O
servidor recusa `hello` sem segredo válido. Desparear apaga o segredo, e aí
desparear passa a significar alguma coisa.

Custo: mexe no protocolo, no agente, no backend e na migração de quem já está
pareado — os agentes antigos precisam de um caminho de adoção. É lote próprio,
não remendo.

### S4 — credenciais de TURN para quem não se autenticou

**Gravidade: média.** Não corrigido, e sai junto com o S3.

O `welcome` de `/ws/agent` inclui credenciais TURN válidas por 12 horas. Como o
canal não autentica (S3), qualquer pessoa abre um WebSocket, manda um `hello`
com um id inventado e recebe credencial de relay.

Na prática: **um relay aberto de graça na sua conta da Oracle.** É a conta de
banda que fizemos no `custos-para-distribuir.md` sendo paga para o tráfego de
outra pessoa. Some quando o S3 for resolvido.

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

### S6 — o segredo do 2FA fica em texto puro no banco

**Gravidade: média.** Não corrigido.

`User.totp_secret` é uma coluna de texto sem cifra. Quem obtiver o banco — ou um
dos backups diários — gera os códigos de 2FA de todo mundo. O 2FA existe
exatamente para o caso de a senha ter vazado; se as duas coisas caem no mesmo
arquivo, ele protege menos do que parece.

**Conserto:** cifrar a coluna com uma chave que **não** esteja no banco (uma
variável de ambiente separada). E os backups deveriam ser cifrados de qualquer
forma antes de saírem da VM.

### S7 — dependências sem trava de versão

**Gravidade: média.** Não corrigido.

O `pyproject.toml` usa `>=` em tudo e não há arquivo de trava. Duas
consequências: dois `docker build` do mesmo commit podem gerar imagens
diferentes, e uma versão comprometida de qualquer dependência entra sozinha no
próximo deploy. O agente tem `Cargo.lock`; o backend não tem equivalente.

**Conserto:** gerar um `requirements.txt` travado (com `uv pip compile` ou
`pip-compile`), usá-lo no Dockerfile, e passar `pip-audit` de vez em quando.

### S8 — o Android aceita tráfego em texto puro

**Gravidade: baixa.** Não corrigido, e já está anotado no `codemagic.yaml`.

`android:usesCleartextTraffic="true"` libera `http://` para **qualquer** destino.
Existe porque o campo "Servidor" aceita `http://IP:8000` na rede local. O
endereço padrão é `https://`, então só corre risco quem digitar um `http://` à
mão.

**Conserto:** trocar por uma *network security config* que permita texto puro
apenas nas faixas privadas (10.x, 192.168.x, 172.16–31.x).

### S9 — a redefinição de senha passa por cima do 2FA

**Gravidade: baixa.** Comportamento a documentar, não necessariamente a mudar.

Quem controla o e-mail da conta redefine a senha e entra, sem apresentar o
código do autenticador. É o comportamento da maioria dos serviços, e exigir 2FA
na redefinição tranca fora quem perdeu o telefone. Fica registrado para ser uma
decisão, e não um descuido.

### S10 — nomes reservados do Windows na transferência de arquivos

**Gravidade: baixa.**

`files::safe_name` derruba corretamente separadores de caminho, caracteres
ilegais e caracteres de controle — a travessia de diretório está fechada, com
teste. O que ele não filtra são os nomes de dispositivo do DOS (`CON`, `NUL`,
`PRN`, `COM1`…). Mandar um arquivo chamado `NUL` faz a escrita se comportar de
forma estranha em vez de falhar limpo. É defeito de robustez, não porta de
entrada.

Junto dele, um defeito de correção que apareceu na leitura: `Incoming::create`
usa `with_extension("parte")` para o arquivo temporário, então `a.png` e `a.txt`
chegando ao mesmo tempo disputam o mesmo `a.parte`.

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
2. **S3 + S4** (segredo por dispositivo) — o lote maior, e o que mais muda a
   postura de segurança do produto.
3. **S7** (travar dependências) — uma tarde, e some uma classe inteira de
   surpresa no deploy.
4. **S6** (cifrar o segredo do 2FA e os backups).
5. **S8** (texto puro no Android) — antes da Play Store, que pergunta sobre isso.

E, antes de cobrar de estranhos: **uma revisão por alguém que não escreveu este
código**. Tudo acima saiu de leitura minha, e há um limite conhecido para o que
se enxerga no próprio trabalho.
