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

Vão no `deploy/.env` da VPS, que é gitignorado e nunca versionado.

## Tokens

- **access token** — curta duração (padrão 15 min), enviado no header
  `Authorization: Bearer <token>` a cada requisição protegida.
- **refresh token** — longa duração (padrão 30 dias), trocado por um novo
  access token quando este expira.

O payload traz um campo `type` (`access`/`refresh`); o backend recusa usar um
no lugar do outro. Senhas são guardadas com hash **bcrypt** (nunca em texto).

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
| POST | `/api/v1/auth/login` | `{email\|phone+country, password}` | `{access_token, refresh_token}` |
| POST | `/api/v1/auth/refresh` | `{refresh_token}` | `{access_token}` |
| GET | `/api/v1/auth/me` | — (Bearer) | `{id, email, phone, first_name, …}` |

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

1. **Limite de tentativas** em `/login` — hoje não há freio contra força bruta,
   e uma conta do Deskside é um computador inteiro.
2. **Login social** (Google/Apple/Microsoft): cada provedor valida a
   identidade e reaproveita a mesma emissão de tokens desta base.
3. **Recuperação de senha**, que reaproveita inteiro o mecanismo de código
   deste cadastro — é o mesmo envio, o mesmo prazo e o mesmo limite de
   tentativas.
4. **Controle de dispositivos autorizados**: vincular refresh tokens a
   dispositivos e permitir revogação — conecta com o pareamento (Etapa 5).
