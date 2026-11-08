# Teste em rede lenta e celular fraco

O teste de carga mediu o servidor. Este mede o que a pessoa sente: o app num
4G ruim, num celular modesto. É manual, leva uns 30 minutos, e vale repetir
antes de cada versão grande.

Fazer **depois** de publicar servidor, app e agente novos: o teste é do que
está no ar.

## Onde

### Android: o emulador do Dell, com a rede de um 3G

O emulador do Android Studio limita a rede sozinho. No PowerShell do **Dell**
(`C:\Users\caiof_lv78yyf\RemoteOne`):

```powershell
$emu = "$env:LOCALAPPDATA\Android\Sdk\emulator\emulator.exe"
$avd = & $emu -list-avds | Select-Object -First 1
& $emu -avd $avd -netdelay umts -netspeed umts
```

- `umts` é um 3G: ~400 ms de atraso e ~400 kbit/s. Para o pior caso, troque
  os dois por `edge`.
- **Processador fraco:** no Android Studio, *Device Manager* → lápis do
  aparelho → *Show Advanced Settings* → *Multi-Core CPU* = 2 e RAM = 2048 MB.
- Com o emulador aberto, instale o app como de costume (por exemplo
  `flutter run --release` na pasta `client`, ou arrastando o `.apk` para a
  janela do emulador).

### iPhone: a rede de verdade, num lugar ruim

O limitador de rede do iPhone (*Network Link Conditioner*) fica no menu
*Desenvolvedor*, que só aparece depois de o iPhone ser ligado a um Mac com o
Xcode. Sem Mac, use a rede real:

- Wi-Fi **desligado**, só dados móveis;
- num lugar de sinal fraco (elevador, garagem, fundo da casa);
- *Ajustes → Celular → Opções → Modo de Poucos Dados* ligado.

## O roteiro

Para cada passo, anote o tempo **do toque até a tela útil**, contando no
relógio do celular ou gravando a tela. Repita 3 vezes e fique com o do meio.

| # | Passo | Bom | Ruim |
|---|---|---|---|
| 1 | Abrir o app já logado até a lista de computadores aparecer | < 2 s | > 4 s |
| 2 | Entrar com e-mail e senha (do toque em "Entrar" até a lista) | < 3 s | > 6 s |
| 3 | Tocar num computador até a primeira imagem da tela | < 5 s | > 10 s |
| 4 | Mover o mouse na tela remota: o atraso percebido | não se nota | o cursor "arrasta" |
| 5 | Abrir Arquivos até a pasta aparecer | < 3 s | > 6 s |
| 6 | Abrir Downloads (pasta grande) e tocar em "Carregar mais" | < 3 s cada | > 6 s |
| 7 | Baixar um arquivo de 5 MB | < 2 min no 3G | falha ou trava |
| 8 | Desligar os dados por 10 s e religar com o app aberto | volta sozinho | precisa fechar o app |

Em cada passo, olhe também:

- **A tela pula?** Um botão que muda de lugar quando o conteúdo chega é
  defeito, mesmo que rápido.
- **Há sinal de vida?** Esqueleto ou barra de progresso enquanto espera. Tela
  parada sem nada dizendo é o pior caso, mesmo que dure pouco.
- **O erro se explica?** Se algo falhar, a mensagem diz o que fazer?

## O que o servidor viu

Toda requisição que passa de 1 segundo vira uma linha no diário da API (ver
`backend/app/cronometro.py`). No **VPS**, logo depois do teste:

```bash
cd ~/Deskside/deploy 2>/dev/null || cd ~/RemoteOne/deploy
sudo docker compose -f docker-compose.lite.yml logs --timestamps --since 1h api | grep "lento:"
```

Uma rota que aparece aqui com o celular em rede **boa** é lentidão do
servidor ou do computador. Uma que só aparece no 3G é rede — e aí o
conserto é mandar menos, ou menos vezes.

## Resultado

Copie a tabela, preencha e guarde aqui embaixo, com a data, o aparelho e a
rede. É o que permite dizer, na próxima versão, se ficou melhor ou pior.
