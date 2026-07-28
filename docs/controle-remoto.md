# Controle remoto — mouse e teclado (Etapa 6)

O app envia ações de mouse e teclado que o agente injeta no computador
pareado. É a primeira feature que toca a **camada de plataforma** do agente
(injeção de entrada no SO).

## Onde funciona de verdade

A injeção de entrada é específica do sistema operacional. Nesta etapa:

- **Windows** — implementação real via crate `enigo` (o cursor se move,
  clica e rola de verdade). É a plataforma disponível para teste no projeto.
- **Linux / macOS** — *stub* que apenas registra a ação (`[mouse-stub] ...`).
  Permite desenvolver e testar todo o caminho app → backend → agente sem
  sessão gráfica; a implementação real entra numa fase posterior.

A dependência `enigo` é declarada apenas para Windows
(`[target.'cfg(windows)'.dependencies]` em `agent/Cargo.toml`), então os
builds de Linux/macOS não a compilam. Ver a estratégia por plataforma em
[`estrategia-de-testes.md`](estrategia-de-testes.md).

## Caminho do comando

```
App (usuário logado)                Backend                     Agente
  │  POST /devices/{id}/input ────►  valida posse + online
  │      {kind, ...}                 ├─ relay via WebSocket ───►  injeta no SO
  │  ◄──────────── 204 / 503 ─────   (503 se o agente offline)
```

Nesta etapa o comando vai por **HTTP** (um por requisição) — simples de testar
e suficiente para cliques e ajustes. O **streaming contínuo** do touchpad
(muitos eventos por segundo) usará um canal WebSocket dedicado do app, a ser
adicionado junto com o cliente Flutter.

## Endpoint

`POST /api/v1/devices/{device_id}/input` (autenticado). Corpo = uma ação:

| kind | Campos | Efeito |
|---|---|---|
| `mouse_move` | `dx`, `dy` (relativos) | Move o cursor |
| `mouse_click` | `button` (`left`/`right`/`middle`) | Clica |
| `mouse_scroll` | `dy` (+ = para cima) | Rola verticalmente |
| `key_text` | `text` | Digita o texto |
| `key_press` | `key` (tecla especial) | Pressiona Enter, setas, F1–F12, etc. |
| `key_combo` | `modifiers` (`ctrl`/`alt`/`shift`/`meta`), `key` | Atalho (ex.: Ctrl+C, Alt+F4) |

Teclas especiais aceitas em `key_press`: `enter`, `backspace`, `tab`,
`escape`, `space`, `delete`, `up`, `down`, `left`, `right`, `home`, `end`,
`page_up`, `page_down`, `f1`–`f12`. Em `key_combo`, `key` é um caractere
(ex.: `"c"`) ou um nome de tecla (`enter`, `tab`, `escape`, `delete`,
`space`, `f1`–`f4`).

Respostas: `204` enviado; `404` dispositivo não é da conta; `503` agente
offline; `422` ação inválida.

## Verificação manual

Com backend + agente rodando e o dispositivo pareado (ver
[`pareamento.md`](pareamento.md)), pegue um access token e envie:

```bash
curl -X POST http://localhost:8000/api/v1/devices/<device_id>/input \
  -H "Authorization: Bearer <access_token>" \
  -H "Content-Type: application/json" \
  -d '{"kind":"mouse_move","dx":50,"dy":0}'
```

No Windows o cursor se move; no Linux/macOS o agente imprime
`[input-stub] MouseMove { dx: 50, dy: 0 }`.

Para teclado, abra um editor de texto no computador e envie:

```bash
curl -X POST http://localhost:8000/api/v1/devices/<device_id>/input \
  -H "Authorization: Bearer <access_token>" -H "Content-Type: application/json" \
  -d '{"kind":"key_text","text":"Olá do meu celular!"}'
```

## Barra de sugestões

Acima do teclado aparecem até três palavras. Ela **nunca corrige sozinha**:
tocar numa palavra é a única coisa que muda o texto.

Essa recusa é deliberada. O teclado digita direto no computador, e os usos mais
comuns são terminal, caminho de arquivo e senha — lugares onde "quase certo" é
simplesmente errado, e onde uma correção automática causaria mais estrago do que
o erro de digitação que ela tentava consertar. A barra também não sugere nada
sobre número, símbolo ou algo com `\` e `:`, justamente por isso.

De onde vêm as palavras:

1. **O que você já digitou** — é a fonte que sabe os seus nomes próprios, os
   seus comandos e o seu jargão, que dicionário nenhum traz. Fica só no celular.
2. **Uma lista curta de palavras comuns** do idioma da interface, para o
   primeiro dia valer alguma coisa. Chinês não recebe lista: a escrita não
   funciona por palavras separadas, e barra vazia é mais honesto que palpite
   ruim.

Digitar sem acento acha a palavra acentuada (`voce` → `você`), e a maiúscula de
quem digitou é mantida (`Proj` → `Projeto`).

Dá para desligar em **Configurações → Qualidade da tela → Sugestões de
palavra**. Se a digitação parecer pesada, esse interruptor é o teste: com ele
desligado, o custo das sugestões sai do caminho e sobra só a rede.

O índice de palavras é montado **uma vez**, não a cada tecla, e a busca por
semelhança (a parte cara) só roda quando as completações não bastam. A primeira
versão remontava o dicionário inteiro a cada letra digitada — com milhares de
palavras, isso se sente no dedo.

### Por que a troca é uma ação só

Trocar a palavra significa apagar o que foi digitado e escrever o certo. Isso
vai numa única ação `key_replace` (com `backspaces` e `text`), e não em várias
mensagens.

O motivo é o canal de dados do WebRTC, que é **não ordenado de propósito** — o
que é bom para o mouse, onde o movimento mais novo vale mais que o antigo. Em
mensagens separadas, o texto novo poderia chegar antes dos backspaces e o
resultado sairia embaralhado. Como ação única, ou chega inteira ou não chega.

O app só rastreia a palavra enquanto ela faz sentido: mover o cursor (um toque
na tela, uma seta, Enter) zera o rastro, porque a partir dali o que o app acha
que está sendo digitado não corresponde mais ao que existe na tela do
computador.

## Realce da tecla

Enquanto o dedo está numa tecla, um balão com o que ela faz aparece acima dela.
É o mesmo motivo do teclado do iPhone: o dedo cobre justamente a tecla que
acabou de ser tocada, e sem o balão não há como confirmar o que foi digitado
sem olhar para a tela do computador.

Vale para **todas** as teclas, não só as letras — numa tela pequena, a de Esc
ou a de seta somem debaixo do dedo tanto quanto a de letra. O balão mostra o
próprio rótulo da tecla, ampliado: quem tem ícone aparece como ícone.

Nas teclas das pontas o balão encosta na borda em vez de sair da tela.

## Selecionar texto

Três caminhos, porque não existe um só que sirva sempre:

**Duplo toque** seleciona a palavra. Sem tirar o dedo do segundo toque,
**arraste** e a seleção cresce - como no celular. Funciona em qualquer lugar,
inclusive onde não dá para digitar: página da web, PDF, mensagem de erro.

**Shift + setas** (no teclado do app) seleciona caractere a caractere, e
Shift + Home/End até o fim da linha. Só onde há cursor de texto.

**Ctrl+A** seleciona tudo.

### Por que o duplo toque não é um "duplo clique" mandado duas vezes

O primeiro toque já manda o seu clique, como qualquer toque. O segundo manda
`mouse_press` - que **aperta e segura, sem clicar antes**. O computador vê
clique + aperto dentro do intervalo de duplo clique, e é isso que faz dele um
duplo clique de verdade, com o botão ainda em baixo para o arrasto estender a
seleção.

A ação carrega um campo `clicks` para quando for preciso emendar cliques do
lado do agente (`clicks: 3` seleciona o parágrafo), mas o gesto do duplo toque
usa `clicks: 1`. Usar 2 ali foi o primeiro erro desta implementação: somado ao
clique do primeiro toque davam **três**, e três cliques no Windows selecionam o
parágrafo inteiro - foi exatamente o que apareceu no teste.

Enquanto a seleção está em curso, o toque longo **não** vira clique direito.
Segurar depois do duplo toque é o começo do arrasto: o dedo fica parado antes
de andar, e o menu de contexto abriria bem no meio disso.

### O botão preso

O pior defeito possível aqui é a conexão cair no meio de uma seleção e o
computador ficar com o botão do mouse apertado, arrastando tudo o que o cursor
tocar. Por isso o injetor de entrada guarda quais botões estão apertados e os
solta no `Drop` - que roda quando a conexão morre, por qualquer caminho, sem
depender de o app conseguir mandar o `mouse_release`.

## Barra de perfis

A segunda barra flutuante do app. A dock escolhe **qual programa abrir**; a
barra de perfis escolhe **qual conjunto de atalhos fica a mão**.

Ela tem duas pistas. A primeira e a seletora: cinco perfis (Sistema, Video,
Navegador, Trabalho, Apresentacao). A segunda so existe enquanto ha um perfil
aceso, e traz os botoes dele. Tocar de novo no perfil aceso fecha a segunda
pista, e a barra volta a ser fininha - que e o estado normal, porque o que a
pessoa veio ver e a tela do computador.

Fica na borda **oposta a da dock**: esquerda com o celular deitado, topo com
ele em pe. As duas flutuam, e disputar a mesma borda faria uma cobrir a outra.
Arrasta-se pela alca, como a dock, e o botao de ajuste na barra de cima
esconde a barra inteira.

O perfil escolhido vai para o disco (`profileId`) e volta na proxima sessao.

### Tres formas de tecla, e o que acontece se escolher a errada

Um botao de perfil manda uma de tres mensagens, e o `ProfileAction` obriga a
dizer qual no construtor:

| Construtor | Mensagem | Para que |
| --- | --- | --- |
| `.combo` | `key_combo` | `Ctrl+S`, `Alt+Tab`, `Win+E` |
| `.special` | `key_press` | teclas com nome proprio: Esc, F5, setas, Espaco |
| `.letter` | `key_text` | uma letra solta: o `f` de tela cheia, o `m` de mudo |

A separacao existe porque errar aqui falha **calado**: `key_press` so aceita
nomes da tabela (`agent/src/input.rs`), e mandar `{"key": "f"}` seria recusado
sem nada aparecer na tela. Um teste percorre todos os perfis e confere cada
tecla contra a mesma tabela - e por isso que um perfil novo com um nome
inventado quebra no `flutter test`, e nao no bolso do usuario.

### O icone do perfil e o icone do programa

Quando o programa da frente e um dos que o perfil atende, o botao passa a
mostrar o **icone real dele**: PowerPoint no perfil de apresentacao, Apple
Music no de midia. E o mesmo icone que a dock usa, extraido pelo mesmo trecho
de PowerShell (`ICON_HELPER`, em `agent/src/apps.rs`) - duas copias acabariam
divergindo, e o mesmo programa apareceria com dois desenhos diferentes na
mesma tela.

O caminho: o app pergunta `GET /devices/{id}/foreground` de 3 em 3 segundos
enquanto a barra esta visivel; o agente responde com nome, executavel e icone.
A comparacao e pelo **executavel** (`powerpnt.exe`), nunca pelo nome legivel,
que muda com o idioma do Windows.

Tres economias, porque isso roda o tempo todo:

1. O agente so pergunta ao sistema quem esta na frente quando o **PID** muda.
2. O icone e extraido uma vez por programa e fica guardado por nome.
3. O app guarda o icone **por perfil**, e nao o retrato do momento: sair do
   Apple Music para o navegador nao apaga o icone do perfil de midia - e ele
   que continua sendo controlado.

Se o computador nao responder (agente antigo, sem rede), o app desliga a
consulta e fica com os icones desenhados. Sem erro na tela: nao e uma falha
que impeca controlar o computador.

### Por que os perfis vem prontos e nao sao editaveis (ainda)

O valor esta em ter algo util no primeiro toque. Um editor de atalhos e uma
tela a mais para atravessar antes de o recurso servir para alguma coisa, e a
lista pronta ja cobre o que se faz num computador pelo celular: assistir,
navegar, escrever, apresentar.
