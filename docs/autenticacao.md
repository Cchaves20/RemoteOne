# Autenticação (Etapa 2)

Cadastro em duas etapas com verificação por código, login por e-mail **ou**
telefone, e tokens JWT. Os métodos externos (Google, Apple, Microsoft) e o 2FA
são construídos por cima desta base.

## Criar conta: duas etapas, e a conta nasce na segunda

O formulário pede nome, sobrenome, data de nascimento, **e-mail ou telefone**,
senha e confirmação. Ele vai inteiro numa chamada, o servidor valida tudo e
manda um código de seis dígitos. Só quando o código volta certo é que a conta
existe.

### Por que a conta não nasce na primeira etapa

Não é preciosismo. Um usuário não verificado ocuparia o e-mail na restrição de
unicidade — e bastaria digitar o endereço de outra pessoa para **impedir que ela
se cadastre**, sem nunca provar que o endereço é seu. Enquanto não há
verificação, o que existe é uma linha em `pending_signups`, com a senha já em
hash: entre o preenchimento e a confirmação passam minutos, e guardar a senha em
claro nesse intervalo seria guardar em claro.

### Por que validar antes de enviar

Cada cadastro por telefone custa um SMS. Recusar a senha fraca, o número
impossível e a idade abaixo do mínimo **antes** do envio evita gastar dinheiro
para depois dizer "a senha precisa de um número".

### O código

Seis dígitos, e não um link, porque o cadastro por telefone chega por SMS — onde
não há link que devolva a pessoa a um app instalado por sideload. Um mecanismo
para os dois caminhos vale mais que dois mecanismos.

| | |
|---|---|
| Validade | 10 minutos |
| Tentativas | 5, e depois o cadastro é descartado |
| Espera entre reenvios | 60 segundos |

O código é guardado como **HMAC-SHA256 com o segredo do servidor**, não com
bcrypt. Bcrypt existe para encarecer cada tentativa de adivinhar uma senha a
partir do hash; com um milhão de combinações, quem tiver o banco testa todas de
qualquer jeito. O que de fato protege é a chave: sem o segredo do servidor, o
milhão não ajuda. E o cadastro não paga duas passagens de bcrypt por conta.

Errar cinco vezes derruba o cadastro inteiro, e não só o código: reaproveitar o
pendente com um código novo devolveria as tentativas de graça.

## Senha: cinco regras

Mínimo de 8 caracteres, uma maiúscula, uma minúscula, um número e um caractere
especial. O erro do servidor diz **o que falta**, e o app mostra as cinco
acendendo enquanto se digita — um formulário que revela uma exigência por vez faz
a pessoa tentar cinco vezes para descobrir cinco regras.

"Especial" é definido por exclusão (tudo que não é `A-Za-z0-9`), o que torna
`ç` e o espaço válidos. É leniente de propósito: as regras são um piso, e frase
com espaço é um jeito legítimo e forte de escolher senha.

O teto é 72 **bytes**, que é o limite do bcrypt. Recusar é melhor que truncar em
silêncio — truncado, duas senhas diferentes passariam a abrir a mesma conta.

A política existe em dois lugares: `backend/app/senha.py` **decide**,
`client/lib/services/senha.dart` **explica**. Se divergirem, o servidor recusa e
o app mostra o motivo que veio de lá.

## Telefone

O seletor tem 33 países. O número é guardado em **E.164** (`+5511987654321`), e
a normalização joga fora:

- a pontuação — `(11) 98765-4321` e `11987654321` são o mesmo número, e recusar
  um dos dois seria recusar por causa do hífen;
- o zero de tronco — o `0` que se disca antes do DDD dentro do Brasil não existe
  no número internacional;
- o código do país digitado junto — quem escreve `+55 11 …` com o Brasil
  escolhido não quer `+55 55 11 …`.

As duas últimas só acontecem **se o que sobra ainda couber** no intervalo do
país. Sem esse cuidado, `55 98765-4321` (DDD 55, Santa Maria) seria mutilado, e
o dono do número nunca conseguiria se cadastrar sem entender por quê.

Sem `libphonenumber`: a biblioteca do Google é a resposta certa para quem
formata e classifica números de 240 países. Aqui basta saber que o número tem a
cara certa antes de gastar um SMS — e uma tabela de trinta países cabe nos dois
lados sem uma dependência nativa a mais no iOS.

## Entrar

Aceita e-mail ou telefone, um campo de cada vez com um seletor em cima. Um campo
só que aceitasse os dois teria de adivinhar o país quando o texto parecesse um
número, e `987654321` não identifica ninguém sem saber de onde é.

A mensagem de erro é a mesma para "não existe" e "senha errada": distinguir as
duas diria a um estranho quais contas existem.

## Entrega do código: e-mail e SMS

Enviar de verdade custa provedor. O código está escrito atrás de uma interface
(`backend/app/entrega.py`) com **SMTP** e **Twilio** prontos, e um modo em que o
código vai para o diário do servidor.

Esse modo não é placebo: é como se testa o fluxo inteiro — validação, expiração,
tentativas, criação da conta — antes de contratar qualquer coisa. E deixa de
valer no instante em que as credenciais aparecerem no `.env`, sem uma linha de
código mudar.

**O `/health` diz em qual modo o servidor está**, e o app avisa na tela de
verificação quando o código não foi entregue de verdade. Sem isso, "o código não
chegou" começaria por dedução, e a pessoa esperaria um SMS que nunca vai chegar.

```
DESKSIDE_SMTP_HOST=smtp.resend.com
DESKSIDE_SMTP_PORT=587
DESKSIDE_SMTP_USER=resend
DESKSIDE_SMTP_PASSWORD=...
DESKSIDE_SMTP_FROM=Deskside <conta@seu-dominio>

DESKSIDE_TWILIO_SID=AC...
DESKSIDE_TWILIO_TOKEN=...
DESKSIDE_TWILIO_FROM=+15551234567
```

Vão no `deploy/.env` da VPS, que é gitignorado e nunca versionado. O
`docker-compose.lite.yml` passa o `.env` inteiro para o contêiner (`env_file`),
então acrescentar uma variável ali basta — não é preciso mexer no compose.

Nem sempre foi assim: o compose listava as variáveis uma a uma, e as de SMTP
ficaram de fora. O efeito é o pior possível para diagnosticar — o `.env` está
certo, o servidor sobe, o `/health` responde "ok", e o recurso continua
desligado. Depois de configurar, `atualizar.cmd -Vps` diz na conferência se o
envio está de pé.

## Esqueci minha senha

Um link na tela de login. Pede o e-mail ou o telefone, manda o **mesmo código de
seis dígitos** do cadastro, e a senha nova passa pelas **mesmas cinco regras**.
Ao acertar, a sessão já abre: quem acabou de provar posse do contato e escolher
uma senha nova fez tudo o que o login pediria — e a senha recém-criada é a que
mais se esquece se tiver de ser digitada de novo no minuto seguinte.

### A resposta é idêntica para conta que existe e conta que não existe

É a decisão que separa esta rota do cadastro, e ela inverte o critério de lá.

No cadastro, dizer "e-mail já cadastrado" é **necessário**: sem isso a pessoa
não sabe que deveria ir entrar em vez de tentar criar conta de novo. Aqui, a
mesma franqueza viraria um oráculo — alguém digitaria endereços em sequência e
montaria a lista de quem tem conta no Deskside. Como cada conta é um computador,
essa lista tem valor para quem a coletasse.

Então, quando o contato não existe: nada é criado, **nada é enviado** (um envio a
mais vazaria a mesma informação por outro caminho) e a resposta é a mesma, campo
a campo.

### O resto do comportamento

Prazo, tentativas e espera entre pedidos são os do cadastro. Dois detalhes
próprios:

- **Recusar a senha não gasta o código.** Se a senha nova não cumpre as cinco
  regras, o pedido continua de pé — perder o código por escolher mal a senha
  seria punir a pessoa por ler as regras depois.
- **Trocar a senha derruba todos os pedidos em aberto daquela conta**, e não só
  o que foi usado. Se havia dois códigos válidos, o segundo continuaria podendo
  trocar a senha depois.

Recuperar a senha **derruba as sessões abertas** — ver a seção de tokens abaixo.
É onde isso mais importa: quem chega aqui ou perdeu o acesso ou desconfia que
alguém o tem.

## Trocar o contato depois

A tela de conta mostra **"Alterar e-mail" ou "Alterar telefone"**, conforme o
que identifica a conta — quem entrou pelo número não tem e-mail nenhum para
trocar, e o botão errado ali não levava a lugar nenhum. É o `/auth/me` que
responde a pergunta: ele devolve os dois campos, e um deles vem nulo.

A troca tem **duas etapas**, como o cadastro, e pelo mesmo motivo: o contato
novo só entra na conta depois de provado.

1. `POST /auth/me/contact/start` — senha atual mais o contato novo. Valida,
   normaliza e manda um código para **o contato novo**. Nada muda na conta.
2. `POST /auth/me/contact/verify` — só o código; qual troca ele confirma sai do
   token. Aí sim o contato entra, e o antigo sai junto.

Antes a troca era imediata, e isso abria dois buracos de uma vez. O primeiro é o
óbvio: apontar a conta para um endereço que não é seu, e perdê-la — é por ele
que se entra e é para ele que vai a recuperação de senha. O segundo é o que
passava despercebido: a coluna é única, então o endereço alheio preso a esta
conta **impediria o dono real de se cadastrar**. Sem nunca provar nada.

Três detalhes que decidem se o conserto funciona:

- **A pendência não reserva o contato.** A tentação, ao adiar a troca, é gravar
  a pendência com o destino único "para ninguém pegar antes" — o que recriaria o
  problema num degrau acima: bastaria começar uma troca para o e-mail de outra
  pessoa para travar o cadastro dela. Uma pendência não prova posse. Duas trocas
  pendentes para o mesmo destino coexistem; quem confirma primeiro fica com ele,
  e a segunda recebe 409 (a conferência é refeita no `verify`, senão a unicidade
  do banco viraria um 500).
- **Os `PATCH /me/email` e `/me/phone` saíram.** Enquanto existissem, o código
  seria decoração. Há um teste guardando a porta fechada — o mesmo cuidado que o
  `/auth/register` recebeu.
- **O número novo passa pela mesma normalização do cadastro.** Sem isso, gravar
  "(11) 98765-4321" produziria uma forma que o login — que normaliza — nunca
  encontraria: a pessoa trocaria o telefone e ficaria fora da própria conta.

O contato novo **substitui** o antigo: a conta se identifica por um só, e é por
ele que se entra. Trocar um e-mail por um telefone limpa o e-mail — deixar os
dois preenchidos daria duas formas de login para uma conta que só provou uma.

Prazo, tentativas e espera de reenvio são os do cadastro. Uma diferença: começar
de novo com **outro** destino não espera o minuto, porque esse é o caso de ter
digitado errado, e o minuto existe contra apertar "enviar" de novo para o mesmo
lugar.

## Excluir a conta leva tudo junto

`DELETE /auth/me` apaga a conta **e** o que pertence a ela: computadores
pareados, perfis, automações e a ordem da barra.

Isso não é arrumação. O SQLite **reaproveita o identificador**: com uma coluna
`INTEGER PRIMARY KEY`, apagar a conta 1 faz a próxima nascer como 1 de novo, e
o que ficou para trás com `user_id = 1` passa a pertencer a outra pessoa sem
nada avisar. Foi exatamente o que aconteceu em uso — perfis e computadores de
uma conta excluída reapareceram numa conta recém-criada.

A limpeza é feita pelas declarações de `cascade` no `User` (ver
`app/models.py`), e **não** por chave estrangeira: o SQLite não as força por
padrão. Quem apaga é o SQLAlchemy. Uma coleção nova que não seja declarada lá
não vira uma linha esquecida e inofensiva no banco — vira a linha que aparece
na conta seguinte.

## Tokens

- **access token** — curta duração (padrão 15 min), enviado no header
  `Authorization: Bearer <token>` a cada requisição protegida.
- **refresh token** — longa duração (padrão 30 dias), trocado por um novo
  access token quando este expira.

O payload traz um campo `type` (`access`/`refresh`); o backend recusa usar um
no lugar do outro. Senhas são guardadas com hash **bcrypt** (nunca em texto).

### Cancelar um token que já saiu

JWT não tem como ser cancelado: é uma assinatura que o servidor confere sozinho,
sem consultar nada — e é exatamente isso que o torna barato. A consequência era
concreta e invisível: **trocar a senha não expulsava ninguém**. O refresh token
de quem tivesse entrado na conta continuava valendo os 30 dias inteiros,
renovando o access a cada 15 minutos. E trocar a senha é o que se faz justamente
quando se desconfia disso.

O conserto é uma **chave de sessão** por conta (`User.token_key`), que todo
token carrega no campo `tk`. Ao decodificar, o backend compara com a que está no
banco; trocar ou recuperar a senha sorteia outra, e todo token emitido antes
morre na mesma hora. Custo: nenhuma consulta a mais — a rota já carregou a linha
do usuário.

Três detalhes que decidem se isso funciona de verdade:

- **A chave é sorteada, não um contador a partir de zero.** O SQLite reaproveita
  `INTEGER PRIMARY KEY`: apagar a conta 1 faz a próxima nascer como 1, e o token
  da conta apagada tem o mesmo `sub`. Com contador, ele abriria a conta de outra
  pessoa — a mesma armadilha que fez perfis de uma conta excluída reaparecerem
  em outra, agora na forma de uma sessão inteira. Uma versão anterior tentou
  resolver pelo relógio (token emitido antes de a conta existir não é dela) e
  foi descartada: `iat` só tem segundos inteiros, e apagar e recriar dentro do
  mesmo segundo passava direto.
- **O WebSocket da tela confere igual.** Ele tem autenticação própria e não passa
  pelo `get_current_user`. Fechar as rotas HTTP e deixar aberto o canal que
  entrega imagem, teclado e mouse seria o pior resultado possível.
- **`PATCH /auth/me/password` devolve um par de tokens** em vez do antigo 204. A
  troca cancela todos os tokens da conta, **inclusive o de quem a fez**; sem o
  substituto na resposta, a pessoa trocaria a senha e cairia na tela de login no
  instante seguinte.

Trocar o e-mail ou o telefone **não** derruba sessão nenhuma: quem faz isso já
provou a senha atual, e deslogar todos os aparelhos por uma edição de contato
seria incômodo sem contrapartida. O corte é a credencial de entrada.

### Como o app reage ao 401

Duas situações se parecem muito e pedem respostas opostas.

**Token vencido.** O access token dura 15 minutos, e nada o renovava durante o
uso - só na abertura do app. Depois de um quarto de hora, toda ação respondia
"credenciais inválidas" até o app ser reaberto. Era o "parou de funcionar,
fechei e abri e voltou".

**Sessão encerrada.** Com o cancelamento acima, o aparelho derrubado precisa
cair na tela de login.

Tratar os dois igual dá o pior dos dois lados: deslogar no primeiro pediria a
senha a cada 15 minutos; insistir no segundo prenderia o aparelho numa sessão
morta. A diferença sai do **refresh token** - se ele ainda vale, era
vencimento; se o servidor o recusa, a sessão acabou. E há um terceiro caso que
não é nenhum dos dois: **rede fora**. Aí não se desloga, porque perder a sessão
por causa de um elevador seria pior que o problema original.

Falta ainda separar os 401 entre si. Senha atual errada e código de verificação
errado também respondem 401, e deslogar neles expulsaria quem só errou a
digitação. Quem separa é o cabeçalho **`WWW-Authenticate`**, que só o
`get_current_user` manda - é o que ele significa em HTTP. O contrato tem teste
dos dois lados (`test_sessoes.py` e `api_client_test.dart`), porque perdê-lo não
quebraria nada visível: uma rota de conta que levantasse 401 com o cabeçalho
passaria a deslogar por erro de digitação, em silêncio.

Tudo isso mora num `http.Client` que embrulha o de verdade
(`_ClienteComSessao`), então nenhuma das 35 chamadas do app precisou mudar.

**O que ainda falta:** o WebSocket da tela não renova nada. Se o token vencer
com a tela aberta, o canal é recusado e o app precisa reabrir a visualização.

Configuração por variável de ambiente (ver `app/config.py`):
`DESKSIDE_JWT_SECRET` (obrigatório trocar em produção),
`DESKSIDE_ACCESS_TOKEN_TTL_MINUTES`, `DESKSIDE_REFRESH_TOKEN_TTL_DAYS`,
`DESKSIDE_IDADE_MINIMA` (padrão 13, o piso da LGPD para tratamento de dados sem
consentimento dos pais).

## Endpoints

| Método | Rota | Corpo | Resposta |
|---|---|---|---|
| GET | `/api/v1/auth/countries` | — | lista de `{iso, name, dial_code, flag}` |
| POST | `/api/v1/auth/signup/start` | formulário completo | 201 + `{destination, channel, resend_in_seconds, delivered}` |
| POST | `/api/v1/auth/signup/verify` | `{destination, code}` | 201 + `{access_token, refresh_token}` |
| POST | `/api/v1/auth/signup/resend` | `{destination}` | `{destination, channel, …}` |
| POST | `/api/v1/auth/password/forgot` | `{email\|phone+country}` | `{destination, channel, resend_in_seconds, delivered}` — igual exista a conta ou não |
| POST | `/api/v1/auth/password/reset` | `{destination, code, password, password_confirm}` | `{access_token, refresh_token}` |
| POST | `/api/v1/auth/login` | `{email\|phone+country, password}` | `{access_token, refresh_token}` |
| POST | `/api/v1/auth/refresh` | `{refresh_token}` | `{access_token}` |
| GET | `/api/v1/auth/me` | — (Bearer) | `{id, email, phone, first_name, …}` |
| POST | `/api/v1/auth/me/contact/start` | `{current_password, email\|phone+country}` | `{destination, channel, resend_in_seconds, delivered}` |
| POST | `/api/v1/auth/me/contact/resend` | — (Bearer) | idem |
| POST | `/api/v1/auth/me/contact/verify` | `{code}` | a conta atualizada |
| PATCH | `/api/v1/auth/me/password` | `{current_password, new_password}` | `{access_token, refresh_token}` — os antigos param de valer |

**`/api/v1/auth/register` não existe mais.** Enquanto existisse, o código de
seis dígitos seria decoração: bastaria chamar a rota velha para ter conta sem
provar posse de e-mail nem de telefone. Há um teste guardando a porta fechada,
porque reabri-la por engano não quebraria mais nada.

Erros: já cadastrado → 409; código errado → 401 (com quantas tentativas
sobraram); código expirado → 410; tentativas ou reenvios demais → 429; provedor
recusou → 502; formulário fora do formato → 422; regra de negócio (senha fraca,
telefone impossível, idade) → 400 com o motivo em texto.

## Verificação manual

Com o backend rodando (`docker compose up` na pasta `backend/`):

```bash
curl -X POST http://localhost:8000/api/v1/auth/signup/start \
  -H "Content-Type: application/json" \
  -d '{"first_name":"Caio","last_name":"Chaves","birth_date":"1998-04-20",
       "email":"caio@example.com","password":"senhaSegura123!",
       "password_confirm":"senhaSegura123!"}'

# sem provedor configurado, o código aparece no log do servidor:
#   [verificação] e-mail para caio@example.com: 481920

curl -X POST http://localhost:8000/api/v1/auth/signup/verify \
  -H "Content-Type: application/json" \
  -d '{"destination":"caio@example.com","code":"481920"}'
```

Ou explore de forma interativa em <http://localhost:8000/docs>.

## Próximos passos desta etapa

1. **Limite de tentativas** em `/login`, `/signup/start` e `/password/forgot`.
   Não é tanto contra adivinhar senha — as cinco regras já tiram o dicionário do
   jogo, e o bcrypt limita a umas cinco tentativas por segundo. É contra o
   **custo**: esses 200 ms de bcrypt são do único worker da VM de 1 GB, e um
   loop de login derruba a API para todo mundo sem descobrir senha nenhuma. Nas
   duas rotas que mandam código, o desperdício é a cota do provedor de e-mail.
   Atraso crescente por IP e por conta, nunca bloqueio permanente — senão
   qualquer um tranca a conta alheia de fora.
2. **Login social** (Google/Apple/Microsoft): cada provedor valida a
   identidade e reaproveita a mesma emissão de tokens desta base.
3. **Controle de dispositivos autorizados**: vincular refresh tokens a
   dispositivos e permitir revogação um a um — hoje a chave de sessão é uma só
   por conta, então derrubar um aparelho derruba todos. Conecta com o
   pareamento (Etapa 5).
