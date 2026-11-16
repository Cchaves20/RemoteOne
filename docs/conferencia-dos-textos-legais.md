# Os termos e a privacidade descrevem o software de verdade?

**Isto não é uma revisão jurídica.** Não sou advogado, e não avalio se os textos
são suficientes perante a LGPD, o Código de Defesa do Consumidor ou as regras
das lojas de aplicativos. Essa parte continua pendente e é a que bloqueia
cobrar.

O que esta conferência faz é a metade que um advogado **não tem como fazer**:
comparar cada afirmação dos textos com o código que está no ar. Um advogado não
vai ler o `main.py`; se o documento disser algo que o Deskside não faz — ou
omitir algo que ele faz —, ele validará um texto errado com muita competência, e
o erro sai carimbado.

Feita em agosto de 2026, contra `deploy/site/termos.html` e
`deploy/site/privacidade.html`.

---

## Os erros de fato (corrigidos)

### L1 — "Não temos como controlar uma máquina sua"

**Corrigido.** Era falso como estava escrito, e era a frase mais perigosa dos
dois documentos.

A `revisao-de-seguranca.md` estabeleceu o contrário, e em letras maiores: o
Deskside é, por desenho, execução remota de código no computador do cliente.
Quem controla o backend manda teclas, cliques, abre e fecha programas e lê
arquivos em **todos** os computadores pareados. Não é um defeito — é como o
produto funciona.

"Não acessamos" é uma promessa de conduta, e é verdadeira: não fazemos isso.
"Não temos como" é uma afirmação de impossibilidade técnica, e não é verdadeira.
A diferença entre as duas, num documento que alguém assina, é a diferença entre
um compromisso e uma declaração falsa.

**Texto que entrou no lugar:**

> Não acessamos os seus computadores. Tecnicamente, um servidor do Deskside
> conseguiria enviar comandos a um agente pareado — é assim que o seu próprio
> celular funciona —, e por isso o compromisso aqui é de conduta e de operação:
> o acesso ao servidor é restrito, protegido por chave e verificação em duas
> etapas, e qualquer acesso a um computador de cliente sem o pedido dele é
> violação destes termos por nós mesmos.

Isso é mais honesto **e** vende melhor: descreve uma postura, em vez de uma
impossibilidade que qualquer pessoa técnica desmonta em trinta segundos.

### L2 — "Cópias de segurança mantidas por até 30 dias"

**Corrigido.** O número estava errado e faltava a metade que sai da VM.

O código guarda **catorze** cópias diárias (`backup.MANTER_POR_PADRAO = 14`), não
trinta dias. E o `scripts/atualizar.cmd -Backup` traz cópias para o computador de
quem administra, onde **não há descarte nenhum** — elas ficam para sempre, numa
pasta pessoal, hoje cifradas (`DESKSIDE_BACKUP_KEY`) mas sem prazo.

Prometer trinta e guardar catorze é errar para o lado bom. Não dizer que uma
cópia sai da infraestrutura é a omissão que importa.

**Texto que entrou:** "Cópias de segurança do banco são mantidas por catorze dias na
infraestrutura e depois descartadas. Uma cópia cifrada pode ser guardada fora
dela, para o caso de o servidor ser perdido por inteiro."

### L3 — "A imagem da sua tela não é gravada... é descartada"

**Corrigido.** Era quase verdade, e a diferença cabia numa frase.

Quando a tela vai pelo caminho antigo (JPEG, sem WebRTC), o servidor guarda **o
último quadro em memória**, por dispositivo (`app/screen.py`, `FrameStore`). Ele
existe para o app mostrar alguma coisa no instante em que abre, em vez de uma
tela preta, e é apagado quando o agente desconecta. Nunca vai a disco.

Não é gravação, mas "é descartada" sugere que nada fica, nem por um segundo.

**Texto que entrou:** "...é descartada. O servidor mantém no máximo o último quadro em
memória, para a tela aparecer imediatamente quando você abre o aplicativo; ele
some quando o computador se desconecta e nunca é gravado em disco."

---

## O que faltava

### L4 — Os textos não sabem que existe um plano pago

**Corrigido** — em rascunho, para o advogado corrigir em vez de escrever do zero.
Era a omissão maior, e a mais recente. Os termos foram escritos quando tudo era
grátis. Hoje há plano grátis, plano pago de R$ 30/mês e trinta dias iniciais com
tudo liberado — e **nenhum dos dois documentos menciona qualquer coisa disso**.

Os termos ganharam uma seção 4 inteira: o que custa, o que a versão grátis
inclui, que os trinta dias iniciais acabam e a conta **cai para o grátis sem
perder nada**, como se assina hoje (à mão, por e-mail), cancelamento, reembolso
e aviso de mudança de preço. O trecho de reembolso cita o art. 49 do Código de
Defesa do Consumidor porque é o que se aplica; **conferir se está bem aplicado é
com o advogado** — o que eu garanti foi que ele saiba que existe assinatura.

A privacidade ganhou os campos novos da conta: o plano, até quando vale, e a
marca de que o aviso de fim de teste foi enviado.

### L5 — Dados guardados que a lista não cita

**Corrigido.**

A seção 1 da privacidade lista o que se guarda dos computadores, e desde então
apareceram dois — agora citados:

- **O segredo do aparelho** (`Device.agent_secret`), a credencial que o agente
  apresenta ao servidor.
- **O segredo do 2FA** (`User.totp_secret`), cifrado em repouso desde a revisão
  de segurança.

Nenhum é dado pessoal no sentido comum, mas a lista se apresenta como completa —
e uma lista que se diz completa e não é vale menos que uma lista que se diz
parcial.

### L6 — SMS aparece como se existisse

**Corrigido:** a página diz agora que só o e-mail recebe códigos.

"Provedor de e-mail e SMS" (seção 4) e "e-mail ou telefone... para receber os
códigos" (seção 1). O SMS **não está contratado**: hoje o cadastro por telefone
não recebe código nenhum. É promessa de um caminho que não funciona.

Ou contrate, ou tire o telefone do cadastro, ou diga que o envio por SMS ainda
não está disponível.

### L7 — Para o advogado, não para mim

Coisas que eu identifico como ausentes mas **não sei** se são obrigatórias no seu
caso. Levar a lista pronta encurta a conversa e a conta:

- **Base legal** de cada tratamento (execução de contrato, legítimo interesse,
  consentimento). A LGPD pede; o texto não menciona nenhuma.
- **Transferência internacional**: o provedor de e-mail (Resend) e a hospedagem
  (Oracle) podem estar fora do Brasil. A LGPD trata disso em capítulo próprio.
- **Encarregado (DPO)**: a seção 7 dá um e-mail, sem nomear pessoa. Pode bastar
  para porte pequeno — é ele quem sabe.
- **A cláusula de não responsabilidade** dos termos, hoje na seção 5. Diante de
  consumidor, exclusões amplas de responsabilidade costumam ser afastadas. A
  frase pode continuar existindo e não valer nada; ele dirá o que se salva.
- **Foro, lei aplicável e prazo de vigência** — nenhum dos dois textos tem.
- **Idade mínima de 13 anos**: bate com o código (`settings.idade_minima`), mas
  quem trata dados de adolescente entre 13 e 18 tem regra própria na LGPD.

---

## O que conferi e está certo

Vale registrar, porque o advogado pode parar de duvidar destes:

- **O pareamento exige o código exibido na máquina.** Confere: nove caracteres
  sorteados no servidor, dez minutos de validade, e sem eles não há vínculo.
- **Trocar a senha encerra as sessões em outros aparelhos.** Confere, e agora
  derruba também uma sessão de tela **já aberta**, em até trinta segundos.
- **A senha é guardada só como hash bcrypt.** Confere.
- **Excluir a conta apaga computadores, perfis e automações.** Confere: as
  relações têm `cascade="all, delete-orphan"`, e a exclusão exige a senha.
- **A área de transferência vem desligada.** Confere.
- **A conexão é direta quando a rede permite; senão passa por um relay que só
  repassa.** Confere — e o texto podia ser mais forte: o WebRTC cifra ponta a
  ponta (DTLS-SRTP), então o relay **não consegue** ler o que repassa. É uma das
  poucas impossibilidades técnicas reais que estes documentos podem alegar — e
  agora alegam, no lugar da que era falsa.
- **Idade mínima de 13 anos.** Confere com o código.
- **Não vendemos dados, não há rastreador de publicidade.** Confere: não há
  nenhuma dependência de análise ou publicidade no app.

---

## O que fazer com isto

L1 a L6 **já foram corrigidos** nas duas páginas: os erros de fato saíram, a
lista de dados guardados ficou completa, e os termos ganharam a seção de planos
e pagamento — em rascunho, porque é mais barato o advogado corrigir um rascunho
do que escrever do zero.

O que sobra:

1. Levar L7 como lista de perguntas. Chegar com as perguntas prontas costuma ser
   a diferença entre uma consulta e um projeto.
2. Contratar a revisão jurídica de verdade. **Nada acima substitui isso** — o
   que foi feito aqui garante que o advogado leia uma descrição verdadeira, não
   que ela seja suficiente.
3. Repetir esta conferência **sempre que o produto ganhar um recurso que toque
   dado ou dinheiro**. Foi exatamente o que aconteceu com os planos: o texto
   envelheceu em duas semanas sem ninguém mexer nele.
