# Estado do projeto

Onde o Deskside está em relação ao documento original do projeto, e **o que foi
deliberadamente cortado dele**.

Este arquivo existe por um motivo específico: o escopo completo vive num
documento em PDF fora do repositório, e ele não sabe das decisões tomadas
depois. Sem este registro, daqui a seis meses o PDF ainda vai dizer que webcam e
microfone fazem parte do produto, e ninguém vai lembrar que a saída deles foi uma
escolha — vai parecer dívida.

Última revisão: agosto de 2026.

## As etapas do documento

| # | Etapa | Estado |
|---|---|---|
| 1 | Estrutura inicial | ✅ |
| 2 | Usuários e autenticação | ⚠️ cadastro completo com verificação; falta login Google/Apple/Microsoft |
| 3 | Agente desktop | ⚠️ só Windows (Linux e macOS são stub) |
| 4 | Comunicação | ⚠️ externa ✅ (WebSocket + WebRTC + STUN/TURN); local (mDNS/UDP) ❌ |
| 5 | Pareamento | ✅ |
| 6 | Controle remoto básico | ✅ |
| 7 | Transmissão de tela | ✅ H.264 + JPEG de reserva, com ajuste de qualidade |
| 8 | Gerenciamento de aplicações | ✅ abrir e fechar |
| 9 | Sistema de arquivos | ✅ incluindo imagem na área de transferência |
| 10 | Controle multimídia | ✅ volume, apresentações e brilho |
| 11 | Sistema de perfis | ⚠️ Steam/gamepad cortado (ver abaixo) |
| 12 | Monitoramento | ✅ CPU, RAM, GPU, temperatura, SSD, rede e bateria |
| 13 | Terminal remoto | 🚫 cortado |
| 14 | Gamepad e controles externos | 🚫 cortado (ver abaixo) |
| 15 | Gerenciamento de energia | ✅ (+ "manter pronto", que não estava no plano) |
| 16 | Áudio e vídeo | ⚠️ áudio ✅; microfone e webcam 🚫 cortados |
| 17 | Automações | ✅ ver [`perfis-de-controle.md`](perfis-de-controle.md) |
| 18 | Integração com IA | 🚫 cortada (ver [`plano-4.0.md`](plano-4.0.md)) |
| 19 | Notificações | 🚫 cortado |
| 20 | Segurança | ⚠️ falta criptografia de arquivos e permissões granulares |

## As versões que o documento define

| Versão | Escopo original | Estado |
|---|---|---|
| MVP | login, pareamento, mouse, teclado, tela, abrir apps | ✅ completa |
| 2.0 | arquivos, área de transferência, monitoramento, perfis, multimídia | ✅ completa |
| 3.0 | ligar à distância, áudio, webcam, microfone, gamepad | ✅ completa **como redefinida** |
| 4.0 | IA, automações, suporte completo aos SOs | ⚠️ automações ✅; IA 🚫 cortada; SOs ❌ — ver [`plano-4.0.md`](plano-4.0.md) |

## O que foi cortado, e por quê

Três recursos saíram do plano. Nenhum saiu por ser difícil de programar — os
três esbarram em obstáculos que não são código.

### Microfone remoto (Etapa 16) — cortado

O Windows não deixa um programa comum **virar** um microfone. Seria preciso um
dispositivo de áudio virtual, e há só dois caminhos:

- depender do VB-CABLE ou equivalente, obrigando o usuário a instalar software de
  terceiros antes de o recurso existir — com termos de licença a resolver num
  produto pago;
- escrever o próprio driver, o que exige certificado de assinatura EV e
  assinatura WHQL: dinheiro recorrente e semanas de trabalho num pedaço do
  sistema onde um erro trava a máquina.

O resto seria fácil (é o caminho do áudio que já existe, ao contrário). O
obstáculo é inteiramente o driver.

### Webcam remota (Etapa 16) — cortado

Mesmo problema do microfone, com dois agravantes: o agente hoje só **codifica**
vídeo e precisaria decodificar, e a compatibilidade de câmera virtual no Windows
é irregular — aplicativos diferentes procuram câmera por vias diferentes, e
"funciona no Zoom" não garante "funciona no Teams". Seria um recurso a testar
aplicativo por aplicativo, sem fim claro.

Nos dois casos pesou também que existem concorrentes maduros e baratos fazendo
só aquilo (Camo, EpocCam, DroidCam): é onde o Deskside teria menos a acrescentar.

### Gamepad virtual (Etapas 11 e 14) — cortado, com condição de volta

Este é diferente dos outros dois, e o motivo merece ficar registrado: **o gamepad
não está bloqueado pelo gamepad.**

A entrada é o lado fácil. O canal de dados do WebRTC já carrega mouse e teclado
por conexão direta, e um gamepad são alguns bytes por evento — o S1 mediu 32 ms
de ida e volta completa (ver [`webrtc-plano.md`](webrtc-plano.md)).

O que bloqueia é o **vídeo**. As medições do próprio projeto:

| Situação | Medido |
|---|---|
| 720p, tela leve | 24,3 fps · 18,2 ms para codificar |
| Resolução maior | 9,6–11,3 fps · captura 72–94 ms · codificação 31–70 ms |

Entre 10 e 24 fps, **antes da rede**, com codificação H.264 por software. Jogar
de longe é *cloud gaming*, e isso pede outra categoria de engenharia:
codificação por hardware (NVENC, QuickSync, AMF), 60 fps, buffer de jitter
agressivo e nenhuma das reduções adaptativas que este pipeline faz de propósito.

Pior: algumas decisões que deixam o vídeo bom para **usar um computador** são
exatamente o que atrapalharia num jogo — parar de mandar quadros quando a tela
não muda, baixar a resolução quando a rede aperta, priorizar nitidez de texto.

Entregar o controle agora daria um recurso que funciona tecnicamente e frustra na
prática, e a frustração cairia sobre o produto inteiro.

**Condição de volta:** o gamepad reentra na pauta se e quando a codificação por
hardware entrar. O pré-requisito dele é o vídeo, não o controle.

Onde ele funcionaria hoje, para registro: mesma rede local, e jogos que não são
de reflexo — emulador, estratégia, turnos, indies. Nicho real, estreito demais
para justificar driver, tela nova e instalador extra agora.

### Suporte a controles externos (Etapa 14) — adiado junto

É barato (mesmo padrão do teclado físico do iPad: detectar pelo evento, traduzir,
encaminhar) e não tem obstáculo de plataforma. Mas só faz sentido depois do
gamepad virtual, que é quem dá o outro lado do caminho.

### Terminal remoto (Etapa 13) — cortado

Executar comando arbitrário no computador é a maior superfície de risco que o
produto poderia ter, e não é o que o Deskside faz: quem quer terminal já tem o
próprio computador na tela, com o teclado remoto funcionando. O recurso
duplicaria o que existe e traria um caminho de execução que nenhuma outra parte
do sistema tem.

### Notificações (Etapa 19) — cortado

Notificação remota no iOS exige APNs, que exige conta paga de desenvolvedor e um
app assinado — nada disso existe enquanto a distribuição for sideload com Apple
ID gratuito. E o conteúdo que valeria notificar ("o download terminou", "o
computador ficou online") é justamente o que se descobre abrindo o app.

Volta junto com a App Store, se voltar.

### HarmonyOS (Etapas 1.1, 1.3 e 1.2 da implementação) — cortado

Decisão anterior, registrada aqui para o corte ficar todo no mesmo lugar:
atrapalharia mais do que ajudaria, e o aparelho de teste roda Windows numa VM.

## O que está fora do documento e trava o lançamento

O PDF descreve o produto, não a operação. Isto não é dívida técnica — é o que
falta para o Deskside poder ser vendido:

- ~~**Backup do banco.**~~ **Feito.** Cópia diária na VM pela API de backup do
  SQLite (consistente com o servidor no ar), catorze cópias mantidas, e
  `atualizar.cmd -Backup` traz a mais recente para fora da máquina — conferindo
  que o arquivo é mesmo um banco. **A restauração foi ensaiada de verdade** em
  agosto de 2026, com o servidor de produção: parar a API, copiar a cópia por
  cima do volume, subir, e confirmar no app que os pareamentos sobreviveram. Um
  backup nunca restaurado é hipótese, não garantia. Ver
  [`deploy-vps-oracle.md`](deploy-vps-oracle.md).
- ~~**Limite de tentativas** em `/login` e no cadastro.~~ **Feito.** Os três
  caminhos que não exigem login (`/login`, `/signup/start`, `/password/forgot`)
  cobram antes de tocar no banco — em `/login`, antes do bcrypt, que é o custo
  que um atacante quer provocar. Dois contadores separados, por conta e por IP,
  porque o IP de celular é compartilhado por operadora (CGNAT) e um limite justo
  para conta bloquearia bairros inteiros. Ver `backend/app/limite.py`.
- ~~**Site e instalador.**~~ **Feito.** `deskside.com.br` serve a página, os
  termos, a privacidade e o download. O download é um `.exe` só, que pergunta se
  pode se instalar. Ver [`publicar-instalador.md`](publicar-instalador.md).
- **Provedor de e-mail e SMS.** O cadastro verifica por código, e a entrega está pronta atrás de uma interface — falta contratar SMTP e Twilio e pôr as credenciais no `deploy/.env`. Sem isso o código vai para o registro do servidor, e o app avisa.
- **App Store.** Hoje é sideload que expira em sete dias por aparelho.
- **Cobrança e planos.**
- **Termos de uso, política de privacidade, LGPD.** Existem em
  `deploy/site/termos.html` e `privacidade.html`, e a própria página diz que são
  rascunho. Escritos por quem não é advogado, e o que trava a cobrança é a
  revisão — não a redação.
- **SQLite** onde o plano pedia PostgreSQL + Redis, e **sem Alembic** — a
  migração de esquema é remendada na mão em `db.py`.
- **Revisão de segurança** antes de abrir para terceiros.

## O que existe e o documento não pedia

Vale registrar, porque não aparece em nenhuma tabela acima: WebRTC com TURN
próprio, dock de aplicativos, várias telas, teclado com sugestões e correção,
zoom para acessibilidade, "manter pronto" (não deixar o PC dormir), biometria,
cinco idiomas, mouse e teclado físicos no iPad, migração automática de
configuração na troca de nome, e um script que atualiza agente, app e VPS de um
terminal só.
