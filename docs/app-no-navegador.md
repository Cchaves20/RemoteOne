# O app no navegador

O RemoteOne compilado para web, servido pelo mesmo domínio da API. Abre em
`https://caio-remoteone.duckdns.org` em qualquer navegador — sem loja, sem
instalação, sem assinatura de código.

Nasceu de um problema concreto: o **MateBook Fold** roda HarmonyOS, que não
instala APK nem tem porta oficial do Flutter. Mas resolve mais do que isso — o
Surface, um computador de trabalho, o notebook de outra pessoa. Qualquer tela
com navegador vira um controle.

## Publicar

```
.\scripts\publicar-web.cmd
```

Na primeira vez ele gera a pasta `client/web/` com
`flutter create --platforms=web`, porque **este repositório não versiona pastas
de plataforma** — o Codemagic faz o mesmo com a `ios/`. Sem esse passo o
Flutter recusa com "This project is not configured for the web". Depois
compila, envia ao VPS e troca a pasta. O Caddy lê os arquivos do disco: não é
preciso reiniciar nada.

Se preferir à mão, ou se o script atrapalhar:

```bash
cd client
flutter create --org com.remoteone --project-name remoteone_client --platforms=web .
flutter build web --release

CHAVE=SUA_CHAVE.key
VPS=ubuntu@147.15.45.45
ssh -i $CHAVE $VPS "rm -rf RemoteOne/deploy/app-novo"
scp -r -i $CHAVE build/web "$VPS:RemoteOne/deploy/app-novo"
ssh -i $CHAVE $VPS 'cd RemoteOne/deploy \
  && sudo mkdir -p app && sudo chown -R $(id -u):$(id -g) app \
  && find app -mindepth 1 -delete && cp -a app-novo/. app/ && rm -rf app-novo'
```

O envio vai para um **nome novo** e só então troca. Copiar por cima deixaria o
app quebrado durante a transferência: arquivos novos convivendo com antigos e
um `main.dart.js` que não casa com o `index.html`.

### Troca o conteúdo, não a pasta

`deploy/app` está **montada** no contêiner do Caddy, e bind mount prende o
contêiner ao *inode*. Um `rm -rf app && mv app-novo app` cria um inode novo: o
disco do VPS ficaria com o app atualizado e o Caddy continuaria servindo o
antigo — ou uma pasta vazia — para sempre, sem erro nenhum.

É a mesma armadilha que já custou uma tarde com o Caddyfile montado como
arquivo solto. Por isso os passos apagam o **conteúdo** e copiam por dentro:
a pasta que o Docker enxerga é sempre a mesma.

O `chown` está ali porque quem cria a pasta na primeira subida é o Docker, como
root; sem ele o `find` responde "permission denied". E o `rm -rf app-novo` do
começo não é zelo: se a pasta já existir de um envio interrompido, o `scp -r`
não a substitui — ele deposita a cópia **dentro** dela, virando `app-novo/web`,
e a publicação termina "com sucesso" servindo 404 em tudo.

## Por que o mesmo domínio

Não é economia de domínio, é requisito. Servir o app de outra origem esbarraria
no **CORS** a cada chamada, e uma página em `https` não pode falar com um
servidor em `http` (**conteúdo misto**) — os dois problemas somem quando app e
API compartilham a origem.

É também o que faz o app abrir funcionando: na web, o servidor padrão é a
própria origem da página (`Uri.base.origin`), então ninguém digita endereço
nenhum. Nas outras plataformas o padrão continua sendo `localhost`, e a tela de
login deixa trocar.

No Caddy, a lista de rotas do backend é **explícita** (`/api/*`, `/ws/*`,
`/health`, `/docs`, `/openapi.json`). Um `reverse_proxy` que pegasse tudo
engoliria os arquivos do app, e o sintoma seria uma página em branco sem erro
nenhum.

### `handle`, e não matcher solto

O Caddy executa as diretivas numa **ordem fixa própria**, não na ordem em que
aparecem no arquivo. O `try_files` é uma reescrita, e reescritas rodam **antes**
do `reverse_proxy`. A primeira versão deste arquivo era assim:

```
@backend path /api/* /ws/* /health
reverse_proxy @backend api:8000
try_files {path} /index.html
file_server
```

Parece certo e **derruba a API inteira**. Todo pedido — inclusive `/health` e
`/ws/agent` — era reescrito para `/index.html` antes de o matcher do backend ser
avaliado, e aí ele não casava com nada. O sintoma foi o servidor parecer
"velho": o `/health` respondia a página do app em vez do JSON, e a conferência
do `atualizar` listou todos os recursos como ausentes.

Blocos `handle` são mutuamente exclusivos e avaliados **na ordem escrita**. É a
primitiva certa para "isto vai para lá, o resto vem para cá", e a reescrita de
dentro do último bloco só vale dentro dele.

## O que muda no navegador

| | Telefone | Navegador |
|---|---|---|
| Tela, teclado, mouse | ✅ | ✅ |
| Vídeo direto (WebRTC) | ✅ | ✅ |
| Som do computador | ✅ | ✅ |
| Área de transferência | ✅ | ✅ |
| Enviar arquivo | ✅ | ✅ |
| Baixar arquivo | folha de compartilhar | download do navegador |
| Biometria para abrir | ✅ | não existe |

**Baixar arquivo.** No telefone o certo é gravar num temporário e abrir a folha
de compartilhamento, onde a pessoa escolhe "Salvar em Arquivos" ou manda por
outro app. No navegador quem decide onde salvar é o próprio navegador, e a
folha ou não existe ou é pior que o download comum. Os dois caminhos vivem em
`services/file_saver*.dart`, escolhidos na compilação por importação
condicional — assim o `dart:io`, que não existe na web, nem aparece para o
compilador.

**Biometria.** Não há Face ID nem digital num navegador. O desbloqueio do app
simplesmente não roda ali: perguntar geraria um erro de plugin ausente a cada
abertura, e o design já era *fail-open* (qualquer problema com a biometria
destranca em vez de trancar).

## Guardar a sessão

No navegador, o token fica no armazenamento local da aba — não num cofre do
sistema, como no telefone. Quem tiver acesso ao computador **e** ao perfil do
navegador alcança a sessão.

Para um computador pessoal isso é equivalente a deixar o e-mail aberto. Para um
computador compartilhado, saia da conta ao terminar, ou use uma janela anônima:
ao fechá-la, nada fica.

## Verificação manual

O script já confere sozinho que a raiz do domínio responde o HTML do Flutter —
se ele terminar reclamando disso, o problema é o roteamento do Caddy, não o
build. O resto precisa de olho humano:

1. `.\scripts\publicar-web.cmd` termina com "Publicado".
2. Abra `https://caio-remoteone.duckdns.org` — a tela de login aparece **sem**
   pedir endereço de servidor.
3. Entre com a conta de sempre: os computadores pareados aparecem.
4. Controle um deles. A imagem tem que chegar, e a barra de cima deve dizer
   **"direto"** (WebRTC), não só "fps".
5. Recarregue a página numa tela interna (F5 em Arquivos, por exemplo): tem que
   continuar ali, não dar 404. É o `try_files` do Caddy.
6. Baixe um arquivo: o navegador deve baixá-lo como qualquer download.
7. Abra também no celular, na mesma conta: os perfis criados num aparecem no
   outro.

## O que ainda não foi verificado

Nada disto rodou ainda — o app nunca foi compilado para web neste projeto. O
primeiro `flutter build web` é o teste de verdade, e é razoável que apareça
algum plugin reclamando. Os candidatos, por ordem de probabilidade:

- **`flutter_webrtc`** na web usa a implementação do navegador, que negocia
  diferente da nativa. Se o vídeo direto não fechar, o JPEG de reserva assume
  e o app continua utilizável.
- **`file_picker`** e **`share_plus`** têm suporte web, mas com comportamento
  próprio de navegador.
- **`local_auth`** não tem implementação web; por isso o `kIsWeb` antes da
  chamada.
