# O que o banco guarda, e o que dele vaza se alguém levar uma cópia

Segunda revisão de segurança, agora focada só no armazenamento — pedida depois
de a cobrança pelas lojas entrar. Setembro de 2026.

**O método é medir, não afirmar.** Não perguntei ao código o que ele guarda:
enchi um banco pelo fluxo real — cadastro em duas etapas, 2FA ligado,
recuperação de senha pedida, computador pareado, assinatura comprada — e depois
abri o arquivo `.db` como bytes crus e procurei cada segredo dentro dele. É a
única forma de a resposta não depender da intenção de quem escreveu.

O roteiro está em `scripts/` (ver "como repetir", no fim).

## A pergunta que motivou a revisão

*"Ninguém deve poder ver senhas, informações de cartões de crédito nem nada
disso."*

Respondendo as três, na ordem:

### Cartão de crédito: não existe no sistema

Não é que esteja bem guardado — **ele nunca chega aqui**. Quem cobra é a Apple
ou o Google; o Deskside recebe um identificador de transação e uma data de
validade. Não há número, bandeira, quatro últimos dígitos, titular, CVV nem
endereço de cobrança em nenhuma tabela, em nenhum log e em nenhum backup.

É a maior vantagem de segurança de vender pela loja, e é por isso que está
escrito dentro do `models.Assinatura`: se um dia alguém propuser guardar "só os
últimos quatro para facilitar o suporte", aquela linha responde não.

O mesmo valeria com Pix ou Mercado Pago — em nenhum dos caminhos que
consideramos o cartão passaria pelo nosso servidor.

### Senha: nunca esteve em texto puro. Confirmado por medida

Bcrypt, com sal por linha. Procurei a senha literal dentro do arquivo: ausente.

O cadastro em duas etapas também não abre janela — o `PendingSignup` já guarda
o hash, e não a senha, no intervalo entre preencher o formulário e digitar o
código.

### "Nada disso": aqui apareceu um defeito, e ele era o pior da lista

**O segredo do agente estava em texto puro.**

`Device.agent_secret` é a credencial que um computador apresenta ao servidor
para dizer "sou esta máquina". Ela estava guardada literalmente, na mesma tabela
e no mesmo arquivo que sai da VM todo dia na cópia de segurança.

É uma credencial **mais perigosa que a senha da conta**, e vale entender por
quê: com a senha, quem entra ainda esbarra no 2FA. Com o segredo do agente, a
pessoa *é* o computador — recebe as teclas que o dono digitar, vê a tela, abre
arquivos. Não há segunda etapa nenhuma nesse caminho.

A medida, antes do conserto:

```
segredo do agente emitido: wMnhEa35w6NR... (43 chars)
está em TEXTO PURO dentro do .db: True

senha guardada como: $2b$12$U8yS5qgnccTtdc6NY0fS7u ...  (bcrypt)
a senha em texto está no .db: False
```

Duas credenciais na mesma tabela, tratadas de formas opostas. **Corrigido** —
ver a seção seguinte.

## O conserto do segredo do agente

Agora o banco guarda o **resumo** (SHA-256), e a conferência é `resumo(o que o
agente apresentou) == o que está guardado`.

SHA-256 puro e não bcrypt de propósito: o segredo é sorteado pelo servidor com
32 bytes de entropia, então não há dicionário para tentar e nada que um custo de
trabalho torne mais difícil. Bcrypt aqui só custaria CPU a cada conexão de
agente — e são muitas.

**A janela que restou, e por que ela existe.** Quem pareia é o aplicativo, e o
agente pode estar desligado naquele instante. O segredo precisa esperar por ele
em algum lugar, e resumo não se reverte. Então ele espera em texto puro numa
coluna separada (`agent_secret_pendente`) e some **na primeira conexão em que o
agente prova que o recebeu**.

Não some no envio, e isso é deliberado: se a entrega falhar no meio, apagar ali
trocaria uma exposição de segundos por um computador trancado para fora da
própria conta, sem nada na tela explicando por quê.

Medido, antes e depois:

```
ANTES de o agente conectar (janela de entrega):
   segredo em texto puro no .db: True
DEPOIS da primeira conexão autenticada:
   segredo em texto puro no .db: False
```

**A conversão não tem parada nem passo manual.** As linhas antigas continuam com
texto puro na coluna definitiva; a conferência aceita os dois formatos, e cada
agente converte a própria linha na primeira vez que se identifica. Um agente que
nunca mais aparecer não tranca ninguém, e não há migração de uma vez só para dar
errado às duas da manhã.

Nove testes cobrem isso, incluindo o ataque óbvio contra hash mal usado —
apresentar como segredo o resumo que está no banco.

## O que a cobrança nova acrescentou, e como

A tabela `assinaturas` nasceu já com duas decisões tomadas por causa desta
revisão:

**O identificador da loja vai como resumo, não em texto.** Precisamos dele para
*casar* uma notificação com uma conta, e casar exige só comparar — nunca
reproduzir. O token de compra do Google é credencial de fato: quem o tem
consulta a assinatura na API do Play. Guardar o resumo custa o mesmo e não
entrega nada a quem ler uma cópia do banco.

**Um comprovante vale para uma conta.** `id_hash` é único. Sem isso, a fraude
mais barata que existe contra compra em loja seria assinar uma vez e passar o
comprovante para o grupo do WhatsApp.

E a linha entra na cascata de exclusão da conta, como todas as outras — pelo
motivo que já mordeu perfis e computadores pareados neste projeto: o SQLite
reaproveita identificador, e uma linha órfã com `user_id = 1` vira patrimônio da
próxima conta que nascer com aquele id. Aqui isso significaria alguém ganhando
plano pago que não comprou.

## O quadro completo, medido

| O que | Como está guardado | Está em texto no `.db`? |
|---|---|---|
| Senha da conta | bcrypt, sal por linha | **não** |
| Código de verificação do cadastro | hash | **não** |
| Código de recuperação de senha | hash | **não** |
| Segredo do 2FA (TOTP) | cifrado (Fernet, `cofre.py`) | **não** |
| Segredo do agente | SHA-256 | **não** (só na janela de entrega) |
| Identificador da compra na loja | SHA-256 | **não** |
| Dados de cartão | não existem | — |
| E-mail, telefone, nome, nascimento | texto | sim, **e é o esperado** |

Os três últimos da tabela são dado pessoal comum, não segredo: são o que a
pessoa digita para entrar e o que a nota de privacidade lista. Cifrá-los
impediria login e busca, e protegeria contra um cenário que a cifra do backup já
cobre.

## O que mais eu procurei, e não achei

- **SQL montado à mão com dado do usuário.** Duas ocorrências de f-string em
  SQL, as duas em `db.py`, as duas montadas com nomes de tabela e de coluna
  vindos do próprio esquema — nunca de uma requisição. Não é injetável hoje. É
  seguro pelo que alimenta a string, então vale a nota: se um dia alguém passar
  ali algo que veio de fora, deixa de ser.
- **Segredo em log.** Nenhum `logger` do backend registra senha, código, token
  ou comprovante. O que se registra é o que aconteceu, nunca com o quê.
- **Segredo em resposta da API.** Nenhum schema de saída expõe hash, segredo,
  chave de sessão ou identificador de loja.
- **Rota aberta por engano.** 54 operações exigem token; 11 são públicas, e as
  11 são as esperadas: cadastro, login, recuperação de senha, `/health` e o
  webhook das lojas.

## Uma coisa que consertei de passagem

O webhook das lojas é o **único** endereço do servidor que aceita `POST` de
qualquer pessoa, sem token, e lê o corpo inteiro na memória. Sem teto, um `POST`
de um gigabyte derruba a VM sem precisar de conta, de credencial e de nada — e a
VM tem 1 GB de RAM.

Agora recusa acima de 256 KB, conferindo **duas vezes**: pelo `Content-Length`,
para não ler à toa, e pelo tamanho real depois de ler, porque o cabeçalho pode
mentir ou faltar. Com teste.

## O que continua em aberto

Não é lista de defeitos — é o que uma revisão honesta precisa dizer que **não**
cobriu:

1. **Contra quem já está dentro da VM, nada disto protege.** Quem tem o `.env`
   tem as chaves; quem tem a máquina tem o banco aberto. O que estas medidas
   cobrem é o vazamento realista: a cópia de segurança, que sai daqui todo dia.
2. **A cifra do backup depende de `DESKSIDE_BACKUP_KEY` estar definida.** Sem
   ela, `backup.py` não cifra — de propósito, para não trancar quem já usava.
   **Confirme que está definida no `deploy/.env`.**
3. **`DESKSIDE_EXIGIR_SEGREDO_DO_AGENTE` continua falso.** Enquanto for, um
   agente antigo que não conheça o campo `secret` é aceito sem provar nada.
   Ligue depois que todos os agentes estiverem atualizados.
4. **O webhook não tem limite por IP.** Hoje é inofensivo (sem credencial de
   loja configurada, ele recusa tudo antes de tocar no banco), mas entra na
   lista para quando a Apple estiver ligada.
5. **A verificação de assinatura das notificações ainda não existe** — as duas
   implementações reais estão escritas como `NotImplementedError` até as contas
   de loja existirem. É a peça de segurança mais importante que falta, e o
   servidor falha **fechado** sem ela: sem credencial, nenhuma notificação é
   aceita e nenhuma compra vale como paga.

## Como repetir esta revisão

```
cd backend
python scripts/auditar-banco.py
```

Ele cria um banco de verdade, exercita cadastro, 2FA, recuperação de senha,
pareamento e compra, e depois abre o arquivo como bytes. Sai com código 1 se
algum segredo aparecer onde não devia.

Não é um teste automático de propósito: é coisa de se fazer **quando o modelo de
dados muda**, e não a cada `pytest`.

### A ferramenta também precisou ser testada por quebra

A primeira versão do roteiro deu **"ok" com o defeito posto de volta de
propósito** — o pior resultado possível para uma auditoria, porque é o que faz
alguém parar de olhar.

O motivo é instrutivo: ela media uma vez só, depois de o agente conectar. E é a
conexão do agente que dispara a conversão automática das linhas antigas. A
ferramenta dizia que estava tudo certo justamente porque o **conserto** estava
funcionando em cima do defeito, e apagando o rastro dele antes da medida.

Agora mede em dois momentos:

1. **pareado, antes de o agente conectar** — a coluna definitiva já tem de ser
   resumo, mesmo com a de espera em texto puro;
2. **depois da primeira conexão autenticada** — nada de texto puro no arquivo.

Com a correção, pôr o defeito de volta produz `<<< VAZOU` no momento 1.

Uma auditoria que só olha depois da faxina não audita nada — e a única forma de
descobrir isso é sujar de propósito e conferir se ela reclama.

### Quando repetir

**Sempre que uma tabela nova guardar qualquer coisa que sirva para provar
identidade.** Foi exatamente o que aconteceu agora: a tabela de assinaturas
entrou, e a revisão que ela motivou achou um defeito antigo em outro lugar.
