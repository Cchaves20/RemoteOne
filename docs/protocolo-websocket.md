# Protocolo WebSocket — agente ↔ backend

Canal entre o agente desktop (Rust) e o backend (FastAPI), base da Etapa 4
do projeto. O agente conecta em `ws://<backend>/ws/agent`.

O formato de fio é JSON com um campo discriminador `type`. As duas
implementações precisam ficar em sincronia:

- Backend: [`backend/app/protocol.py`](../backend/app/protocol.py)
- Agente: [`agent/src/protocol.rs`](../agent/src/protocol.rs)

Cada lado tem testes que fixam esse formato; ao alterar uma mensagem,
atualize os dois.

## Fluxo

```
Agente                          Backend
  |  ── hello ──────────────────►  registra o agente como online
  |  ◄──────────────── welcome ─   confirma (envia versão do servidor)
  |                                
  |  ── heartbeat ──────────────►  atualiza last_seen
  |  ◄──────────────────── ack ─   confirma
  |            (a cada 10s)         
  |                                
  |  (desconexão)                   remove o agente do registro
```

## Mensagens do agente → backend

| type | Campos | Quando |
|---|---|---|
| `hello` | `device_id`, `hostname`, `os`, `agent_version`, `mac?` | Primeira mensagem ao conectar (`mac` opcional, para Wake-on-LAN) |
| `heartbeat` | — | Periódico, mantém a sessão viva |
| `app_list` | `request_id`, `apps[]` (`id`, `name`, `icon?`) | Resposta a um `list_apps`; `icon` é o ícone real do programa em PNG base64 (ver "pergunta e resposta" abaixo) |
| `file_list` | `request_id`, `listing?` (`path`, `parent?`, `entries[]`), `error?` | Resposta a um `list_files`. Vem `listing` **ou** `error` — pasta sem permissão não pode chegar ao app como pasta vazia |
| `file_chunk` | `transfer_id`, `seq`, `data` (base64) | Um pedaço de arquivo indo ao celular; `seq` detecta pedaço fora de ordem |
| `file_done` | `transfer_id`, `ok`, `detail?`, `size?` | Fim de transferência nos dois sentidos: `detail` traz o caminho salvo ou o motivo da falha |
| `automation_result` | `request_id`, `results[]` (`index`, `ok`, `error?`) | Resposta a um `run_automation`: uma só, no fim da sequência inteira. Identificado por **índice** e não por nome — dois passos podem ser idênticos. O `error` também vem com `ok` verdadeiro, quando o passo aconteceu com ressalva (a janela abriu mas não foi para o lugar pedido) |
| `system_stats` | `request_id`, `stats` (`cpu_percent`, `memory_used`, `memory_total`, `disk_used`, `disk_total`, `disk_name`, `uptime_seconds`) | Resposta a um `system_info`. Bytes crus e porcentagem: quem formata é o app, que sabe o idioma |

## Mensagens do backend → agente

| type | Campos | Quando |
|---|---|---|
| `welcome` | `server_version` | Resposta ao `hello` |
| `ack` | — | Resposta ao `heartbeat` |
| `error` | `message` | Mensagem inválida ou fora de ordem |
| `pair_code` | `code`, `expires_in_seconds` | Após o `welcome`, se o dispositivo não está pareado |
| `paired` | `user_email` | Quando o dispositivo é vinculado a uma conta |
| `input` | `action` (mouse/teclado) | Comando de entrada a injetar no computador (Etapa 6) |
| `start_stream` | `max_fps`, `quality?`, `max_width?` | Inicia a transmissão da tela; `quality`/`max_width` (opcionais) vêm do ajuste de qualidade do app (Etapa 7) |
| `stop_stream` | — | Encerra a transmissão da tela |
| `power` | `action` (`shutdown`/`restart`/`suspend`) | Desliga, reinicia ou suspende o computador |
| `wake` | `mac` | Pede a este agente que acorde (Wake-on-LAN) um vizinho da LAN pelo MAC |
| `list_apps` | `request_id`, `kind` (`desktop`/`installed`/`running`) | Pede a lista de aplicativos; o agente responde com `app_list`. `desktop` = atalhos da área de trabalho (com ícones), usado pela dock |
| `launch_app` | `id` (caminho do atalho) | Abre um programa no computador |
| `close_app` | `id` (PID) | Encerra um programa em execução |
| `system_info` | `request_id` | Pede as métricas do computador; o agente responde com `system_stats` |
| `list_files` | `request_id`, `path` (vazio = pasta do usuário) | Pede o conteúdo de uma pasta |
| `read_file` | `transfer_id`, `path` | Pede que o agente leia um arquivo e o mande em `file_chunk` |
| `write_file_begin` | `transfer_id`, `name`, `size` | Começa a receber um arquivo vindo do celular |
| `write_file_chunk` | `transfer_id`, `seq`, `data` (base64) | Um pedaço do arquivo que sobe ao computador |
| `write_file_end` | `transfer_id` | Fim do envio; o agente publica o arquivo e responde `file_done` |
| `cancel_transfer` | `transfer_id` | Desiste de uma transferência em curso, nos dois sentidos |
| `run_automation` | `request_id`, `steps[]` (`kind`, `wait_ms?`, e os campos do tipo) | Executa uma sequência de passos em ordem. Vai **numa mensagem só**: o iOS suspende aplicativos, e uma sequência conduzida pelo telefone pararia no meio se a pessoa bloqueasse a tela. Uma falha não interrompe as seguintes, e cada passo volta no `automation_result` |
| `media` | `action` (`play_pause`/`next`/`previous`/`volume_up`/`volume_down`/`mute`) | Aciona uma tecla multimídia. São teclas **globais**: valem para quem estiver tocando som, sem depender da janela em foco |
| `set_schedule` | `items[]` (`id`, `name`, `time` `"HH:MM"`, `days[]`, `steps[]`) | A lista **inteira** das automações que este computador dispara sozinho. Ver abaixo |

## A agenda vive no computador, não no servidor

O agendamento só tem sentido se funcionar **com o celular na gaveta**. Por isso o
backend não dispara nada às 18h: ele entrega a agenda ao agente (no aperto de mão
e a cada mudança em `/automations`), e o relógio que decide é o do próprio
computador.

No agente, a agenda vive **fora do laço da conexão** (`vigiar_agenda`, em
`client.rs`). Se ela morasse dentro dele, um Wi-Fi que trocasse de rede às 17:59
levaria junto as dezoito horas: o laço cai, reconecta e a agenda voltaria zerada.
Como está, uma vez entregue ela dispara mesmo com o servidor fora do ar. O que
ainda não sobrevive é **reiniciar o agente**: a agenda só existe em memória, e
volta na próxima conexão. Persistir em disco é o passo que falta.

Três consequências que o formato registra:

- **A lista vai inteira, nunca em pedaços.** Lista inteira não dessincroniza:
  não existe "o servidor achava que tinha apagado". O agente troca a agenda toda
  e esquece as marcas de quem saiu.
- **`time` é hora local da máquina.** "18:00" é dezoito horas onde o computador
  está. Um agente que decidisse em UTC fecharia tudo às 15h no Brasil.
- **`days` tem segunda = 0, e vazio significa todos os dias.** Um item com
  horário malformado é **descartado** em vez de virar 00:00: uma automação que
  não aparece na lista é um problema visível; uma que dispara na madrugada por
  causa de um `parse` falho é um problema que ninguém liga à causa.

### O passo `save_all`, e por que ele tem uma lista escrita à mão

O par do `close_all`, e o que torna o agendamento seguro: fechar tudo às 18h com
a pessoa longe do computador é uma promessa de perder trabalho.

A tentação é mandar Ctrl+S em tudo que está aberto, e não dá — **Ctrl+S não
significa "salvar" em toda parte.** Num navegador ele abre "salvar página como",
uma caixa modal esperando um nome; a automação seguiria em frente e o computador
passaria a noite com ela no meio da tela. Por isso `salvar.rs` tem uma lista de
**permissão** (`EDITORES`). Uma lista de exclusão erraria por omissão: todo
programa novo do mundo entraria nela sozinho, e o erro só apareceria na noite em
que alguém deixasse a automação rodando.

O que resta de risco é conhecido e falha para o lado seguro: um arquivo novo e
nunca salvo abre "salvar como" mesmo num editor de verdade, e aí o `close_all`
seguinte simplesmente não consegue fechar aquele programa — que é o desfecho
certo, porque o que estava lá não tinha sido gravado.

O que o agente faz sozinho, em `agenda.rs`: avisa **5 min antes** (na janela ou,
em máquina sem placa de vídeo, numa caixa do Windows com "Cancelar por hoje"),
dispara na hora com **2 min** de folga, e **não dispara** se passou disso — ligar
o computador às 19h e ver o "fim de expediente" das 18h fechar tudo seria pior do
que ele não ter rodado. Cancelar vale só para hoje.

## O heartbeat é um contrato dos dois lados

O agente manda `heartbeat` a cada **10 s** e o servidor responde `ack`. As duas
pontas cobram esse ritmo, e nenhuma cobrava antes:

- **Agente** (`SEM_RESPOSTA`, em `client.rs`): 35 s sem receber **nada** do
  servidor derrubam a conexão e disparam a reconexão.
- **Servidor** (`SILENCIO_DO_AGENTE`, em `main.py`): 35 s sem receber nada do
  agente fecham o socket.

Os dois números são iguais, e são três batidas com folga. Menos que isso
derrubaria a conexão por uma batida perdida em rede ruim; muito mais é o
problema original.

E o problema original era este: **uma conexão TCP pode morrer sem que nenhum
dos lados saiba**. Numa máquina virtual que suspende, num Wi-Fi que troca de
rede, num notebook que dorme, o socket fica meio-aberto. O agente continua
escrevendo `heartbeat` nele, o sistema operacional guarda em buffer e
retransmite, e o erro só aparece quando a retransmissão esgota — **minutos**
depois. Nesse intervalo o agente se diz conectado, o app mostra o computador
online, e nada funciona. A reconexão em 5 s não ajudava: o que era lento não
era reconectar, era **perceber**.

### A conexão antiga não limpa a sessão nova

Enquanto o socket morto está pendurado, o agente já voltou por um socket novo.
Quando o antigo finalmente morre, o encerramento dele não pode apagar nada — e
apagava. Ver `main.encerrar_agente`: o registro de presença e o último quadro
da tela agora conferem **qual** conexão está saindo, como o gerenciador já
fazia. Sem isso, o computador sumia do app minutos depois de voltar.