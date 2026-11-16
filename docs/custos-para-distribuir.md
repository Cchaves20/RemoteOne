# Quanto custa colocar o Deskside na rua

Tudo que precisa ser pago para o produto sair de "funciona na minha casa" e
virar algo que um estranho instala, usa e paga.

**Duas ressalvas antes dos números.** Os preços são do que eu conhecia até maio
de 2026 e mudam — confirme cada um antes de gastar. E o câmbio usado é
**US$ 1 = R$ 5,50**; se estiver diferente, os valores em real mudam junto.

## A tabela, item por item

| Item | Uma vez | Por mês | Obrigatório? |
|---|---:|---:|---|
| Google Play Console (US$ 25) | R$ 138 | — | sim |
| Revisão jurídica dos termos | R$ 1.000 a 3.000 | — | sim, antes de cobrar |
| Abertura do CNPJ (MEI) | R$ 0 | — | sim |
| Apple Developer (US$ 99/ano) | — | R$ 45 | sim |
| DAS do MEI | — | R$ 78 | sim |
| Domínio `.com.br` (R$ 40/ano) | — | R$ 3 | sim |
| Envio de e-mail (Amazon SES) | — | R$ 5 | sim |
| Servidor (Oracle Always Free) | — | R$ 0 | sim |
| Azure Trusted Signing (US$ 9,99/mês) | — | R$ 55 | não |
| — *ou* certificado EV (~US$ 500/ano) | — | R$ 229 | não |
| SMS (Twilio) | — | — | **não faça** |

## Os totais

Usando R$ 2.000 para a revisão jurídica (meio da faixa):

| Cenário | Uma vez | Por mês | **Primeiro ano** |
|---|---:|---:|---:|
| **A — sem certificado** | R$ 2.138 | R$ 131 | **R$ 3.710** |
| **B — com Azure Signing** | R$ 2.138 | R$ 186 | **R$ 4.370** |
| **C — com certificado EV** | R$ 2.138 | R$ 361 | **R$ 6.470** |

A partir do segundo ano cai para 12 × a mensalidade: **R$ 1.572**, **R$ 2.232**
ou **R$ 4.332**.

**Só para pôr no ar, sem cobrar ainda**, tire a revisão jurídica: R$ 138 de
entrada e R$ 131 por mês. Isso é o cenário A menos os R$ 2.000, e é onde dá
para começar.

## O custo que não está na tabela

**15% de cada mensalidade vai para a Apple ou para o Google.** É variável, então
não cabe nas linhas acima — mas assim que houver clientes ele passa tudo o mais.

```
R$ 30,00  mensalidade
- R$ 4,50  15% da loja
= R$ 25,50 líquido por assinante
```

Vendendo pelo site, a taxa do processador de pagamento fica em torno de 5% e
sobram R$ 28,40 — R$ 3 a mais por assinante, todo mês.

## Quantos assinantes fecham a conta

| Cenário | Só o mensal | Primeiro ano, com o de uma vez diluído |
|---|---:|---:|
| A | 6 | 13 |
| B | 8 | 15 |
| C | 15 | 22 |

A coluna da direita é a honesta para quem está começando: ela paga também os
R$ 2.138 de entrada ao longo dos doze primeiros meses.

**Treze a quinze assinantes cobrem o primeiro ano inteiro** nos cenários que eu
escolheria. É uma barreira baixa, e é a notícia boa desta página.

## Obrigatório — sem isto ninguém além de você usa

### Apple Developer Program — US$ 99/ano (~R$ 545/ano, ~R$ 45/mês)

É o item mais importante da lista, e não por causa da App Store.

Hoje o app entra no seu iPhone por sideload com Apple ID grátis, e isso
**expira em 7 dias, por aparelho, com o cabo na mão**. Não é uma limitação que
dá para contornar com jeitinho: é o desenho da Apple. Enquanto for assim, o
iPhone é uma plataforma onde só você consegue usar o Deskside.

Os US$ 99 resolvem duas coisas de uma vez: o TestFlight (até 10.000 testadores,
builds que duram 90 dias) e a App Store propriamente dita.

### Google Play Console — US$ 25, uma vez só (~R$ 140)

Pagamento único, para sempre. Comparado aos US$ 99/ano da Apple, é de graça.

**A pegadinha não é o preço.** Contas pessoais criadas depois de novembro de
2023 precisam rodar um teste fechado com **12 testadores por 14 dias seguidos**
antes de poder publicar. Contas de organização (com CNPJ) são dispensadas disso.

Ou seja: o CNPJ, que parecia assunto de contabilidade, encurta o lançamento no
Android em duas semanas e doze pessoas.

### Domínio `deskside.com.br` — ~R$ 40/ano

Já pago. Renove em dia: domínio expirado derruba site, API e agentes ao mesmo
tempo, porque tudo aponta para ele.

### Servidor — R$ 0, e a banda não é o problema

A VM da Oracle é do nível gratuito permanente. A pergunta natural é se vai ser
preciso aumentar a banda, e a resposta é não — mas por um motivo que vale
entender, porque ele muda **qual** peça apertar quando apertar.

#### Por que a maior parte do vídeo não passa pelo servidor

O Deskside usa WebRTC. Quando o celular e o computador conseguem se achar
diretamente, **a tela vai de um para o outro sem tocar na VM** — o servidor só
apresentou os dois. Nesses casos o tráfego do servidor é de bytes: um punhado
de mensagens de sinalização.

O relay (coturn) só entra quando os dois lados estão atrás de NAT que não
atravessa — o caso comum em 4G/5G, onde a operadora põe milhares de assinantes
atrás do mesmo IP. Aí sim, todo o vídeo passa pela VM.

Chute conservador: **um quarto das sessões** cai no relay.

#### As contas

Uma sessão de tela relayed gasta por volta de 3 Mbps, o que dá **1,35 GB por
hora**.

Com 100 assinantes, cada um usando 10 horas por mês, e 25% disso no relay:

```
100 × 10 h × 25% = 250 horas relayed
250 h × 1,35 GB  = 340 GB por mês
```

O nível gratuito da Oracle inclui **10 TB de saída por mês** — cerca de trinta
vezes isso. Os downloads do instalador nem contam: o `.exe` tem 21 MB, e dez mil
downloads somam 210 GB.

A **velocidade** também sobra. A `E2.1.Micro` entrega 480 Mbps, e a 3 Mbps por
sessão relayed isso são mais de cem sessões simultâneas. Você vai bater em
outra coisa muito antes.

#### O que vai apertar primeiro: a memória

O gargalo real da sua VM é **1 GB de RAM** rodando Caddy, a API e o coturn ao
mesmo tempo — é por isso que existe um `docker-compose.lite.yml` e por isso que
o swap é obrigatório.

E a boa notícia é que o conserto é de graça: a `VM.Standard.A1.Flex` (ARM,
Ampere) também é Always Free e dá **4 OCPU e 24 GB de RAM**. Vinte e quatro
vezes a memória, 1 Gbps por OCPU, custo zero. O que impede não é preço, é
disponibilidade — a cota ARM vive esgotada, e a saída é insistir em outro
Availability Domain até aparecer vaga.

Ou seja: o upgrade que você precisa não é de banda, é de instância, e ele é
gratuito.

#### O risco de verdade, e como tirá-lo de graça

A Oracle **reivindica instâncias ociosas** do nível gratuito. Para um projeto de
estudo, tudo bem. Para um produto pago, um dia fora do ar é um dia de reembolso
e de gente cancelando.

O jeito de eliminar isso sem gastar: **converter a conta para Pay As You Go**.
As contas pagas ficam de fora da política de recuperação por ociosidade, e os
recursos Always Free continuam gratuitos — você só paga se passar dos limites,
o que pelas contas acima não vai acontecer tão cedo. Exige um cartão cadastrado.

Confirme os termos antes de fazer, que é justamente o tipo de política que
muda; mas se continuar valendo, é o melhor negócio da lista: some o único risco
sério da infraestrutura por R$ 0.

Trocar por um servidor pago (Hetzner, DigitalOcean) custa **US$ 5 a US$ 7 por
mês** (~R$ 30 a R$ 40) e continua sendo o plano B — não porque a banda acabou,
mas se a Oracle mudar de ideia sobre o nível gratuito.

### Envio de e-mail — ~R$ 5/mês, na prática quase zero

O cadastro verifica por código, e hoje o código vai para o log do servidor.
Funciona para você e para mais ninguém.

- **Amazon SES**: US$ 0,10 por mil e-mails. Mil cadastros custam sessenta
  centavos. É o mais barato de longe. Exige sair do "sandbox" — um formulário
  explicando o uso, aprovado em um ou dois dias.
- **Resend**: 3.000 e-mails/mês de graça, US$ 20/mês depois. Mais simples de
  configurar, mais caro quando crescer.

Comece pelo SES. O custo é ruído.

### SMS — **não faça**

Twilio para número brasileiro sai por volta de **US$ 0,05 a US$ 0,08 por
mensagem** (R$ 0,28 a R$ 0,44), e ainda exige registro de remetente junto às
operadoras.

Faça a conta: numa assinatura de R$ 30, cada SMS come até 1,5% da mensalidade —
e verificação é justamente o que mais se manda para quem **ainda não pagou**.
Uma leva de cadastros falsos vira prejuízo direto.

A verificação por e-mail cobre o mesmo caso de uso por um custo mil vezes menor.
O código de SMS já está pronto atrás de uma interface no backend; deixe
desligado até existir um motivo concreto para ligá-lo.

## Para os avisos do Windows sumirem

O `.exe` não é assinado, e é por isso que aparece a tela azul do SmartScreen.
Três caminhos, do mais barato ao mais caro:

### Azure Trusted Signing — US$ 9,99/mês (~R$ 55/mês)

De longe o mais barato, e o que eu tentaria primeiro.

**Confirme a elegibilidade antes de contar com isto.** Até onde eu sei, a
Microsoft exige uma pessoa jurídica com **três anos de existência verificável**
para o plano padrão. Um MEI aberto este mês não passaria. Havia um caminho para
desenvolvedor individual, mas não sei em que estado está — é a primeira coisa a
checar.

### Certificado OV — ~US$ 220 a 400/ano (~R$ 1.200 a 2.200/ano, R$ 100 a 183/mês)

Reduz o aviso, não elimina: a reputação vai se acumulando ao longo de semanas de
downloads. Desde 2023 a chave tem que ficar em token físico ou HSM na nuvem, o
que pode acrescentar custo e enviar um dispositivo pelo correio.

### Certificado EV — ~US$ 400 a 600/ano (~R$ 2.200 a 3.300/ano, R$ 183 a 275/mês)

**Elimina o aviso na hora**, sem esperar reputação. Exige CNPJ e verificação da
empresa.

### E o que é de graça

Submeter o `.exe` em <https://www.microsoft.com/en-us/wdsi/filesubmission>. Só
ajuda se o Defender estiver detectando algo; contra falta de reputação, faz
pouco. Precisa ser refeito a cada versão do executável.

## Para poder cobrar de verdade

### CNPJ (MEI) — ~R$ 75 a 80/mês

Abrir é grátis e leva minutos. O que custa é o DAS mensal, por volta de
**R$ 75 a 80** para serviços (confirme o valor de 2026 — ele sobe com o
salário mínimo).

Sem CNPJ você não emite nota fiscal, não abre conta de organização nas lojas,
não tira certificado EV, e cai no limite de 12 testadores do Google.

O teto de faturamento do MEI é de **R$ 81.000/ano** (havia projetos para
aumentar; confirme). A R$ 30/mês, isso são 225 assinantes simultâneos o ano
inteiro — problema bom de ter, e quando chegar lá o passo é migrar para
Microempresa.

### As lojas ficam com 15% — e este é o maior custo de todos

Apple e Google exigem que assinatura de serviço digital consumida dentro do app
passe pelo sistema de pagamento **deles**. A taxa é de 15% para quem fatura
menos de US$ 1 milhão por ano — os dois têm programa para pequeno
desenvolvedor.

Numa mensalidade de R$ 30: **R$ 4,50 vão embora antes de qualquer outra coisa.**

Existem discussões e decisões judiciais sobre links de pagamento externos, no
Brasil inclusive, mas o estado disso muda de mês em mês. **Não monte a conta
supondo a exceção.** Suponha 15% e comemore se sobrar.

### Processador de pagamento — 3,5% a 4,5% + ~R$ 0,40 por cobrança

Só entra se você vender **fora** das lojas (pelo site, para quem usa o agente no
Windows). Stripe, Mercado Pago e Pagar.me ficam todos nessa faixa. Numa cobrança
de R$ 30, algo entre R$ 1,45 e R$ 1,75.

Vender pelo site é mais barato que vender pela loja — 5% contra 15%. Vale
oferecer os dois, com a assinatura pelo site sendo a que você divulga.

### Revisão jurídica dos termos e da privacidade — R$ 1.000 a R$ 3.000, uma vez

Os textos existem em `deploy/site/termos.html` e `privacidade.html`, e a própria
página diz que são rascunho. Foram escritos por quem não é advogado.

Cobrar com termos não revisados é assumir um risco que não tem teto conhecido —
e as duas lojas exigem política de privacidade de verdade, com o que se coleta e
por quê. O Deskside vê a tela do computador da pessoa; isso não é um app de
lista de tarefas.

É o único item da lista em que eu não economizaria.

## De onde vem a mensalidade de cada cenário

Para conferir os totais lá de cima sem precisar refazer a soma:

```
R$  45  Apple, diluída no mês (US$ 99/ano)
R$  78  DAS do MEI
R$   3  domínio (R$ 40/ano)
R$   5  e-mail (SES)
R$   0  servidor (Oracle Always Free)
= R$ 131  cenário A

+ R$  55  Azure Trusted Signing      = R$ 186  cenário B
+ R$ 229  certificado EV, no lugar   = R$ 361  cenário C
```

O Google Play não aparece: são US$ 25 **uma vez só**, e diluir um pagamento
único numa mensalidade só serviria para o número parecer pior do que é.

## A ordem em que eu gastaria

1. **CNPJ (MEI)** — destrava o resto e é barato. R$ 78/mês.
2. **SMTP (SES)** — sem isto, ninguém além de você cria conta. Centavos.
3. **Apple Developer, US$ 99** — sem isto, o iOS não existe para outra pessoa.
4. **Play Console, US$ 25** — pagamento único, e com o CNPJ some a regra dos 12
   testadores.
5. **Revisão jurídica** — antes da primeira cobrança, não depois.
6. **Certificado de assinatura** — o aviso do Windows atrapalha, mas a página do
   site já explica o que vai acontecer. Dá para viver com ele por uns meses.
7. **Servidor pago** — quando o dinheiro entrar, e não antes.

Itens 1 a 4 somam cerca de **R$ 800 no primeiro mês** e colocam o produto no ar
para estranhos nas três plataformas.
