# Plano: versão 4.0 — automações, IA e outros sistemas

A 4.0 do documento do projeto tem três pedaços: **automações** (Etapa 17),
**integração com IA** (Etapa 18) e **suporte completo aos sistemas operacionais**.

Este documento decide a ordem, a arquitetura e o que fica de fora. O estado geral
do projeto e os cortes já feitos estão em
[`estado-do-projeto.md`](estado-do-projeto.md).

## A decisão que organiza tudo

**A saída da IA é uma automação.**

Sem isso, os dois recursos seriam sistemas paralelos: um jeito de guardar uma
sequência de ações, e outro jeito de a IA executar ações. Dois formatos, duas
validações, dois lugares para um comando dar errado.

Com isso, viram um só. A automação é o **formato**; a pessoa é um produtor dele
(pelo editor) e a IA é o outro (traduzindo uma frase). Tudo o que for construído
para executar, validar, limitar e confirmar uma automação serve aos dois — e a
IA nasce sem poder nenhum que o editor já não tenha.

É também o que mantém a IA segura por construção: ela **escolhe de um cardápio
fechado**, não inventa comandos. Não há caminho pelo qual ela produza algo que um
usuário não pudesse ter montado à mão.

Consequência prática: **automações primeiro**. A IA sem elas seria construir o
formato duas vezes.

## Fase 1 — Automações

Um botão que faz várias coisas. O exemplo do documento é o "Modo Trabalho": abrir
Outlook, Teams, navegador e Spotify.

### O que é um passo

Cada passo é **uma ação que o agente já sabe fazer**. Nada novo do lado dele:

`launch_app` · `close_app` · `input` (tecla, texto, atalho) · `media` ·
`brightness` · `power` · `keep_awake` · escolher monitor · escrever na área de
transferência.

Isso não é economia de esforço, é limite de projeto: o conjunto de coisas que uma
automação pode fazer é exatamente o conjunto que a pessoa já podia fazer com os
dedos. Nenhum poder novo entra pela porta da automação.

### Onde fica guardada: no servidor

Mesmo raciocínio dos perfis, e as duas razões continuam valendo:

- a conta é usada em mais de um aparelho — automação criada no iPhone tem de
  aparecer no iPad;
- o app instalado por sideload é reinstalado a cada sete dias, e o que estivesse
  só no aparelho iria embora junto.

### Onde é executada: no agente

Esta é a decisão menos óbvia, e a que mais importa.

O caminho fácil seria o app disparar os endpoints em sequência. Três problemas,
e o terceiro decide:

1. **Custo.** Uma automação de seis passos seriam seis idas e voltas
   `celular → VPS → agente`.
2. **Espera.** Um programa leva tempo para abrir antes de aceitar teclas. Quem
   espera teria de ser o telefone, contando o tempo do outro lado do mundo.
3. **O iOS suspende aplicativos.** Se a pessoa aperta o botão e bloqueia a tela,
   o app para no meio — e a automação fica pela metade, com o Outlook aberto e o
   resto não. Um "Modo Trabalho" que às vezes faz metade do trabalho é pior que
   não ter.

Então o backend manda **uma** mensagem com a lista de passos, e o agente executa
em ordem. Sobrevive ao telefone sair da frente, gasta uma ida e volta, e a espera
entre passos acontece onde ela faz sentido.

### As regras de execução

- **Espera por passo, opcional.** Abrir um programa e mandar `Ctrl+N` no mesmo
  instante não funciona: o programa ainda não existe para receber a tecla.
- **Falha não interrompe.** Se o Teams não está instalado, os outros três ainda
  devem abrir. Mas o resultado de **cada** passo volta ao app — falhar em
  silêncio é o que este projeto já corrigiu meia dúzia de vezes.
- **Teto de passos e de duração total.** A lista chega pela rede; ela não pode
  prender o agente para sempre nem virar um laço de mil aberturas de programa.
- **Passos destrutivos confirmam antes.** Desligar e fechar programa entram na
  automação, mas com aviso no app antes de rodar — ver a Fase 2, onde isso deixa
  de ser cuidado e vira requisito.

### Onde aparece no app

Tela própria: lista de automações e editor. **Não** dentro do editor de perfis —
um perfil é um punhado de atalhos que a pessoa escolhe um a um; uma automação é
um botão que faz uma sequência. Misturar os dois no mesmo editor obrigaria a
explicar a diferença antes de o recurso servir para alguma coisa.

Ligar uma automação a um botão da barra de perfis é natural e fica para depois de
o recurso existir sozinho.

### Como fica verificado

Aqui não há Flutter nem Windows, então a verificação se concentra onde ela é
possível e vale mais:

- **Agente:** a execução da lista é lógica portável — ordem, espera, falha que
  não interrompe, teto de passos, relatório por passo. Tudo testável no Linux.
- **Backend:** modelo, validação (passo desconhecido é recusado antes de chegar
  ao computador), posse (automação de outra conta é 404) e o repasse.
- **App:** editor e lista, sem compilar aqui — o que dá para testar é o modelo.

## Fase 2 — Integração com IA

"Abra o Photoshop e coloque uma música." O sistema interpreta, converte em passos
e executa.

### O modelo roda na nuvem, e a chamada sai do backend

**Na nuvem** porque um modelo capaz disto não roda num telefone.

**Do backend, e não do app**, por três razões:

1. A chave da API não pode viajar dentro de um `.ipa` — de um aplicativo
   instalado por sideload ela sai em minutos.
2. Custo e limite por conta precisam de um ponto central. Cada frase custa
   dinheiro, e sem cobrança montada isso é despesa aberta por usuário.
3. Trocar de modelo passa a não exigir uma versão nova do app.

### A IA escolhe de um cardápio fechado

Ela recebe: a frase, a lista de programas instalados naquele computador e a lista
de ações possíveis. Devolve: uma automação — os mesmos passos da Fase 1, nada
além.

Isso não é conservadorismo. É a diferença entre um recurso e um risco: um modelo
que pudesse emitir comando livre teria, na prática, acesso de terminal ao
computador de outra pessoa. O **terminal remoto** (Etapa 13) está fora da 4.0 de
propósito, e essa separação tem que continuar de pé.

### A pessoa vê o plano antes de ele rodar

O app mostra os passos que a IA propôs e pede confirmação. Sempre, não só nos
casos perigosos.

Dois motivos. O óbvio: um modelo entende errado, e o erro aqui acontece no
computador de alguém. O menos óbvio: **ver o plano ensina o produto**. Quem lê
"abrir Spotify → esperar 2s → tocar" entende o que a ferramenta faz e começa a
montar as próprias automações. O caminho da IA vira a porta de entrada do editor,
em vez de um concorrente dele.

Passos destrutivos (desligar, reiniciar, fechar programa) confirmam de novo,
destacados.

### Privacidade

O que sai do computador na hora da consulta: o **nome dos programas instalados** e
o nome da máquina. Nada mais — nunca o conteúdo da tela, nunca a área de
transferência, nunca arquivo.

Isso é opt-in explícito, com o texto dizendo o que vai. A área de transferência
já estabeleceu o padrão neste projeto: sincronia automática nasce desligada
porque o que passa por ali costuma incluir senha, e o interruptor diz isso com
todas as letras em vez de esconder atrás de "sincronizar".

### Quando ela não souber, ela diz

Frase que não mapeia para as ações conhecidas devolve "não sei fazer isso" com o
que ela entendeu — não um palpite executado. Um chute silencioso no computador de
alguém é o pior desfecho possível deste recurso.

## Fase 3 — Suporte completo aos sistemas operacionais

O agente compila em Linux e macOS hoje, e a lógica portável é testada nos três.
O que falta é a camada de plataforma inteira: captura, injeção de entrada,
aplicativos, área de transferência, arquivos, energia e "manter pronto" — hoje
todos *stub* fora do Windows.

É o maior dos três pedaços e o menos verificável daqui. Três realidades
diferentes:

### Linux — viável, com uma ressalva grande

X11 tem caminho conhecido para tudo. **Wayland não**: a captura de tela exige
PipeWire e o portal do ambiente gráfico, com **consentimento do usuário por
sessão**. Isso briga de frente com a premissa do produto — um agente que sobe
sozinho e fica disponível não pode depender de alguém clicar "permitir" a cada
reinício.

Não é impossível, é uma decisão de produto: em Wayland, ou o recurso pede
permissão uma vez por sessão e avisa, ou a captura fica de fora e sobra o resto
(entrada, arquivos, energia, monitoramento).

Dá para testar aqui, numa máquina virtual com sessão gráfica. É por onde começar.

### macOS — depende de hardware que o projeto não tem

Precisa de duas permissões que o usuário concede uma a uma (Acessibilidade e
Gravação de Tela) e de notarização para distribuir fora da App Store. E não há
Mac no projeto — o Codemagic compila, mas compilar não é testar.

Só faz sentido atacar com uma máquina emprestada ou comprada. Antes disso,
qualquer entrega seria fé.

### ChromeOS — rever se entra

Um agente em ChromeOS roda dentro do contêiner Linux (Crostini), que **não
controla a área de trabalho do ChromeOS** — só o próprio contêiner. Entregar isso
como "suporte a ChromeOS" seria prometer o que o nome sugere e entregar outra
coisa.

Recomendação: tirar do escopo, ou redefinir explicitamente como "o contêiner
Linux", que é o que de fato dá para fazer.

## A ordem, e por quê

1. **Automações.** Fundação da IA, reaproveita tudo o que existe, e é a parte
   inteiramente verificável daqui.
2. **IA.** Depende do formato da Fase 1 e de decisões de custo e privacidade que
   ficam melhores com o editor já no ar.
3. **Sistemas operacionais.** Maior, mais incerto, e o único que depende de
   comprar ou emprestar hardware.

## O que não está aqui, e continua na frente

A 4.0 é sobre o produto. O que separa o Deskside de poder ser **vendido** está em
[`estado-do-projeto.md`](estado-do-projeto.md) e não mudou: backup do banco,
limite de tentativas no login, App Store, cobrança, termos de uso.

O backup em particular é o único item de qualquer lista que pode custar tudo de
uma vez, e leva meia hora.
