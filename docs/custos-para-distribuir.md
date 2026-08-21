# Quanto custa colocar o Deskside na rua

Tudo que precisa ser pago para o produto sair de "funciona na minha casa" e
virar algo que um estranho instala, usa e paga.

**Duas ressalvas antes dos números.** Os preços são do que eu conhecia até maio
de 2026 e mudam — confirme cada um antes de gastar. E o câmbio usado é
**US$ 1 = R$ 5,50**; se estiver diferente, os valores em real mudam junto.

## O resumo, para quem quer o número

| | Uma vez | Por mês |
|---|---|---|
| **Mínimo para cobrar** | ~R$ 140 | ~R$ 130 |
| **Com os avisos do Windows resolvidos** | ~R$ 140 | ~R$ 185 a R$ 320 |
| **Mais a revisão jurídica** | ~R$ 1.140 a R$ 3.140 | igual |

E o custo que não aparece em nenhuma tabela de assinatura: **15% de cada
mensalidade vai para a Apple ou para o Google.** Isso é maior que todo o resto
somado, assim que houver clientes.

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

### Servidor — R$ 0, com um risco que vale dizer

A VM da Oracle Cloud é do nível gratuito permanente, e aguenta o que temos.

O risco é de política, não de técnica: o nível gratuito da Oracle pode
**reivindicar instâncias ociosas**, e "ocioso" é definido por eles. Para um
projeto de estudo, tudo bem. Para um produto pago, um dia de fora é um dia de
reembolso e de gente cancelando.

Trocar por um servidor pago quando começar a entrar dinheiro custa entre
**US$ 5 e US$ 7 por mês** (~R$ 30 a R$ 40) num Hetzner ou DigitalOcean. Não é
para agora; é para quando o primeiro cliente pagar.

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

## A conta de quando isso se paga

Numa assinatura de R$ 30 vendida pela loja:

```
R$ 30,00  mensalidade
- R$ 4,50  15% da loja
= R$ 25,50 líquido por assinante
```

Custo fixo mensal, no cenário do meio (Apple + MEI + Azure Trusted Signing +
domínio + e-mail):

```
R$  45  Apple, diluída no mês
R$  78  MEI
R$  55  assinatura do certificado
R$   3  domínio
R$   5  e-mail
= R$ 186 por mês
```

**Ponto de equilíbrio: 8 assinantes.** Com certificado EV em vez do Azure, sobe
para 13. Vendendo pelo site em vez da loja, cai para 7.

Oito pessoas pagando cobrem a operação inteira. Isso é uma barreira baixa — e é
a notícia boa desta página.

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
