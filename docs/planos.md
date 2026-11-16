# Planos: grátis permanente, pago sem limitação

R$ 30 por mês na versão paga. A grátis não expira.

## O desenho, e por que cada linha

**Grátis é permanente, e não um teste.** Um teste que acaba produz uma tela de
"acabou" que a pessoa fecha e desinstala. Um plano grátis produz alguém que
continua usando, conta para os outros, e um dia esbarra num limite.

**Mas toda conta nasce com 30 dias do plano pago**, e depois cai para o grátis —
nunca para bloqueada. Quem provou um recurso e o perdeu converte muito melhor do
que quem nunca o teve, e o custo de errar é zero: ninguém fica sem produto.

## A divisão

| | Grátis | Pago |
|---|---|---|
| Computadores | 1 | ilimitados |
| Mouse, teclado, tela ao vivo | sim | sim |
| Abrir e fechar programas, encaixar janelas | sim | sim |
| Área de transferência | sim | sim |
| Automações (tocar para executar) | 1 | ilimitadas |
| Horário marcado | — | sim |
| Transferência de arquivos | — | sim |
| Modo apresentação | — | sim |
| Som do computador | — | sim |
| Perfis de controle | — | sim |
| Vários monitores | — | sim |

O princípio de cada linha: **o limite tem que ser esbarrado por satisfação, não
por frustração no começo.** Quem trava nos primeiros dez minutos desinstala e
não conta para ninguém.

**A tela ao vivo fica de graça** apesar de ser o que mais custa em banda. É o
que faz a pessoa mostrar o produto para alguém, e essa demonstração é o
marketing. Pelas contas de [`custos-para-distribuir.md`](custos-para-distribuir.md),
cem usuários pesados gastariam 340 GB dos 10 TB inclusos — cortar isso
economizaria quase nada e mataria o boca a boca.

**O segundo computador é o limite mais eficaz que existe.** É esbarrado uma vez,
com força, por quem já gostou, e é honesto: quem tem dois computadores tira o
dobro de valor.

**O horário marcado é o melhor recurso pago do produto.** É o que faz o Deskside
trabalhar sozinho, e é desejado repetidamente — um desejo semanal converte
melhor que um desejo único.

**Nada de segurança entra na lista.** 2FA, revogação de sessão, o botão de
desinstalar: cobrar por proteção é o tipo de decisão que aparece no Reddit.

**E nada de limite de tempo por sessão.** É a tentação óbvia e o erro clássico:
transforma a demonstração numa interrupção, exatamente no instante em que a
pessoa ia se impressionar.

## Onde a regra mora

`backend/app/plano.py` — as regras, sem FastAPI, testáveis sem servidor.
`backend/app/cobranca.py` — a cola com o HTTP: qual status e o que dizer.

**A regra é aplicada no servidor, e só no servidor.** O aplicativo é código que
roda no aparelho de outra pessoa: esconder um botão lá é apresentação, não
regra. Todos os testes de recusa em `tests/test_plano.py` batem na API, nunca na
tela.

### 402, e não 403

`403` é "você não pode". `402 Payment Required` é "você poderia, pagando". A
diferença permite ao app distinguir *isto não é seu* de *isto é do plano pago*
sem interpretar texto — um 403 faria o aplicativo mostrar "acesso negado" a quem
só precisava saber que existe um plano.

E a **ordem** importa: a checagem de dono vem antes da de plano. Quem pede o
computador de outra pessoa recebe 404, não uma oferta — dizer "isto é pago"
sobre o que não é seu confirmaria que aquele identificador existe.

### A data manda sobre o rótulo

`plano_efetivo` olha `plano` **e** `plano_ate`. Guardar só o rótulo obrigaria uma
tarefa noturna a rebaixar contas vencidas — e uma tarefa que não roda deixa gente
no plano pago sem ninguém perceber. Com a data, uma assinatura vencida vale tanto
quanto nenhuma, sem nada precisar rodar.

O `/auth/me` devolve o plano **efetivo**, e não o guardado: uma tela que promete o
que o servidor nega é pior que uma tela que não promete nada.

## Ligar uma conta à mão

Enquanto não há cobrança automática — e depois também, para dar acesso a um
amigo ou consertar um pagamento que não chegou:

```bash
cd ~/Deskside 2>/dev/null || cd ~/RemoteOne
sudo docker compose -f deploy/docker-compose.lite.yml exec -T api \
    python -m app.conta ver caio@example.com

... python -m app.conta pago caio@example.com --dias 365
... python -m app.conta pago caio@example.com --sem-prazo
... python -m app.conta gratis caio@example.com
```

O `ver` mostra o rótulo guardado **e** o que vale agora, porque eles podem
discordar — e é essa discordância que explica "o cliente diz que pagou e o app
diz que é grátis".

Renovar soma a partir de hoje ou do prazo atual, o que for maior: quem renova
antes do fim não perde o que sobrou, e quem voltou depois de meses não recebe um
prazo que já nasce vencido.

## O que ainda não existe

- **Processador de pagamento.** Nada de Stripe, Mercado Pago ou compra dentro do
  app. `pago` se liga à mão.
- **Um botão de assinar.** Não existe porque não há como assinar: o app mostra
  o endereço de contato e o copia. Um botão que abrisse uma tela vazia custaria
  mais confiança do que a ausência dele.
## O aviso de fim do mês completo

`backend/app/avisos.py`, rodado uma vez por dia pelo cron da VM:

```bash
sudo docker compose -f deploy/docker-compose.lite.yml exec -T api python -m app.avisos
```

Sai cinco dias antes: perto o bastante para ser concreto ("acaba na sexta") e
longe o bastante para caber uma decisão. Rodar duas vezes no mesmo dia não manda
nada duas vezes — quem já foi avisado fica marcado.

Três detalhes:

**O texto abre com o que continua funcionando**, e só depois diz o que fica no
plano pago. Uma mensagem que abre com o que se perde é lida como ameaça, e a
reação a uma ameaça de software é desinstalar.

**Falha de envio não marca a conta.** Um provedor fora do ar por uma hora não
pode custar o aviso inteiro: a tarefa de amanhã tenta de novo.

**Conta criada por telefone não é marcada em silêncio.** Sem SMS contratado não
há por onde avisar, e fingir que houve esconderia esse caso para sempre — o
defeito só apareceria como "eu não fui avisado", meses depois.

Instalar no cron, junto do backup:

```bash
( crontab -l 2>/dev/null | grep -v 'app.avisos'; \
  echo "23 12 * * * sh -c 'cd ~/Deskside 2>/dev/null || cd ~/RemoteOne; sudo docker compose -f deploy/docker-compose.lite.yml exec -T api python -m app.avisos' >> ~/avisos.log 2>&1" ) | crontab -
```

Meio-dia, e não de madrugada: um e-mail que chega às 3h fica no fim da caixa de
entrada quando a pessoa acorda.
